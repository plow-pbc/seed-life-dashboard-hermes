#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Verification for the Hermes umbrella.
#
# Reads the umbrella's own state file as the source of truth for the
# bearer and the endpoint, then compares (a) the producers' DASHBOARD_TOKEN
# value as written into the seed-hermes scaffold's data/.env (the agent
# seed writes the RHS verbatim; see SEED.md ## Verification step 2), and
# (b) the Pi's .env DASHBOARD_TOKEN via SHA-256 hash over SSH (so the value
# never lands on the local terminal). Finally, runs an end-to-end smoke from
# the Docker host directly to the Pi's published /api/message (proving
# host→Pi reachability) and back out via the Pi's localhost API (the same
# store the kiosk reads), using the fixed, non-rendered probe card
# __umbrella_verify__ — the store is latest-per-card with no DELETE route,
# so a fixed card keeps it bounded at one inert probe field; per-run
# uniqueness lives in the text.
#
# The Authorization: Bearer <STATE_TOKEN> header is passed to curl via
# a mode-600 -K config file, NOT via -H "Authorization: ..." on argv —
# argv is world-readable through /proc/<pid>/cmdline on Linux and `ps`
# on macOS, and the dashboard-token is a live bearer.

set -euo pipefail

# The seed-hermes scaffold dir holds the producers' data/.env (agent-side
# token write-side). Default ./hermes-agent; overridable via --scaffold or
# HERMES_SCAFFOLD, mirroring the agent seed's installer + verifier.
SCAFFOLD_DIR="${HERMES_SCAFFOLD:-./hermes-agent}"
while [ $# -gt 0 ]; do
  case "$1" in
    --scaffold) SCAFFOLD_DIR="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
AGENT_ENV="${SCAFFOLD_DIR%/}/data/.env"

# accept-new: trust a never-seen Pi host key on first contact (TOFU) so an
# unattended run doesn't stall; a later key change still hard-fails.
SSH_OPTS="-o StrictHostKeyChecking=accept-new"

STATE_DIR="${SEED_LD_HERMES_STATE_DIR:-$HOME/.local/state/seed-life-dashboard-hermes}"
UMBRELLA_STATE="$STATE_DIR/state.json"

[ -f "$UMBRELLA_STATE" ] || { echo "FAIL v-link: umbrella state missing at $UMBRELLA_STATE" >&2; exit 1; }
[ -f "$AGENT_ENV" ] || { echo "FAIL v-link: scaffold data/.env missing at $AGENT_ENV" >&2; exit 1; }

PI_TARGET=$(jq -re .pi_ssh_target "$UMBRELLA_STATE")

# v-children: every declared child SEED's install terminated `success`.
# Each child's install-report.json lives at its $REPO_ROOT — the installer
# cache for the host-side children (durable-ssh, hermes-plow, hermes-agent),
# the Pi's cache for the viewer (cloned there per the remote-host transport
# contract). The Pi check parses with node (jq is not in the viewer's
# system-package set; node >=20.6 is), so both transports assert the same
# top-level-key predicate.
CHILD_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/seed/github.com/plow-pbc"
for child in seed-durable-ssh seed-hermes-plow seed-life-dashboard-hermes-agent; do
  R="$CHILD_CACHE/$child/install-report.json"
  [ "$(jq -r .terminal_reason "$R" 2>/dev/null)" = success ] \
    || { echo "FAIL v-children: $child terminal_reason != success, or report unreadable (expected: $R)" >&2; exit 1; }
done
ssh $SSH_OPTS -- "$PI_TARGET" 'bash -l -c '\''node -e "process.exit(JSON.parse(require(\"fs\").readFileSync(process.argv[1])).terminal_reason===\"success\"?0:1)" "${XDG_CACHE_HOME:-$HOME/.cache}/seed/github.com/plow-pbc/seed-life-dashboard-viewer/install-report.json"'\''' \
  || { echo "FAIL v-children: viewer terminal_reason != success, or report unreadable over SSH (Pi cache clone)" >&2; exit 1; }
echo "OK   v-children"

# v-link-agent: the producers' DASHBOARD_TOKEN (the RHS in the scaffold's
# data/.env) == umbrella's state.json:dashboard_token. The value is read by
# stripping the KEY= prefix and never echoed.
STATE_TOKEN=$(jq -re .dashboard_token "$UMBRELLA_STATE")
AGENT_TOKEN_VAL=$(grep -m1 -E '^DASHBOARD_TOKEN=' "$AGENT_ENV" | sed 's/^DASHBOARD_TOKEN=//')
if [ "$STATE_TOKEN" = "$AGENT_TOKEN_VAL" ]; then
  echo "OK   v-link-agent"
else
  echo "FAIL v-link-agent: scaffold data/.env DASHBOARD_TOKEN does not match umbrella state token" >&2
  exit 1
fi
unset AGENT_TOKEN_VAL

# Build a mode-600 curl config file carrying the Authorization header.
# `printf` is a bash builtin (`type printf` → builtin), so its argv
# never appears in /proc/<pid>/cmdline or `ps`. The file is removed on
# every exit path via the trap.
CURL_CFG=$(mktemp -t umbrella-verify-curl)
trap 'rm -f "$CURL_CFG"' EXIT
chmod 600 "$CURL_CFG"
ENDPOINT_URL=$(jq -re .endpoint_url "$UMBRELLA_STATE")
printf 'header = "Authorization: Bearer %s"\n' "$STATE_TOKEN" > "$CURL_CFG"

# v-link-viewer: Pi's .env DASHBOARD_TOKEN value SHA-256 matches umbrella's.
STATE_SHA=$(printf '%s' "$STATE_TOKEN" | shasum -a 256 | awk '{print $1}')
PI_SHA=$(ssh $SSH_OPTS -- "$PI_TARGET" bash -s <<'REMOTE'
set -euo pipefail
VAL=$(grep '^DASHBOARD_TOKEN=' "$HOME/services/life-dashboard-viewer/.env" | sed 's/^DASHBOARD_TOKEN=//')
# Stock Raspberry Pi OS ships sha256sum but often not shasum; prefer it,
# fall back to shasum so the digest matches the host-side shasum output.
printf '%s' "$VAL" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}'
REMOTE
)
if [ "$STATE_SHA" = "$PI_SHA" ]; then
  echo "OK   v-link-viewer"
else
  echo "FAIL v-link-viewer: Pi .env DASHBOARD_TOKEN hash does not match umbrella state" >&2
  exit 1
fi

# v-e2e: synthetic POST from the Docker host directly to the Pi's published
# endpoint; Pi GET via localhost (filtered to the same card) → assert the
# sentinel round-trips. The probe CARD is the FIXED `__umbrella_verify__`:
# the store is latest-per-card with no DELETE route (any non-GET/POST is
# 405), so a fixed card keeps it bounded at exactly one inert probe field
# — each run overwrites the last. Per-run uniqueness lives in the TEXT,
# which is what the assertion greps for, so a stale prior-run value can
# never spuriously pass. There is no proxy cache in the path anymore: the
# localhost GET reads the Pi's own store directly. The card is NOT one of
# the rendered slots (1-4), so it never overwrites the household's real
# cards and never renders on the kiosk.
RUN_ID="$(date +%s)-$RANDOM"
PROBE_CARD="__umbrella_verify__"
SENTINEL="umbrella-verify-$RUN_ID"
# Transport note: the bearer travels plain HTTP to the Pi — the endpoint
# lives on the household LAN/tailnet (a Tailscale hostname is encrypted on
# the wire); plaintext-LAN is the SEED's documented trade-off.
curl -fsS -K "$CURL_CFG" \
  -H "Content-Type: application/json" \
  -d "{\"card\":\"$PROBE_CARD\",\"type\":\"probe\",\"text\":\"$SENTINEL\"}" \
  "$ENDPOINT_URL/api/message" >/dev/null

# The Pi's local /api/message is served by the viewer's own store (per
# life-dashboard-viewer.service) — the same one the published endpoint
# above wrote to. curling localhost:5174 with the probe card confirms the
# kiosk-side read path works end-to-end: host → Pi store → kiosk read.
PI_RESPONSE=$(ssh $SSH_OPTS -- "$PI_TARGET" "curl -fsS 'http://localhost:5174/api/message?card=$PROBE_CARD'")
if printf '%s' "$PI_RESPONSE" | grep -q "$SENTINEL"; then
  echo "OK   v-e2e"
else
  echo "FAIL v-e2e: sentinel $SENTINEL not found in Pi /api/message response" >&2
  exit 1
fi

# v-units: both promised units are active AND enabled (reboot-persistent) —
# the e2e above proves the dashboard service serves, but not that the kiosk
# unit is up nor that either survives a reboot. The viewer SEED installs
# rootless --user units regardless of sudo availability; that is the one
# supported namespace.
PI_UNITS=$(ssh $SSH_OPTS -- "$PI_TARGET" bash -s <<'REMOTE'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
for u in life-dashboard-viewer.service life-kiosk-viewer.service; do
  [ "$(systemctl --user is-active "$u" 2>/dev/null)" = active ] || { echo "FAIL $u not active"; exit 1; }
  [ "$(systemctl --user is-enabled "$u" 2>/dev/null)" = enabled ] || { echo "FAIL $u not enabled"; exit 1; }
done
echo OK
REMOTE
)
if [ "$PI_UNITS" = OK ]; then
  echo "OK   v-units"
else
  echo "FAIL v-units: $PI_UNITS" >&2
  exit 1
fi

# v-populated: the install isn't done until the ld-* producers have actually
# RUN once (driven host-side by the Dependencies activation block's
# `hermes cron run` loop) and all four rendered card slots hold data in the
# Pi's store THAT CHANGED during this run. The store is latest-per-card with
# no timestamps, so non-null alone would pass on a prior install's stale
# cards; each card must differ from the SHA-256 baseline the activation block
# snapshotted before running the producers, and must carry its slot's expected
# type (the kiosk eyebrow renders the posted type verbatim): 1 alert,
# 2 affirmation, 3 weather, 4 digest. This catches the silent-empty AND
# silently-stale classes no on-disk or host-side check can see: skills landed
# but never executed (stale container-side copies, endpoint host unresolvable
# from inside the container, crons never registered). The umbrella smoke above
# uses the non-rendered __umbrella_verify__ card and never touches these slots.
# Fixed 600s timeout — producer runs take minutes, not seconds.
BASELINE="$STATE_DIR/activation-baseline"
[ -f "$BASELINE" ] || { echo "FAIL v-populated: activation baseline missing — the activation block did not run" >&2; exit 1; }
DEADLINE=$(( $(date +%s) + 600 ))
MISSING="1:alert 2:affirmation 3:weather 4:digest"
while :; do
  STILL=""
  for pair in $MISSING; do
    c=${pair%%:*} ty=${pair#*:}
    RESP=$(ssh $SSH_OPTS -- "$PI_TARGET" "curl -fsS 'http://localhost:5174/api/message?card=$c'" 2>/dev/null || true)
    # Fail-closed: anything that isn't a parseable object with a non-null
    # .message of the slot's expected type counts as missing, and a card
    # whose hash still equals the pre-activation baseline counts as
    # missing (stale, not THIS run's).
    if printf '%s' "$RESP" | jq -e --arg ty "$ty" '.message != null and .message.type == $ty' >/dev/null 2>&1; then
      CUR=$(printf '%s' "$RESP" | shasum -a 256 | awk '{print $1}')
      BASE=$(awk -v c="$c" '$1==c{print $2}' "$BASELINE")
      # Fail closed on a missing per-card entry — an empty BASE would make
      # any card read as "changed" with no freshness evidence (list drift
      # between the activation snapshot loop and this one).
      [ -n "$BASE" ] || { echo "FAIL v-populated: no baseline entry for card $c" >&2; exit 1; }
      [ "$CUR" != "$BASE" ] || STILL="$STILL $pair"
    else
      STILL="$STILL $pair"
    fi
  done
  MISSING="${STILL# }"
  if [ -z "$MISSING" ]; then echo "OK   v-populated"; break; fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "FAIL v-populated: card slots (card:type) still empty, mistyped, or unchanged from pre-activation baseline after 600s: $MISSING" >&2
    echo "      (skills may be installed but never executed in the Hermes runtime —" >&2
    echo "       check container-visible skill copies, container->Pi endpoint reachability, cron registration)" >&2
    exit 1
  fi
  sleep 15
done

# v-handoff: FINAL check — the owner take-over handoff. The kiosk is up and the
# producers have run (everything above), but the install isn't "handed off" until
# (a) Hermes is actually SUBSCRIBED to the bound chat (gateway connected — bound
# but not subscribed means no inbound/outbound flows) and (b) a welcome message
# has REACHED the owner's device (delivered, not merely accepted). The send is
# once-only across re-runs: verification runs repeatedly, so it gates on
# state.json.handoff_sent_at and never re-texts the owner. `sent` = API accepted
# (necessary, not sufficient); `delivered`/`read` = reached the device (the bar);
# still-`sent` after the poll window WARNs (recipient device likely offline) but
# does NOT hard-fail. The chat bearer (PLOW_CHAT_TOKEN) travels via its own
# mode-600 -K config, never on argv — same hygiene as the dashboard bearer above.
GATEWAY_STATE="${SCAFFOLD_DIR%/}/data/gateway_state.json"
[ -f "$GATEWAY_STATE" ] \
  || { echo "FAIL v-handoff: gateway_state.json missing at $GATEWAY_STATE (chat bound but Hermes not subscribed)" >&2; exit 1; }
[ "$(jq -r '.platforms.plow_chat.state // empty' "$GATEWAY_STATE")" = connected ] \
  || { echo "FAIL v-handoff: plow_chat gateway not connected (chat bound but Hermes not subscribed)" >&2; exit 1; }

HANDOFF_SENT_AT=$(jq -r '.handoff_sent_at // empty' "$UMBRELLA_STATE")
if [ -n "$HANDOFF_SENT_AT" ]; then
  echo "OK   v-handoff (already sent at $HANDOFF_SENT_AT)"
else
  # Chat creds from the scaffold's data/.env (where seed-hermes-plow's
  # activation landed PLOW_CHAT_*). Token read by stripping KEY=, NEVER echoed.
  CHAT_TOKEN=$(grep -m1 -E '^PLOW_CHAT_TOKEN=' "$AGENT_ENV" | sed 's/^PLOW_CHAT_TOKEN=//')
  # Optional — its no-match grep (exit 1) must not abort under set -e/pipefail.
  CHAT_BASE=$(grep -m1 -E '^PLOW_CHAT_BASE_URL=' "$AGENT_ENV" | sed 's/^PLOW_CHAT_BASE_URL=//' || true)
  CHAT_BASE="${CHAT_BASE:-https://api.plow.co}"
  # The base carries the bearer on every request — require a bare https origin
  # (no userinfo/path/query/fragment) so a malformed or downgraded value can't
  # steer PLOW_CHAT_TOKEN off the intended host.
  [[ "$CHAT_BASE" =~ ^https://[A-Za-z0-9._-]+(:[0-9]+)?$ ]] \
    || { echo "FAIL v-handoff: PLOW_CHAT_BASE_URL must be a bare https origin (no userinfo/path/query/fragment) — check that value in data/.env" >&2; exit 1; }
  CHAT_UID=$(grep -m1 -E '^PLOW_CHAT_CHAT_UID=' "$AGENT_ENV" | sed 's/^PLOW_CHAT_CHAT_UID=//')
  [ -n "$CHAT_TOKEN" ] \
    || { echo "FAIL v-handoff: PLOW_CHAT_TOKEN missing from $AGENT_ENV (plow_chat not activated)" >&2; exit 1; }
  [ -n "$CHAT_UID" ] \
    || { echo "FAIL v-handoff: PLOW_CHAT_CHAT_UID missing from $AGENT_ENV (plow_chat not activated)" >&2; exit 1; }

  # Reuse the existing mode-600 $CURL_CFG seam — the e2e smoke above is done
  # with it, so overwrite it with the chat bearer rather than maintaining a
  # second config + trap. The bearer never hits argv (printf is a builtin);
  # the EXIT trap set at $CURL_CFG's creation already removes it.
  printf 'header = "Authorization: Bearer %s"\n' "$CHAT_TOKEN" > "$CURL_CFG"
  unset CHAT_TOKEN

  # Resume-safe once-only: sending is the only non-idempotent step, so its uid
  # is persisted to state.json the instant the POST returns — before the poll.
  # A rerun that finds handoff_msg_uid (but no handoff_sent_at — a prior run
  # crashed mid-poll) RESUMES polling that message instead of sending a second.
  MSG_UID=$(jq -r '.handoff_msg_uid // empty' "$UMBRELLA_STATE")
  if [ -z "$MSG_UID" ]; then
    HANDOFF_MSG="✅ Your Life Dashboard is live — the Pi kiosk is up and I'm connected here on Hermes. Reply anytime to chat with me."
    POST_RESP=$(jq -nc --arg b "$HANDOFF_MSG" '{body: $b}' \
      | curl -fsS -K "$CURL_CFG" -H "Content-Type: application/json" \
          --data-binary @- "$CHAT_BASE/v1/chats/$CHAT_UID/messages") \
      || { echo "FAIL v-handoff: POST to $CHAT_BASE/v1/chats/\$CHAT_UID/messages returned non-2xx" >&2; exit 1; }
    MSG_UID=$(printf '%s' "$POST_RESP" | jq -r '.uid // empty')
    [ -n "$MSG_UID" ] \
      || { echo "FAIL v-handoff: send response carried no message uid" >&2; exit 1; }
    # Persist the uid NOW (atomic mode-600 merge) so a crash before the delivery
    # confirm can never re-text — the rerun resumes on this uid.
    HU_TMP=$(mktemp "$STATE_DIR/state.json.XXXXXX")
    trap 'rm -f "$CURL_CFG" "$HU_TMP"' EXIT
    jq --arg uid "$MSG_UID" '. + {handoff_msg_uid: $uid}' "$UMBRELLA_STATE" > "$HU_TMP" && mv "$HU_TMP" "$UMBRELLA_STATE"
  else
    echo "v-handoff: resuming delivery poll for a previously-sent message (no re-send)"
  fi

  # Poll for delivery. A GET failure or an unparseable response is FAIL-loud —
  # never silently treated as 'sent'. HANDOFF_STATUS starts empty and only ever
  # holds an *observed* status, so an undeliverable/never-listed message FAILs
  # rather than masquerading as a benign WARN.
  HANDOFF_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  HANDOFF_DEADLINE=$(( $(date +%s) + 45 ))
  HANDOFF_STATUS=""
  while :; do
    LIST_RESP=$(curl -fsS -K "$CURL_CFG" "$CHAT_BASE/v1/chats/$CHAT_UID/messages") \
      || { echo "FAIL v-handoff: delivery-poll GET failed for $CHAT_BASE/v1/chats/\$CHAT_UID/messages" >&2; exit 1; }
    printf '%s' "$LIST_RESP" | jq -e . >/dev/null 2>&1 \
      || { echo "FAIL v-handoff: delivery-poll response was not valid JSON" >&2; exit 1; }
    ST=$(printf '%s' "$LIST_RESP" \
      | jq -r --arg u "$MSG_UID" '(.messages? // .) | (if type=="array" then . else [] end) | map(select(.uid == $u)) | .[0].status // empty')
    [ -n "$ST" ] && HANDOFF_STATUS="$ST"
    case "$HANDOFF_STATUS" in
      delivered|read) break ;;
    esac
    [ "$(date +%s)" -ge "$HANDOFF_DEADLINE" ] && break
    sleep 5
  done
  [ -n "$HANDOFF_STATUS" ] \
    || { echo "FAIL v-handoff: delivery status never observed for message $MSG_UID within 45s (message not found in chat)" >&2; exit 1; }

  # handoff_sent_at (the once-only latch) is written ONLY on a true delivery
  # (delivered/read). An offline 'sent' WARNs but does NOT latch — latching it
  # would calcify a never-delivered "complete" state and skip every future
  # check; instead handoff_msg_uid (already persisted) lets the next run resume
  # polling THIS message until it delivers or terminally fails. A terminal
  # failure status fails loud. None of these branches re-send.
  case "$HANDOFF_STATUS" in
    delivered|read)
      HS_TMP=$(mktemp "$STATE_DIR/state.json.XXXXXX")   # mktemp creates mode 600
      trap 'rm -f "$CURL_CFG" "$HS_TMP"' EXIT
      jq --arg ts "$HANDOFF_TS" '. + {handoff_sent_at: $ts}' "$UMBRELLA_STATE" > "$HS_TMP" && mv "$HS_TMP" "$UMBRELLA_STATE"
      echo "OK   v-handoff (welcome message $HANDOFF_STATUS)" ;;
    sent)
      echo "WARN v-handoff: welcome message still 'sent' after 45s — recipient device may be offline; left handoff_sent_at unset so a later verification re-checks the same message (no re-send)" >&2 ;;
    *)
      echo "FAIL v-handoff: welcome message has terminal status '$HANDOFF_STATUS' — not delivered" >&2; exit 1 ;;
  esac
fi

# Take-over summary (human handoff). Phone numbers are masked to last-4 for
# CI-log safety; the owner already has their full number from the delivered text.
# The chat token never prints here.
echo "--- handoff summary ---"
echo "kiosk:    $ENDPOINT_URL"
echo "Pi:       $(printf '%s' "$PI_TARGET" | sed -E 's/[0-9]{5,}([0-9]{4})/****\1/g')"
echo "schedule: weather 06:00, affirmation 07:00, alert 07:05, digest Sun 17:00"
echo "take over: reply to the Hermes chat thread to chat with the agent."

echo "tree conforms"
