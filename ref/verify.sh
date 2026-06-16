#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Verification for the Hermes umbrella.
#
# Reads the umbrella's own state file as the source of truth for the
# bearer and the endpoint, then compares (a) the producers' DASHBOARD_TOKEN
# value as written into the seed-hermes scaffold's data/.env (the agent
# seed writes the RHS verbatim; see SEED.md ## Verification step 2) and
# (b) the Pi's viewer .env DASHBOARD_TOKEN — BOTH via SHA-256 hash over SSH,
# because in the Pi-colocated topology the scaffold lives ON THE PI (the
# container and the viewer share one machine), so neither token value lands
# on the install host's terminal. Finally, runs an end-to-end smoke from the
# install host directly to the Pi's published /api/message (proving
# install-host→Pi reachability) and back out via the Pi's localhost API (the
# same store the kiosk reads), using the fixed, non-rendered probe card
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
# token write-side). In the Pi-colocated topology the scaffold lives ON THE
# PI, inside the seed-hermes clone; HERMES_SCAFFOLD (or --scaffold) is that
# on-Pi path, default ${SEED_HOME:-$HOME/seeds}/seed-hermes/hermes-agent —
# resolved on the Pi, not locally. Mirrors the agent seed's installer.
SCAFFOLD_DIR="${HERMES_SCAFFOLD:-\${SEED_HOME:-\$HOME/seeds}/seed-hermes/hermes-agent}"
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

PI_TARGET=$(jq -re .pi_ssh_target "$UMBRELLA_STATE")

# The scaffold data/.env now lives on the Pi; existence is checked there
# (the on-Pi path may reference $HOME/$SEED_HOME, so it expands on the Pi).
ssh $SSH_OPTS -- "$PI_TARGET" "[ -f \"$AGENT_ENV\" ]" \
  || { echo "FAIL v-link: scaffold data/.env missing on Pi (or Pi unreachable) at $AGENT_ENV" >&2; exit 1; }

# v-children: every declared child SEED's install terminated `success`.
# Each child's install-report.json lives at its $REPO_ROOT. In the
# Pi-colocated topology only seed-durable-ssh installs on the install host;
# seed-hermes, seed-hermes-plow, the agent, and the viewer are all
# remote-host deps cloned in the PI's cache (per the remote-host transport
# contract). The Pi checks parse with node (jq is not in the Pi's
# system-package set; node >=20.6 is), so both transports assert the same
# top-level-key predicate.
CHILD_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/seed/github.com/plow-pbc"
R="$CHILD_CACHE/seed-durable-ssh/install-report.json"
[ "$(jq -r .terminal_reason "$R" 2>/dev/null)" = success ] \
  || { echo "FAIL v-children: seed-durable-ssh terminal_reason != success, or report unreadable (expected: $R)" >&2; exit 1; }
for child in seed-hermes seed-hermes-plow seed-life-dashboard-hermes-agent seed-life-dashboard-viewer; do
  # The child name is passed as a positional arg ($0 to the remote bash -c),
  # not interpolated into the quoted body — same positional discipline as the
  # node `process.argv[1]` read, so no nested-escaping fragility.
  ssh $SSH_OPTS -- "$PI_TARGET" 'bash -l -c '\''node -e "process.exit(JSON.parse(require(\"fs\").readFileSync(process.argv[1])).terminal_reason===\"success\"?0:1)" "${XDG_CACHE_HOME:-$HOME/.cache}/seed/github.com/plow-pbc/$0/install-report.json"'\'' '"$child" \
    || { echo "FAIL v-children: $child terminal_reason != success, or report unreadable over SSH (Pi cache clone)" >&2; exit 1; }
done
echo "OK   v-children"

# v-link-agent: the producers' DASHBOARD_TOKEN (the RHS in the scaffold's
# data/.env, ON THE PI) == umbrella's state.json:dashboard_token. The Pi-side
# value is hashed on the Pi and only its SHA-256 returns — the token value
# never lands on the install host's terminal (matching v-link-viewer below).
STATE_TOKEN=$(jq -re .dashboard_token "$UMBRELLA_STATE")
STATE_SHA=$(printf '%s' "$STATE_TOKEN" | shasum -a 256 | awk '{print $1}')
# AGENT_ENV may reference $HOME/$SEED_HOME; the remote login shell expands it
# (the path is interpolated into the double-quoted remote command, so any
# $HOME inside it expands ON THE PI, matching the existence check above). The
# token value is hashed on the Pi; only the SHA-256 returns — the value never
# lands on the install host's terminal (same discipline as v-link-viewer).
# Guarded capture: under `set -e` a bare AGENT_SHA=$(ssh …) would abort at the
# assignment on an SSH/remote error, skipping the FAIL message below.
if ! AGENT_SHA=$(ssh $SSH_OPTS -- "$PI_TARGET" "bash -lc 'VAL=\$(grep -m1 \"^DASHBOARD_TOKEN=\" \"$AGENT_ENV\" | sed \"s/^DASHBOARD_TOKEN=//\"); printf %s \"\$VAL\" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk \"{print \\\$1}\"'"); then
  echo "FAIL v-link-agent: ssh/remote error reading scaffold token on Pi" >&2; exit 1
fi
if [ "$STATE_SHA" = "$AGENT_SHA" ]; then
  echo "OK   v-link-agent"
else
  echo "FAIL v-link-agent: scaffold data/.env DASHBOARD_TOKEN (on Pi) does not match umbrella state token" >&2
  exit 1
fi

# Build a mode-600 curl config file carrying the Authorization header.
# `printf` is a bash builtin (`type printf` → builtin), so its argv
# never appears in /proc/<pid>/cmdline or `ps`. The file is removed on
# every exit path via the trap.
CURL_CFG=$(mktemp "${TMPDIR:-/tmp}/umbrella-verify-curl.XXXXXX")
trap 'rm -f "$CURL_CFG"' EXIT
chmod 600 "$CURL_CFG"
ENDPOINT_URL=$(jq -re .endpoint_url "$UMBRELLA_STATE")
printf 'header = "Authorization: Bearer %s"\n' "$STATE_TOKEN" > "$CURL_CFG"

# v-link-viewer: Pi's .env DASHBOARD_TOKEN value SHA-256 matches umbrella's.
# STATE_SHA was computed at v-link-agent above (same umbrella token).
# Guarded capture (as v-link-agent): keep the FAIL message reachable on an
# SSH/remote error rather than aborting silently at the assignment.
if ! PI_SHA=$(ssh $SSH_OPTS -- "$PI_TARGET" bash -s <<'REMOTE'
set -euo pipefail
VAL=$(grep '^DASHBOARD_TOKEN=' "$HOME/services/life-dashboard-viewer/.env" | sed 's/^DASHBOARD_TOKEN=//')
# Stock Raspberry Pi OS ships sha256sum but often not shasum; prefer it,
# fall back to shasum so the digest matches the host-side shasum output.
printf '%s' "$VAL" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}'
REMOTE
); then
  echo "FAIL v-link-viewer: cannot read viewer .env DASHBOARD_TOKEN on Pi (missing file/token or Pi unreachable)" >&2; exit 1
fi
if [ "$STATE_SHA" = "$PI_SHA" ]; then
  echo "OK   v-link-viewer"
else
  echo "FAIL v-link-viewer: Pi .env DASHBOARD_TOKEN hash does not match umbrella state" >&2
  exit 1
fi

# v-e2e: synthetic POST from the install host directly to the Pi's published
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
if ! PI_RESPONSE=$(ssh $SSH_OPTS -- "$PI_TARGET" "curl -fsS 'http://localhost:5174/api/message?card=$PROBE_CARD'"); then
  echo "FAIL v-e2e: ssh/curl error reading Pi /api/message (Pi unreachable or viewer not serving)" >&2; exit 1
fi
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
if ! PI_UNITS=$(ssh $SSH_OPTS -- "$PI_TARGET" bash -s <<'REMOTE'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
for u in life-dashboard-viewer.service life-kiosk-viewer.service; do
  [ "$(systemctl --user is-active "$u" 2>/dev/null)" = active ] || { echo "FAIL $u not active"; exit 1; }
  [ "$(systemctl --user is-enabled "$u" 2>/dev/null)" = enabled ] || { echo "FAIL $u not enabled"; exit 1; }
done
echo OK
REMOTE
); then
  # Remote exits non-zero both when a unit is down (PI_UNITS holds the
  # "FAIL <u> not active/enabled" detail) and on a pure SSH error (empty).
  echo "FAIL v-units: ${PI_UNITS:-ssh/remote error reaching Pi}" >&2; exit 1
fi
# Reaching here means the remote exited 0, which it does only after echoing OK.
echo "OK   v-units"

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

# v-handoff: FINAL check — owner take-over handoff. Asserts plow_chat is
# connected, sends a one-time welcome, and confirms it reached the device. The
# full contract (once-only gate, delivered-vs-`sent` bar, resume-by-uid, and the
# accepted lost-window trade-off) lives in SEED.md ## Verification step 7 — not
# re-derived here. Reading notes: in the co-located topology the connected gate,
# the POST, and the poll all run ON THE PI over SSH under a login shell (node is
# on the login PATH; jq isn't on the Pi). The bearer is read+used on the Pi and
# never reaches the install host (same discipline as v-link-agent); only the
# umbrella state.json (handoff_msg_uid / handoff_sent_at) is written locally.
# send+poll are one SSH call, so a crash of it after the POST may re-text once
# next run — accepted (duplicates are fine for a one-time best-effort welcome).
GATEWAY_STATE="${SCAFFOLD_DIR%/}/data/gateway_state.json"
# Connected gate ON THE PI: gateway_state.json is on the Pi; jq isn't in the
# Pi's package set (node >=20.6 is, per v-children), so parse with node. The
# path may reference $HOME/$SEED_HOME — it expands on the Pi.
ssh $SSH_OPTS -- "$PI_TARGET" "GATEWAY_STATE=\"$GATEWAY_STATE\" bash -l -s" <<'REMOTE' \
  || { echo "FAIL v-handoff: plow_chat gateway not connected on Pi (gateway_state.json missing/unreadable, or state != connected — chat bound but Hermes not subscribed)" >&2; exit 1; }
node -e 'const fs=require("fs");let s;try{s=JSON.parse(fs.readFileSync(process.env.GATEWAY_STATE,"utf8"))}catch(e){process.exit(1)}process.exit(s&&s.platforms&&s.platforms.plow_chat&&s.platforms.plow_chat.state==="connected"?0:1)'
REMOTE

HANDOFF_SENT_AT=$(jq -r '.handoff_sent_at // empty' "$UMBRELLA_STATE")
if [ -n "$HANDOFF_SENT_AT" ]; then
  echo "OK   v-handoff (already sent at $HANDOFF_SENT_AT)"
else
  # state.json merge helper (LOCAL — the umbrella state lives on the install
  # host, not the Pi): atomic mode-600 mktemp-in-STATE_DIR + rename, existing
  # keys preserved, fail-loud (a jq failure removes its orphan tmp, returns non-0).
  merge_state() {
    local tmp; tmp=$(mktemp "$STATE_DIR/state.json.XXXXXX")   # mode 600
    if jq "$@" "$UMBRELLA_STATE" > "$tmp"; then mv "$tmp" "$UMBRELLA_STATE"; else rm -f "$tmp"; return 1; fi
  }

  # Resume key: pass any previously-recorded uid to the Pi so it polls that
  # message instead of sending a second one (a prior run POSTed but didn't
  # confirm delivery). HANDOFF_TS is stamped locally for the latch below.
  MSG_UID=$(jq -r '.handoff_msg_uid // empty' "$UMBRELLA_STATE")
  HANDOFF_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Send (if no uid yet) + poll, ALL ON THE PI over SSH — PLOW_CHAT_TOKEN is read
  # from the scaffold data/.env and used on the Pi; it never reaches the install
  # host (same discipline as v-link-agent). The remote script validates the base
  # origin, POSTs the welcome when MSG_UID is empty, polls up to 45s, and prints
  # "<uid>\t<status>" on success or "ERR …" on a hard failure. jq is absent on
  # the Pi → JSON via node. AGENT_ENV may contain $HOME and expands on the Pi.
  HANDOFF_RESULT=$(ssh $SSH_OPTS -- "$PI_TARGET" "AGENT_ENV=\"$AGENT_ENV\" MSG_UID=\"$MSG_UID\" bash -l -s" <<'REMOTE'
set -euo pipefail
TOKEN=$(grep -m1 -E '^PLOW_CHAT_TOKEN=' "$AGENT_ENV" | sed 's/^PLOW_CHAT_TOKEN=//')
CUID=$(grep -m1 -E '^PLOW_CHAT_CHAT_UID=' "$AGENT_ENV" | sed 's/^PLOW_CHAT_CHAT_UID=//')
[ -n "$TOKEN" ] || { echo "ERR PLOW_CHAT_TOKEN missing on Pi (plow_chat not activated)"; exit 1; }
[ -n "$CUID" ]  || { echo "ERR PLOW_CHAT_CHAT_UID missing on Pi (plow_chat not activated)"; exit 1; }
# Plow Chat API base is the prod origin, inlined: single-operator pre-PMF, no
# second origin exists — so there's no PLOW_CHAT_BASE_URL knob to read/validate.
# Bearer via a mode-600 -K config (never on argv); removed on exit.
cfg=$(mktemp); chmod 600 "$cfg"; trap 'rm -f "$cfg"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$cfg"
msg_uid="$MSG_UID"
if [ -z "$msg_uid" ]; then
  body=$(node -e 'process.stdout.write(JSON.stringify({body:"✅ Your Life Dashboard is live — the Pi kiosk is up and I'\''m connected here on Hermes. Reply anytime to chat with me."}))')
  resp=$(printf '%s' "$body" | curl -fsS -K "$cfg" -H "Content-Type: application/json" --data-binary @- "https://api.plow.co/v1/chats/$CUID/messages") \
    || { echo "ERR welcome POST returned non-2xx"; exit 1; }
  msg_uid=$(printf '%s' "$resp" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).uid||"")}catch(e){}})')
  [ -n "$msg_uid" ] || { echo "ERR welcome response carried no message uid"; exit 1; }
fi
deadline=$(( $(date +%s) + 45 )); status=""
while :; do
  resp=$(curl -fsS -K "$cfg" "https://api.plow.co/v1/chats/$CUID/messages") || { echo "ERR delivery-poll GET failed"; exit 1; }
  st=$(printf '%s' "$resp" | MU="$msg_uid" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j;try{j=JSON.parse(s)}catch(e){process.exit(2)}const a=Array.isArray(j)?j:(j.messages||[]);const m=a.find(x=>x&&x.uid===process.env.MU);process.stdout.write(m&&m.status?m.status:"")})') \
    || { echo "ERR delivery-poll response was not valid JSON"; exit 1; }
  [ -n "$st" ] && status="$st"
  case "$status" in delivered|read) break ;; esac
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 5
done
printf '%s\t%s\n' "$msg_uid" "$status"
REMOTE
) || { echo "FAIL v-handoff (on Pi): ${HANDOFF_RESULT#ERR }" >&2; exit 1; }

  MSG_UID="${HANDOFF_RESULT%%$'\t'*}"
  HANDOFF_STATUS="${HANDOFF_RESULT#*$'\t'}"
  [ -n "$MSG_UID" ] || { echo "FAIL v-handoff: Pi returned no message uid" >&2; exit 1; }
  # Persist the uid locally so a later run resumes this same message (no re-send),
  # including the offline-'sent' path. A lost POST *response* on the Pi may
  # re-text once next run — accepted trade-off (duplicates fine for a one-time
  # best-effort welcome).
  merge_state --arg uid "$MSG_UID" '. + {handoff_msg_uid: $uid}' \
    || { echo "FAIL v-handoff: could not persist handoff_msg_uid to state.json" >&2; exit 1; }

  # The latch (handoff_sent_at) is written LOCALLY and ONLY on confirmed
  # delivery. A merely-'sent' (offline) WARNs without latching — the uid stays so
  # the next run resumes polling. Terminal failure / never-observed fails loud.
  case "$HANDOFF_STATUS" in
    delivered|read)
      merge_state --arg ts "$HANDOFF_TS" '. + {handoff_sent_at: $ts}' \
        || { echo "FAIL v-handoff: could not persist handoff_sent_at to state.json" >&2; exit 1; }
      echo "OK   v-handoff (welcome message $HANDOFF_STATUS)" ;;
    sent)
      echo "WARN v-handoff: welcome message still 'sent' after 45s — recipient device may be offline; the message is queued and the next verification run resumes polling this same message (no re-send)" >&2 ;;
    "")
      echo "FAIL v-handoff: delivery status never observed for message $MSG_UID within 45s (message not found in chat)" >&2; exit 1 ;;
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
