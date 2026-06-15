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

echo "tree conforms"
