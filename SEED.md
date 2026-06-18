# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Dependencies

This is a SEED per the [openseed convention](https://github.com/plow-pbc/openseed). An agent installing this repo without the `seed-install` skill MUST first fetch [openseed's `SEED.md`](https://github.com/plow-pbc/openseed/blob/main/SEED.md) and follow its installer contract. Like the system-tools line below, this is an install-time environment prerequisite the installer checks, not a SEED dep it recurses into — an agent already running `seed-install` satisfies it trivially.

API / per-machine state — declared as the `### Requirements` manifest below so the installer's [preflight](https://github.com/plow-pbc/openseed/blob/main/SEED.md#preflight-is-rendered) aggregates and surfaces the whole graph's needs up front (collecting non-secret rows through the agent question interface and routing the secret row + interactive logins into its generated prepare-script, both landing in the standard [inputs file](https://github.com/plow-pbc/openseed/blob/main/SEED.md#inputs-file) `~/.config/seed/seed-life-dashboard-hermes.env`, mode 600, and constructing the single-shot prompt from it), instead of hand-copying child-SEED needs into prose here:

### Requirements

| kind     | label                       | phase     | satisfy                     | bypass                            |
|----------|-----------------------------|-----------|-----------------------------|-----------------------------------|
| hardware | Raspberry Pi over SSH (`user@host`) — the single host: it runs both the natively-installed viewer kiosk AND the seed-hermes Docker scaffold (the producer container, `./data:/opt/data`) | preflight | LD_PI_SSH_TARGET            |                                   |
| input    | Calendar ICS URL            | preflight | LD_ICAL_URL                 |                                   |
| input    | Household owner's display name (how the dashboard refers to you) | preflight | LD_OWNER_NAME | |
| system   | Pi system packages (Node ≥20.6, npm, git, Chromium, emoji font) | preflight | probed up front; when the Pi lacks passwordless sudo the missing-package install is folded into the prepare-script, never a mid-install hand-back — mechanism in [environment is probed up front](#environment-is-probed-up-front) | |
| system   | Docker + Compose v2 on the Pi (the seed-hermes scaffold's runtime) | preflight | native `linux/arm64` (no qemu — fully `docker compose exec`-able); provisioned with the Pi packages above, with Compose v2 installed **explicitly** (Debian trixie has no apt candidate) on the same fold — mechanism in [environment is probed up front](#environment-is-probed-up-front) | |
| auth     | ChatGPT account for Hermes' `openai-codex` | in-flow   | **reused from the install host's own codex credential when present (zero human), else the end-of-install device-code OAuth checkpoint** ([skills are activated](#skills-are-activated-first-run)): the container needs no `auth.json` to start, so `seed-hermes` brings it up without auth and the umbrella runs `auth-openai-codex.sh` on the Pi just before the producers (the only step needing the LLM) — staging the host's `${CODEX_HOME:-$HOME/.codex}/auth.json` onto the Pi when it exists, otherwise falling through to the device-code browser flow announced up front per [the Pi-side hands-on moments](#environment-is-probed-up-front) | host already holds a codex credential |
| auth     | Plow Chat activation        | preflight | **front-loaded into the prepare-script**: the one-time phone-bind runs up front in the operator's shell (`seed-hermes-plow`'s `create_plow_chat_curl.sh --env-file <inputs-file>`), landing `PLOW_CHAT_*` in the inputs file; the install then writes them into the Pi scaffold's `data/.env` (`--from-env`, no second phone-bind) | PLOW_CHAT_TOKEN |

Context the table can't hold: the Pi's first-contact host key is trusted TOFU via `StrictHostKeyChecking=accept-new` (a *changed* key still hard-fails), and key auth to the Pi is established up front by the `seed-durable-ssh` dep (`ssh-copy-id` at prepare time, only when a BatchMode probe fails); and Plow Chat activation lands `PLOW_CHAT_*` into the scaffold's `data/.env` — the producers read external data and `ld-calendar-nudge` notifies the owner through that gateway — but the phone-bind that mints those values is **front-loaded into the prepare-script** (run once up front in the operator's shell), so the autonomous install never blocks on it; set `PLOW_CHAT_TOKEN` to skip even that up-front step. **Topology is single-Pi (co-located):** the scaffold is no longer a precondition on a separate Docker host — the `seed-hermes` dep (first in the software list) **provisions** it on the Pi (clone + `prepare.sh` + `docker compose up -d` + ready-check — the ChatGPT `openai-codex` auth is **deferred to the end-of-install checkpoint**, since container readiness needs no `auth.json`), so there is exactly one machine. The seed-hermes scaffold lives in the `seed-hermes` clone's `hermes-agent/` dir on the Pi; `HERMES_SCAFFOLD` defaults to that on-Pi path and the agent half's `docker compose exec` and the activation block run **on the Pi over SSH** (the same `seed-durable-ssh` transport the viewer rides). Because the image's `linux/arm64` variant runs natively on the Pi (no qemu binfmt handler), the container is fully exec-able — the qemu-can't-exec failure mode of a cross-host arm64 scaffold does not arise.

Software (SEED deps):

- `https://github.com/plow-pbc/seed-durable-ssh` — listed **first** so SSH reachability and key auth to the Pi are proven (or fail loudly) before anything else installs, and every later SSH hop — the on-Pi scaffold install, the agent recursion's `docker compose exec`, viewer blocks, verification — rides its ControlMaster multiplexing (one authenticated connection for the whole install). Its `SEED_SSH_TARGET` input is derived, never re-collected: `SEED_SSH_TARGET=$LD_PI_SSH_TARGET`. When key auth is missing, its `ssh-copy-id` step is the prepare-script's one extra interactive moment (the Pi password, typed once in the operator's shell).
- `https://github.com/plow-pbc/seed-hermes` — the **first software dep that materializes the producer runtime**, and the SEED that fixes the long-standing "nothing creates the scaffold" gap (#6). Declared as a **remote-host dep whose install host is the Pi** (satisfied from `LD_PI_SSH_TARGET`, the same [remote-host SEED dependency](https://github.com/plow-pbc/openseed/blob/main/SEED.md#remote-host-seed-dependency) transport the viewer uses): the installer clones it on the Pi, runs its `hermes-agent/scripts/prepare.sh` (per-checkout `COMPOSE_PROJECT_NAME`/`HERMES_CONTAINER_NAME`, host-UID/GID remap keys, `data/config.yaml`), then `docker compose up -d` + `scripts/check-ready.sh`. The ChatGPT `openai-codex` auth (`auth-openai-codex.sh`, reuse-first with a device-code fallback) is **NOT run during this recursion** — it is deferred to the end-of-install checkpoint ([skills are activated](#skills-are-activated-first-run)), because `check-ready.sh` confirms the dashboard/gateway is up with no `auth.json` present (the LLM credential is needed only by the producers, which run last). The result is the seed-hermes scaffold's `hermes` service **running on the Pi** with `./data:/opt/data` — the base `compose.yaml` + image pull + live container that nothing in the graph used to create. The compose service is named `hermes`; its checkout's `hermes-agent/` dir is the on-Pi `HERMES_SCAFFOLD`. (Its OPTIONAL platform-gateway prompt is declined here — `seed-hermes-plow` is the gateway, installed next.)
- `https://github.com/plow-pbc/seed-hermes-plow` — installs the `plow_chat` gateway (the `PLOW_CHAT_*` values were minted up front by the prepare-script's phone-bind and exported from the inputs file; this recursion just writes them into the scaffold's `data/.env` via `create_plow_chat_curl.sh --from-env` — **no mid-install phone-bind**) and the `plow-connectors` skill the producers read Gmail / Google Calendar / Slack through **into the seed-hermes scaffold that the `seed-hermes` dep just provisioned on the Pi**. It does NOT create the scaffold (no `compose.yaml`, no Hermes image pull) — that is now `seed-hermes`'s job, run as the prior dep on the same Pi — it installs the gateway + connectors *into* the now-existing scaffold. That scaffold IS the producer runtime — the agent half installs into it; there is no Plow desktop app and no local agent daemon in this graph. Like `seed-hermes`, its blocks run on the Pi over the `seed-durable-ssh` transport.
- `https://github.com/plow-pbc/seed-life-dashboard-hermes-agent` — installs the seven `ld-*` producer skills into the scaffold's `data/skills/` (a plain copy, not a marketplace POST) and registers one Hermes cron per producer via `docker compose exec <service> hermes cron create` — on the Pi, over SSH, into the same scaffold. Its `DASHBOARD_ENDPOINT_URL`/`DASHBOARD_TOKEN` inputs are derived and exported by this umbrella before any recursion (see [rendezvous is minted](#rendezvous-is-minted)); they land in the scaffold's `data/.env`, not a Plow secrets mount.
- `https://github.com/plow-pbc/seed-life-dashboard-viewer` — the Pi kiosk, **reused unchanged**, installed natively on the Pi (no container). It is co-located with the Hermes scaffold on the same Pi, but installs through a different path: **its blocks run on the Pi over SSH** (it is a remote-host dep), where the scaffold is a container. Its [`### Hardware`](https://github.com/plow-pbc/seed-life-dashboard-viewer/blob/main/SEED.md#hardware) declares the host "Reachable over SSH", and the installer satisfies that host from `LD_PI_SSH_TARGET` (this SEED's `### Requirements` hardware row), running the viewer's clone, shell blocks, and `## Verify` prompts on the Pi per the transport contract in [viewer is installed on the Pi](#viewer-is-installed-on-the-pi-over-ssh). Listed last for the verification flow (inputs no longer impose an order between agent and viewer): before recursing into it, the installer derives the viewer's [inputs](https://github.com/plow-pbc/seed-life-dashboard-viewer/blob/main/SEED.md#inputs) from the minted rendezvous values and the operator inputs per [viewer inputs are derived](#viewer-inputs-are-derived).

Standard system tools (on `PATH`): on the **install host** — `curl`, `ssh`, `jq`, `mkdir`, `mktemp`, `mv`, `rm`, `date`, `openssl`, `git`, `shasum`, `awk`; on the **Pi** — `docker` with Compose v2 (the `seed-hermes`, `seed-hermes-plow`, and agent recursions, plus the activation kick, all run `docker compose` there over SSH) and `git` (the on-Pi clones). The install host no longer needs Docker: nothing in this graph runs a container on it.

Install is **one-shot and agent-driven**. The installer's [preflight](https://github.com/plow-pbc/openseed/blob/main/SEED.md#preflight-is-rendered) reads the `### Requirements` table above and collects every unsatisfied operator input **once, up front** — the non-secret `LD_PI_SSH_TARGET`/`LD_OWNER_NAME` through the agent question interface, the secret `LD_ICAL_URL` and interactive logins through its generated prepare-script — landing the values in `~/.config/seed/seed-life-dashboard-hermes.env` (mode 600, off-transcript). Sourcing, validation, and probe order are normative in [operator inputs are supplied by preflight](#operator-inputs-are-supplied-by-preflight) and [environment is probed up front](#environment-is-probed-up-front); at that same boundary — before any recursion — the installer mints, exports, **and persists** the rendezvous values per [rendezvous is minted](#rendezvous-is-minted) (the umbrella itself owns them — no hosted middleman; the state file lands at minting, so a run that dies anywhere downstream leaves the source-of-truth token on disk for the rerun to reuse instead of minting a split-brain rotation); the leaves-first recursion order follows the `## Dependencies` list above, and the viewer's transport and derived inputs have their own sections. The root has exactly **two Phase-2 steps**, both after all recursions complete: (1) the end-of-install **ChatGPT `openai-codex` auth checkpoint** — which **reuses the install host's own codex credential when present (zero human touch), falling back to the device-code browser OAuth only when the host has none** — deferred to here so the autonomous middle never blocks on it, then (2) the activation block below ([skills are activated](#skills-are-activated-first-run)). There is exactly **one path**, and the SEED never prompts for typed input mid-install — every value is collected up front (the non-secret inputs via agent questions, the secret `LD_ICAL_URL` via the prepare-script); when the host already holds a codex credential the whole install is unattended, and the only possible interactive moment past preflight is the announced browser OAuth approval **when the host has no credential to reuse**, which mints no value the prepare-script could have pre-collected (its device code is minted live against the running container).

After the children install, run the **two Phase-2 steps in order**.

**Step 1 — the openai-codex auth checkpoint (zero-touch when the install host already has a credential).** The scaffold container is already up and ready (its readiness needs no `auth.json`), so the deferred ChatGPT `openai-codex` auth runs here — last, right before the producers, which are the only step that needs the LLM credential. This step **reuses the install host's own ChatGPT/codex credential when one exists** (zero human interaction), falling back to the device-code browser OAuth only when the host has none. Run `seed-hermes`'s standalone `auth-openai-codex.sh` **on the Pi over SSH**: the script first attempts non-interactive reuse of `${CODEX_HOME:-$HOME/.codex}/auth.json` on the machine it runs, adopting it via Hermes' native recovery; only if no valid credential is found does it fall through to a one-off `docker compose run … auth add openai-codex` that relays the device-code URL for the operator to approve in a browser, polls, and writes `data/auth.json`. Because the script runs **on the Pi** (a fresh target with no credential) while the credential lives on the **install host**, the block below **stages the host's `auth.json` onto the Pi** (mode-700 dir, mode-600 file, removed after the script returns — `scp` never prints the contents) and points the script at it via `CODEX_HOME`; with no host credential it invokes the script unstaged and the device-code fallback runs. It is **idempotent**: a credential already valid on the Pi skips the whole block, so a re-run never re-auths. The reuse path is fully unattended; the device-code path is the lone interactive moment past preflight, and it is [announced up front](#environment-is-probed-up-front):

```bash
set -euo pipefail
# PHASE-2 STEP 1 — the deferred ChatGPT openai-codex auth checkpoint. Zero-touch
# when the install host already holds a codex credential (reused), else the
# device-code browser OAuth. The seed-hermes clone (with auth-openai-codex.sh)
# lives on the Pi; the path expands ON THE PI (escaped), like HERMES_SCAFFOLD below.
HERMES_SCAFFOLD="${HERMES_SCAFFOLD:-\${SEED_HOME:-\$HOME/seeds}/seed-hermes/hermes-agent}"
# Skip ONLY when the credential is AFFIRMATIVELY valid — an allowlist on
# `hermes auth status` reporting "logged in", NOT a denylist of "not-authed"
# phrases. A non-empty status that isn't authenticated but is phrased some other
# way ("credential expired", a re-auth message, any future rephrasing) must not
# skip; gating on the positive signal makes every other state (logged out,
# expired, empty/failed exec, unknown) fall through to running the OAuth — the
# gate fails toward authenticating regardless of phrasing. Use `auth status`
# (real validity, via the running container), not a file check (a stale/malformed
# data/auth.json would fool `test -s`); and never an unconditional `hermes auth
# add` — it is *pooled*, so it would re-run the OAuth + add a duplicate each run.
STATUS=$(ssh -o StrictHostKeyChecking=accept-new -- "$LD_PI_SSH_TARGET" \
  "cd \"$HERMES_SCAFFOLD\" && docker compose exec -T hermes hermes auth status openai-codex 2>/dev/null" || true)
if printf '%s' "$STATUS" | grep -qi 'logged in'; then
  echo "openai-codex credential already valid on the Pi — skipping OAuth checkpoint"
else
  # Not affirmatively authenticated -> authenticate, preferring ZERO-touch
  # reuse of THIS install host's own ChatGPT/codex credential over the browser
  # OAuth. auth-openai-codex.sh already does the non-interactive reuse itself —
  # it reads ${CODEX_HOME:-$HOME/.codex}/auth.json ON THE MACHINE IT RUNS and
  # adopts it via Hermes' native recovery, falling through to the device-code
  # browser flow when none is valid. But it runs ON THE PI (a fresh target with
  # no credential), so we STAGE the install host's auth.json onto the Pi and
  # point the script at it via CODEX_HOME. Absent on the host -> no CODEX_HOME,
  # and the script falls through to device-code exactly as before.
  LOCAL_CODEX="${CODEX_HOME:-$HOME/.codex}/auth.json"   # on the install host
  if [ -f "$LOCAL_CODEX" ]; then
    # Stage the host credential onto the Pi: a mode-700 dir, the file mode 600,
    # removed after the script returns. scp transfers without printing the
    # contents; the token is never echoed. The Pi-side path expands ON THE PI.
    PI_CODEX_DIR="\$HOME/.cache/seed-codex"
    ssh -o StrictHostKeyChecking=accept-new -- "$LD_PI_SSH_TARGET" \
        "mkdir -p \"$PI_CODEX_DIR\" && chmod 700 \"$PI_CODEX_DIR\"" \
      || { echo "FAIL: staging dir for openai-codex credential" >&2; exit 1; }
    scp -q -o StrictHostKeyChecking=accept-new -- \
        "$LOCAL_CODEX" "$LD_PI_SSH_TARGET:.cache/seed-codex/auth.json" \
      || { echo "FAIL: staging openai-codex credential onto the Pi" >&2; exit 1; }
    # Reuse runs non-interactively. No `-t`: auth-openai-codex.sh adopts the
    # staged auth.json (or, if it's invalid, runs `docker compose run -T` and
    # relays the device-code URL on stdout) — works from a non-TTY context. The
    # staged file is removed whether the script succeeds or fails; the `if`
    # captures the outcome without tripping `set -e` before cleanup runs.
    rc=0
    ssh -o StrictHostKeyChecking=accept-new -- "$LD_PI_SSH_TARGET" \
        "chmod 600 \"$PI_CODEX_DIR/auth.json\"; cd \"$HERMES_SCAFFOLD\" && CODEX_HOME=\"$PI_CODEX_DIR\" ./scripts/auth-openai-codex.sh" \
      || rc=$?
    ssh -o StrictHostKeyChecking=accept-new -- "$LD_PI_SSH_TARGET" \
      "rm -f \"$PI_CODEX_DIR/auth.json\"" || true
    [ "$rc" -eq 0 ] || { echo "FAIL: openai-codex auth checkpoint (reuse)" >&2; exit 1; }
  else
    # No host credential to reuse -> run the one-time OAuth. No `-t`:
    # auth-openai-codex.sh runs `docker compose run -T` and relays the device-code
    # URL on stdout (operator approves out-of-band in a browser), polling until
    # Hermes writes data/auth.json — works from a non-TTY installer context.
    ssh -o StrictHostKeyChecking=accept-new -- "$LD_PI_SSH_TARGET" \
        "cd \"$HERMES_SCAFFOLD\" && ./scripts/auth-openai-codex.sh" \
      || { echo "FAIL: openai-codex OAuth checkpoint" >&2; exit 1; }
  fi
fi
```

**Step 2 — activation (skills run once).** Installing the skills is necessary but NOT sufficient — code that has never executed in the Hermes runtime proves nothing (the runtime context differs from the install host: the container's `/opt/data` mount, its DNS, its copy of the skills). The block runs **from the install host, driving the Pi over SSH** (the `seed-durable-ssh` transport): it snapshots the four card baselines, then runs each card-producing Hermes cron job once via `docker compose exec` **on the Pi** — deterministic, no chat round-trip — so [Verification](#verification) step 6 can assert the result. The baseline snapshot and the cron kick both hit the Pi: the viewer's store (`localhost:5174` *on the Pi*) and the Hermes container (also on the Pi) are co-located:

```bash
set -euo pipefail
# Activation drives the Pi over SSH: snapshot the four card baselines, then
# drive each card-producing Hermes cron job once via `docker compose exec` on
# the Pi. The umbrella state dir (on the install host) holds the baseline
# (hashes only, never card text).
STATE_DIR="${SEED_LD_HERMES_STATE_DIR:-$HOME/.local/state/seed-life-dashboard-hermes}"
# The seed-hermes scaffold lives in its clone on the Pi; this is the on-Pi path.
HERMES_SCAFFOLD="${HERMES_SCAFFOLD:-\${SEED_HOME:-\$HOME/seeds}/seed-hermes/hermes-agent}"
HERMES_SERVICE="${HERMES_SERVICE:-hermes}"   # the seed-hermes compose service the producers run in
# Baseline FIRST, then run: snapshot a SHA-256 of each rendered card slot as
# it stands before the producers run. The store is latest-per-card with no
# timestamps, so "card is non-null" cannot prove THIS run's producers
# executed — Verification step 6 instead requires every card to differ from
# this baseline. Hashes only (no card text) land on disk. Capture-then-hash
# (command substitution strips trailing newlines) so both sides of the
# comparison normalize identically — verify.sh hashes the same way.
BASE_TMP=""
mkdir -p "$STATE_DIR"
trap 'rm -f "$BASE_TMP"' EXIT
BASE_TMP=$(mktemp "$STATE_DIR/activation-baseline.XXXXXX")
for c in 1 2 3 4; do
  # A failed snapshot (SSH or curl error) aborts via the named handler
  # below — hashing an empty body would bake a hash-of-empty baseline and
  # re-open the stale-card loophole. An empty store slot is NOT a
  # failure: the server returns 200 {"message":null} for it.
  RESP=$(ssh -o StrictHostKeyChecking=accept-new -- "$LD_PI_SSH_TARGET" \
      "curl -fsS 'http://localhost:5174/api/message?card=$c'" 2>/dev/null) \
    || { echo "FAIL: baseline snapshot for card $c (ssh/curl error)" >&2; exit 1; }
  H=$(printf '%s' "$RESP" | shasum -a 256 | awk '{print $1}')
  printf '%s %s\n' "$c" "$H"
done > "$BASE_TMP"
mv "$BASE_TMP" "$STATE_DIR/activation-baseline"
BASE_TMP=""
# Drive each card-producing job once via the Hermes container ON THE PI. The
# agent seed registered these jobs (keyed by name) during its recursion;
# running them lands the four rendered cards (1 alert, 2 affirmation,
# 3 weather, 4 digest) through the same runtime path (mount, DNS, env) the
# scheduled ticks use. ld-sports (card 5) and ld-calendar-nudge are not part
# of the four-card baseline contract, so the activation kick does not run
# them. The container and the viewer store are co-located on the Pi, so the
# `docker compose exec` runs over the same SSH transport as the snapshot.
COMPOSE="$HERMES_SCAFFOLD/compose.yaml"
for job in ld-morning-triage ld-morning-updates ld-weather ld-weekly-digest; do
  ssh -o StrictHostKeyChecking=accept-new -- "$LD_PI_SSH_TARGET" \
      "docker compose -f \"$COMPOSE\" exec -T '$HERMES_SERVICE' hermes cron run '$job'" \
    || { echo "FAIL: activation run $job" >&2; exit 1; }
done
echo "activation runs dispatched"
```

## Objects

### Agent-side composition

- The on-Pi container result of `seed-hermes` + `seed-hermes-plow` + `seed-life-dashboard-hermes-agent`: the seed-hermes scaffold's container running on the Pi (provisioned by `seed-hermes`) with the `plow_chat` gateway activated (`PLOW_CHAT_*` in `data/.env`) and the `plow-connectors` skill installed, the seven `ld-*` producer skills copied into `<scaffold>/data/skills/`, one Hermes cron per producer registered, and `DASHBOARD_ENDPOINT_URL`/`DASHBOARD_TOKEN` landed in `<scaffold>/data/.env` (mode 600).

### Viewer-side composition

- The Pi-side result driven over SSH: `life-dashboard-viewer.service` + `life-kiosk-viewer.service` running, `.env` populated with `ICAL_URL`, `DASHBOARD_TOKEN`.

### Connection link

- The token-consistency invariant: the scaffold's `data/.env DASHBOARD_TOKEN` (the producers' write-side) and the Pi's `.env DASHBOARD_TOKEN` (viewer's read-side) MUST equal this SEED's [umbrella state file](#umbrella-state-file) `.dashboard_token` (the source-of-truth). The umbrella's [Verification](#verification) checks assert this invariant — it's the umbrella's primary post-install assertion.

### Umbrella state file

- `${SEED_LD_HERMES_STATE_DIR:-$HOME/.local/state/seed-life-dashboard-hermes}/state.json`, mode 600, owner-only (an XDG state path so the umbrella runs on a Linux or macOS install host alike — the install host needs no Docker; the scaffold runs on the Pi). Records the install's Pi target, the derived message-API endpoint, the minted `dashboard_token`, and a timestamp. Written **at minting, before any recursion** ([rendezvous is minted](#rendezvous-is-minted)), so the source of truth exists before any child materializes a copy. The file is **secret-bearing** (it holds the live bearer token), so the mode-600 mktemp + atomic-rename write is load-bearing, not just hygiene — an interrupted run can never truncate the source-of-truth token while the agent and Pi hold materialized copies. Body shape:

```json
{
  "pi_ssh_target": "user@host",
  "endpoint_url": "http://<host>:5174",
  "dashboard_token": "<hex>",
  "installed_at": "<RFC3339-ts>",
  "handoff_msg_uid": "<Plow message uid; the durable once-only key — set the instant the welcome POSTs, before delivery is confirmed>",
  "handoff_sent_at": "<RFC3339-ts; added by Verification step 7 ONLY once the owner welcome is confirmed delivered/read — a merely-'sent' (queued) message does not write this>"
}
```

### Activation baseline

- `${SEED_LD_HERMES_STATE_DIR:-$HOME/.local/state/seed-life-dashboard-hermes}/activation-baseline`: one `<card> <sha256>` line per rendered card slot (`1`–`4`), snapshotted by the activation block **before** it runs the producers. Carries hashes only — never card text. [Verification](#verification) step 6 requires every card to differ from it, which is what makes "populated" mean "populated by THIS run's producers" on a latest-per-card store with no timestamps.

## Actions

### Operator inputs are supplied by preflight

- The three operator-only inputs are declared in the [`### Requirements`](#requirements) table so the installer's [preflight](https://github.com/plow-pbc/openseed/blob/main/SEED.md#preflight-is-rendered) collects them **once, up front** — the secret `LD_ICAL_URL` via its generated prepare-script (which the operator runs in their own shell), the non-secret `LD_PI_SSH_TARGET`/`LD_OWNER_NAME` via the agent question interface — landing them in the standard inputs file `~/.config/seed/seed-life-dashboard-hermes.env` (mode 600), and the installer sources + exports them **before any recursion runs**. There is exactly **one install path — agent-driven and one-shot**; the SEED never prompts interactively (no `/dev/tty` path, no interactive-vs-headless fork):
  - `LD_ICAL_URL` — the private calendar ICS URL. Acquisition recipe, surfaced by the preflight prompt (an operator otherwise stalls hunting for it): Google Calendar → Settings → [your calendar] → "Integrate calendar" → **"Secret address in iCal format"** — NOT the public address, which can omit event details (free/busy only, per the calendar's sharing settings) yet still passes the `BEGIN:VCALENDAR` fetch-check, silently producing a sparse dashboard.
  - `LD_PI_SSH_TARGET` — `user@host`, e.g. `odio@rpi5screen`.
  - `LD_OWNER_NAME` — the household owner's display name (how the dashboard refers to you). HARD-REQUIRED by the [`seed-life-dashboard-hermes-agent`](https://github.com/plow-pbc/seed-life-dashboard-hermes-agent) child (its installer exits non-zero without it; it assembles `ld-config` from it), so it is collected once up front into the inputs file alongside `LD_ICAL_URL` and `LD_PI_SSH_TARGET`, consumed and never re-collected, and projected into the agent child at its recursion.
- All three are `tier-3` (open prose; only the operator knows them), but they **split by secret-ness** per the convention's [preflight classifier](https://github.com/plow-pbc/openseed/blob/main/SEED.md#preflight-is-rendered): **`LD_ICAL_URL` is secret** — a private-calendar feed, and `*_URL` is in the [Secret redaction](https://github.com/plow-pbc/openseed/blob/main/SEED.md#secret-redaction) set — so the agent routes it to the up-front prepare-script (silent `read -s`, non-empty only, off-transcript); **`LD_PI_SSH_TARGET` and `LD_OWNER_NAME` are non-secret**, so the agent collects them through its question interface up front and writes them to the inputs file directly. Neither non-secret value belongs in the prepare-script. The SEED itself only **consumes** the exported values; it does not re-collect them. The canonical `user@host` shape (e.g. `odio@rpi5screen`) is surfaced by the question prompt so an operator doesn't paste a URL or a bare hostname.
- **The two auth gates are scheduled at deterministic boundaries, never as mid-install surprises** — this is what keeps the autonomous middle truly hands-off. **Plow Chat is front-loaded:** its phone-bind is an interactive-login `satisfy` on a `preflight` row, so the [preflight](https://github.com/plow-pbc/openseed/blob/main/SEED.md#preflight-is-rendered) embeds `create_plow_chat_curl.sh --env-file <inputs-file>` verbatim in the prepare-script — the operator completes the one-time iMessage activation up front in their own shell, and `PLOW_CHAT_*` land in the inputs file (the install later writes them into the Pi scaffold's `data/.env` via `--from-env`, no second phone-bind; set `PLOW_CHAT_TOKEN` to skip even this). **ChatGPT `openai-codex` is reuse-first, end-loaded only when needed:** the checkpoint first **reuses the install host's own codex credential** (`${CODEX_HOME:-$HOME/.codex}/auth.json`, staged onto the Pi) — zero human touch — and only when the host has none does it fall back to the device-code browser OAuth, which *cannot* run at prepare time anyway (its device code is minted live against the running container, which does not exist until `seed-hermes` provisions it), so that fallback is deferred to the single end-of-install checkpoint ([skills are activated](#skills-are-activated-first-run)) and merely *announced* up front. Net shape: **one** prepare-script run (the one secret `LD_ICAL_URL` + the Plow phone-bind + the one-time `ssh-copy-id` only when key auth is missing; the two non-secret inputs are collected by the agent up front, not in this script) → a fully autonomous install → and **at most one** browser OAuth approval at the very end — **zero** when the install host already holds a codex credential.
- Each value is **validated by the agent at the input boundary** — immediately after the inputs file is sourced, **before** the first recursion (`seed-durable-ssh`) or any probe consumes a value — never by hand-rolled checks in the prepare-script (the collection script does non-empty only). The non-secret values are validated inline (the agent holds them); `LD_ICAL_URL` MUST first be a non-empty, **single-line** `https://` URL — the agent rejects an embedded newline (it would otherwise split the Pi's `data/.env` into a second injected assignment, a check the body probe alone does not enforce since a newline-bearing value can still fetch and pass) — then it is validated via a **non-echoing probe** that sources the inputs file in a subshell and prints only OK/FAIL: `curl -fsSL --max-time 10` it and require the body to contain `BEGIN:VCALENDAR` (the `-L` follows Google Calendar's redirect — its absence was a real failure mode; the value never reaches argv or the transcript), the canonical check being the viewer's [`## Verify` calendar-proxy step](https://github.com/plow-pbc/seed-life-dashboard-viewer/blob/main/SEED.md#verify) applied early. A wrong URL fails here in ~10s (otherwise the viewer's `server.js` swallows a bad ICS fetch and renders an empty dashboard); on failure the agent clears `LD_ICAL_URL` and re-hands-off the prepare-script. `LD_PI_SSH_TARGET` MUST match the `user@host` allowlist (`[A-Za-z0-9_.-]`, neither side leading `-`) — a security check the agent applies before the value reaches any `ssh` argv, closing the ssh option-injection and copy-paste-injection surfaces; its executable site is the [rendezvous minting](#rendezvous-is-minted) block at this same boundary, and `seed-durable-ssh`'s own [Verification](https://github.com/plow-pbc/seed-durable-ssh/blob/main/SEED.md#verification) re-asserts reachability. Secret-bearing values reach `curl`/`ssh` only via env or a mode-600 `-K` config, never on argv; no value is echoed or written anywhere in the SEED tree.
- The exported values are inherited by child SEED installs (recursed) and by the umbrella's Dependencies block. Values MUST NOT be echoed to stdout and MUST NOT be written to disk anywhere in the SEED tree; the convention's mode-600 inputs file (`~/.config/seed/seed-life-dashboard-hermes.env`, outside the tree) is the ONE sanctioned persistent location — beyond it, no per-user state beyond the [umbrella state file](#umbrella-state-file) (mode 600, secret-bearing: it carries the minted `dashboard_token`).

### Rendezvous is minted

- The umbrella itself owns the rendezvous values both children consume — the message backend is the viewer's own server on the Pi, so there is no hosted middleman and no external state file. At the input boundary, **before any recursion** (`seed-durable-ssh` included), the installer validates `LD_PI_SSH_TARGET` against the `user@host` allowlist (the endpoint host derives from it and the agent recursion materializes that endpoint into secret files), then mints/derives, exports, and atomically persists the values to the [umbrella state file](#umbrella-state-file) — persisted **at minting**, so no downstream failure can orphan a token the children already hold. The token is **reused from a prior install's state file when present** (re-runs must not rotate it — both sides hold materialized copies); otherwise it is minted fresh. Never echoed, never on argv:

```bash
set -euo pipefail
# Validate the SSH target FIRST — the endpoint host derives from it, and the
# agent recursion materializes that endpoint into secret files. Allowlist
# [A-Za-z0-9_.-] on both sides, neither side leading '-' (closes the ssh
# option-injection and copy-paste-injection surfaces). bash =~ anchors over
# the entire value, so embedded newlines fail the character class.
[[ "$LD_PI_SSH_TARGET" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*@[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] \
  || { echo "LD_PI_SSH_TARGET is not user@host (allowlist [A-Za-z0-9_.-], no leading -)" >&2; exit 1; }
# Token: reuse a prior install's (re-runs must not rotate — both sides hold
# materialized copies); else mint fresh. A PRESENT-but-unreadable state file
# hard-fails instead of silently minting a rotation: a partial re-run would
# otherwise leave the Pi holding the old token. Never echoed, never on argv.
STATE_DIR="${SEED_LD_HERMES_STATE_DIR:-$HOME/.local/state/seed-life-dashboard-hermes}"
STATE="$STATE_DIR/state.json"
DASHBOARD_TOKEN=""
if [ -f "$STATE" ]; then
  DASHBOARD_TOKEN="$(jq -re '.dashboard_token | select(. != "")' "$STATE")" \
    || { echo "existing $STATE is unreadable or has no dashboard_token — refusing to mint a rotated token over it" >&2; exit 1; }
fi
[ -n "$DASHBOARD_TOKEN" ] || DASHBOARD_TOKEN="$(openssl rand -hex 32)"
# Single derivation site for the endpoint: everything downstream (the agent
# recursion, the state write below) consumes the exported value. The host
# half of LD_PI_SSH_TARGET is the Pi's own LAN/tailnet address. This is the
# load-bearing co-location choice: the producers run INSIDE the Hermes
# container on the Pi, and the viewer's server listens on the Pi HOST's
# :5174. From inside a bridge-network container, `localhost` is the
# container's own loopback (wrong) and `host.docker.internal` does NOT
# resolve in every Docker substrate (seed-hermes documents this) — so the
# endpoint MUST be an address that routes from the container OUT to the Pi
# host. The Pi's published LAN/tailnet hostname/IP (the SSH host) is exactly
# that: the viewer binds 0.0.0.0:5174, reachable from the container as an
# ordinary outbound LAN/tailnet connection. If a household's Hermes
# container cannot resolve the SSH *hostname*, set LD_PI_SSH_TARGET with the
# Pi's IP or tailnet FQDN (see the http:// note below) — that is the
# supported escape hatch, not host.docker.internal.
ENDPOINT_URL="http://${LD_PI_SSH_TARGET#*@}:5174"
export DASHBOARD_TOKEN ENDPOINT_URL
export DASHBOARD_ENDPOINT_URL="$ENDPOINT_URL/api/message"
# Persist the source of truth NOW — before any recursion — so a run that
# dies downstream (mid-child, mid-verify) leaves state.json in place and
# the rerun reuses this token instead of minting a split-brain rotation.
# The token reaches jq via the environment (env.DASHBOARD_TOKEN), never
# argv — argv is world-readable through /proc/<pid>/cmdline and ps. The
# write is atomic (mktemp inside STATE_DIR + rename): an interrupted run
# can never truncate an existing source-of-truth token.
mkdir -p "$STATE_DIR"
# Preserve any handoff keys a prior install wrote (handoff_msg_uid /
# handoff_sent_at — the Verification step 7 once-only gate); re-minting the base
# fields must NOT drop them or a re-install re-texts the owner. They are
# non-secret (a timestamp + a message uid), so they ride --arg — the bearer
# still reaches jq only via env.DASHBOARD_TOKEN, never argv.
PRIOR_HSA=""; PRIOR_HMU=""
if [ -f "$STATE" ]; then
  PRIOR_HSA=$(jq -r '.handoff_sent_at // empty' "$STATE")
  PRIOR_HMU=$(jq -r '.handoff_msg_uid // empty' "$STATE")
fi
TMP=$(mktemp "$STATE_DIR/state.json.XXXXXX")   # mktemp creates mode 600
trap 'rm -f "$TMP"' EXIT   # pre-rename failure (jq error, signal) cleans its orphan; SIGKILL/power-loss residue stays mode-600 and inert
jq -n --arg pi "$LD_PI_SSH_TARGET" --arg ep "$ENDPOINT_URL" \
   --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   --arg hsa "$PRIOR_HSA" --arg hmu "$PRIOR_HMU" \
   '{pi_ssh_target: $pi, endpoint_url: $ep, dashboard_token: env.DASHBOARD_TOKEN, installed_at: $ts}
    + (if $hsa != "" then {handoff_sent_at: $hsa} else {} end)
    + (if $hmu != "" then {handoff_msg_uid: $hmu} else {} end)' \
   > "$TMP"
mv "$TMP" "$STATE"
```

- The viewer recursion consumes `ICAL_URL` + `DASHBOARD_TOKEN` (landing in its `.env`; there is no `MESSAGE_API_URL` — the message backend IS the viewer's own server). The agent recursion consumes `DASHBOARD_ENDPOINT_URL` + `DASHBOARD_TOKEN`, which its installer writes into the seed-hermes scaffold's `data/.env` (mode 600) — the producers read both from the container environment; there is no Plow secrets mount.
- `http://` is deliberate: the endpoint lives on the household LAN or tailnet, and a Tailscale hostname is encrypted on the wire anyway — plaintext-LAN is the documented trade-off. **Single-Pi note:** the container and the viewer are now on the *same* Pi, but the traffic still leaves the container and re-enters the Pi host over its LAN/tailnet interface (the bridge network gives the container its own netns), so the address derivation is identical to a cross-host one — the Pi's published address, not `localhost`. A household whose Hermes container can't resolve the SSH hostname can set `LD_PI_SSH_TARGET` with an IP or tailnet FQDN instead; an alternative the live install MAY adopt if hostname resolution proves flaky is a compose `extra_hosts: ["pi-host:host-gateway"]` mapping, but the LAN/tailnet-address approach needs no compose change and is the default. **This container→host hop is the part the live install on `rpi5a` stress-tests.**

### Environment is probed up front

The mid-install halts a first install can hit (unreachable Pi, missing Pi packages/Compose without passwordless sudo) MUST surface **at the start** — not three dependencies deep. That is why the Pi package / `sudo -n` / Docker+Compose-v2 **probe is front-loaded** (both paths), and the install it triggers is **never a mid-install hand-back** (step 2 below is the authoritative mechanism). The two paths differ in *where* the install runs: **without** passwordless sudo the prerequisites are folded into the prepare-script (installed after that script's own `ssh-copy-id`, so SSH already works) and are present before any recursion; **with** passwordless sudo the installer installs them unattended over SSH — the viewer's system packages (including `git`, which the `seed-hermes` clone needs) **up front, before any on-Pi recursion**, and Docker + Compose v2 via `seed-hermes`'s own host-tools check during its recursion (before its `docker compose up`). The recursion order is: inputs sourced + validated + rendezvous minted ([rendezvous is minted](#rendezvous-is-minted)) → the `seed-durable-ssh` recursion (first in `## Dependencies` — reachability and key auth proven, multiplexing landed) → the `seed-hermes` recursion (second — provisions the scaffold on the Pi: clone + `prepare.sh` + `up -d` + ready-check; the ChatGPT `openai-codex` auth is deferred to the end-of-install checkpoint, not run here) → all remaining recursion. **Either way, no operator line is handed back mid-install** — the privileged install is either unattended (passwordless) or rides the single up-front prepare-script.

1. SSH reachability and key auth: a preflight BatchMode probe decides whether key auth already exists; when it doesn't, `seed-durable-ssh`'s `ssh-copy-id` — the prepare-script's first privileged step — establishes it, so the package probe in step 2 runs over working SSH **in that same up-front script**. The later `seed-durable-ssh` recursion re-proves reachability + key auth and lands the connection multiplexing the autonomous install rides — distinct from the prepare-script's up-front copy-id.
2. Pi system packages + sudo posture: during the up-front preflight (before any recursion), run the viewer's system-packages probe (read from the viewer's SEED, already in the installer's host-side preflight cache, shipped over the SSH stdin transport) and `sudo -n true`. Missing packages with passwordless sudo → the installer auto-runs the viewer's `apt` line over SSH **up front, before any on-Pi recursion** (so `git` is present when the `seed-hermes` recursion clones the dep on the Pi — `git` is one of these viewer packages, and `seed-hermes` recurses before the viewer), then re-runs the probe; without passwordless sudo → the exact `apt` line is **folded into the prepare-script** over `ssh -t "$LD_PI_SSH_TARGET" sudo …`, run in the same up-front operator shell as `seed-durable-ssh`'s `ssh-copy-id` (and **after** it, so key auth is already established when the privileged line runs) — **not** at viewer time and **not** a mid-install hand-back. This is the SEED-side application of the convention's [remote-host SEED dependency](https://github.com/plow-pbc/openseed/blob/main/SEED.md#remote-host-seed-dependency) rule (the remote host's privileged system-package setup is folded into the prepare-script, not handed back). Docker + Compose v2 on the Pi rides the same fold: with passwordless sudo the `seed-hermes` dep's host-tools check installs it when that dep recurses; without it, the Compose-v2 install joins the same `ssh -t … sudo …` line — and because Raspberry Pi OS trixie has no apt candidate for `docker-compose-plugin`/`docker-compose-v2`, that line installs Compose v2 **explicitly** (Docker's official apt repo, or the `docker-compose` cli-plugin binary), since engine-present ≠ Compose-present.
3. The two human-auth moments are pinned to boundaries (the authoritative statement is the scheduling bullet under [operator inputs are supplied by preflight](#operator-inputs-are-supplied-by-preflight), plus the `### Requirements` `auth` rows) — neither lands mid-install. The **Plow phone-bind** is front-loaded (the prepare-script), so nothing surfaces here; the **ChatGPT `openai-codex` auth** is the single end-of-install checkpoint ([skills are activated](#skills-are-activated-first-run)), which **reuses the install host's own codex credential when present (no browser approval at all)** and otherwise falls back to device-code — **announced here** so the operator expects *at most* one browser approval once provisioning finishes, and **none** when the host already holds a codex credential.

### Viewer inputs are derived

- The viewer's [`### Inputs`](https://github.com/plow-pbc/seed-life-dashboard-viewer/blob/main/SEED.md#inputs) are never re-collected from the operator — the installer **derives** them, immediately before recursing into the viewer, from the operator inputs and the minted rendezvous values ([rendezvous is minted](#rendezvous-is-minted)): `ICAL_URL` = `$LD_ICAL_URL`; `DASHBOARD_TOKEN` = the minted token verbatim. There is no `MESSAGE_API_URL` — the viewer's own server is the message backend, so it has no upstream to point at.
- The operator inputs were already validated at the input boundary ([operator inputs are supplied by preflight](#operator-inputs-are-supplied-by-preflight)), and the derived values above are pass-throughs of already-validated or umbrella-minted values — nothing is re-validated here. (A value that slips through still fails loudly downstream: the viewer's own `## Verify` calendar-proxy check and the umbrella's e2e smoke.)
- The derived values are exported for the viewer recursion only — never echoed, never on argv. The only file they reach is the viewer's own mode-600 `.env`, written **on the Pi by the viewer's Configure block**, not by this SEED.

### Viewer is installed on the Pi (over SSH)

The viewer is a declared SEED dep whose install host is the **Pi, not the install host**: its `### Hardware` declares the host "Reachable over SSH" and the installer satisfies it from `LD_PI_SSH_TARGET`. (So are `seed-hermes` and `seed-hermes-plow` — all three execute on the Pi over the same transport; this section is the worked example for all of them.) The transport itself — `user@host` allowlist validation (already satisfied at the input boundary per [rendezvous is minted](#rendezvous-is-minted), not re-run here), fail-fast reachability probe, TOFU `accept-new`, the Pi-side cache clone as the viewer's `$REPO_ROOT` (where its `install-report.json` also lands), every block over `ssh -- "$LD_PI_SSH_TARGET" bash -l -s` with the `printf %q` export preamble on stdin, and the display-and-announce gate applied locally before the wire — is the convention's [remote-host SEED dependency](https://github.com/plow-pbc/openseed/blob/main/SEED.md#remote-host-seed-dependency) rule (this SEED is its worked example), not restated here. Specific to this graph:

- Ongoing access is the `seed-durable-ssh` dep's job: key auth was proven at the start of the install, and every hop here rides its ControlMaster multiplexing — one authenticated connection across the viewer's blocks and the umbrella's verification.
- The login shell covers the *install blocks* only: the viewer's units hardcode `ExecStart=/usr/bin/node`, so Node must be system-installed — apt or NodeSource, not nvm-only — which the viewer's own probe and NodeSource hint already steer toward.
- **The install is autonomous — there is no opt-in flag and no manual checklist.** The Pi's missing system packages are installed **up front, before any on-Pi recursion**, per [environment is probed up front](#environment-is-probed-up-front) (auto over SSH when the Pi grants passwordless sudo, else folded into the prepare-script after its `ssh-copy-id`) — so by the time the viewer recurses, its system-packages probe passes silently, with no mid-install halt and no second operator script. A provisioned Pi installs end-to-end to a live kiosk with **no root step**: the viewer's units are rootless `systemctl --user` units, reboot-persistent via the Pi's autologin (it fails loudly if the user systemd manager isn't running rather than pretending the kiosk is enabled).

### Skills are activated (first run)

The install is NOT complete when the skills are merely on disk — it is complete when each dashboard producer has **executed** once in the Hermes runtime and the cards exist. This activation is the **second** of the root's two Phase-2 steps — preceded by the end-of-install openai-codex auth checkpoint that lands `data/auth.json` (reusing the install host's own codex credential when present, else device-code OAuth; both blocks in [`## Dependencies`](#dependencies)), since the producers below are the first thing to need the LLM credential; [Verification](#verification) step 6 asserts its observable outcome.

1. After every child recursion terminates `success` — the agent seed already registered one Hermes cron per producer (keyed by name) during its recursion — the installer snapshots the four card baselines over SSH and runs each card-producing job once host-side: `docker compose exec -T <service> hermes cron run <job>` for `ld-morning-triage`, `ld-morning-updates`, `ld-weather`, `ld-weekly-digest` (the activation block above). This is deterministic and needs no chat round-trip.
2. Each run lands its card on the dashboard — the `alert` (card `1`), `affirmation` (card `2`), `weather` (card `3`), and `digest` (card `4`) cards — through the same runtime path (the container's `/opt/data` mount, its `data/.env` credentials, the container network) the scheduled ticks will use.
3. The installer does not parse the cron run's output — the Pi store is the ground truth, asserted by Verification step 6. A populated store proves the whole producer chain: current skill code visible to the container, endpoint reachable *from inside the container* (the container→Pi-host hop over the Pi's LAN/tailnet address — not merely the host-to-Pi reachability the smoke proves), valid token, store writable.
4. Why this is a verification criterion and not a courtesy note: the failure class it catches is *silent* — skills installed but never executed (stale container-side copies, container-unresolvable endpoint host, unregistered crons). Every pre-condition check (files on disk, token equality, host-side smoke) passes in that state while the kiosk stays empty until 07:00 — or forever.
5. The install then **hands off to the owner**: once the kiosk is populated, [Verification](#verification) step 7 sends a one-time welcome over the `plow_chat` gateway and confirms it reached the owner's device (`delivered`), then prints the take-over summary. The send happens **exactly once** across re-runs — gated on `state.json` (`handoff_msg_uid` recorded the instant the POST returns, finalized by `handoff_sent_at` on confirmed delivery): a rerun resumes polling the existing message rather than re-sending, so re-running verification never re-texts the owner even if a prior run crashed mid-delivery. (The narrow lost-POST-*response* window may re-text once — an accepted trade-off for a one-time best-effort welcome.) From that message on, the owner replies in the Hermes chat thread to take over two-way; that inbound reply is human onboarding, not part of the automated gate.

## Verification

1. **Each child's `## Verification` passed.** Recursion delegated this to each child SEED. This umbrella step asserts every child's terminal reason was `success` per the SEED convention's state machine — read from each child's `install-report.json` at its `$REPO_ROOT` (the install-host cache for `seed-durable-ssh`; the Pi's cache clone, over SSH, for `seed-hermes`, `seed-hermes-plow`, `seed-life-dashboard-hermes-agent`, and the viewer — all four are remote-host deps installed on the Pi). Expected: all `success`.
2. **Token-consistency: agent ↔ umbrella state.** Does the `DASHBOARD_TOKEN` **value** in the scaffold's `data/.env` equal the umbrella state file's `.dashboard_token`? Value equality, whitespace-trimmed — the agent installer writes the `.env` line verbatim, so the RHS is compared after stripping the `DASHBOARD_TOKEN=` prefix. Compared in-process (the values never print). Expected: yes.
3. **Token-consistency: viewer ↔ umbrella state.** Does the SHA-256 of the Pi's `~/services/life-dashboard-viewer/.env DASHBOARD_TOKEN` value (extracted over SSH) equal the SHA-256 of the umbrella's state-file token? Compared via hash so the value never leaves the Pi in plaintext. Expected: yes.
4. **Units active + enabled.** SSH to the Pi and assert both `life-dashboard-viewer.service` and `life-kiosk-viewer.service` are `active` AND `enabled` (reboot-persistent) — closing the gap where the e2e smoke below proves the dashboard service serves but not that the kiosk unit is up or that either survives a reboot. The rootless `systemctl --user` namespace is the one supported install shape (the viewer SEED installs user units regardless of sudo availability). Expected: both active + enabled.
5. **End-to-end smoke.** POST a synthetic `{"card":"__umbrella_verify__","type":"probe","text":"<per-run-unique sentinel>"}` from the install host **directly** to `$endpoint_url/api/message` (from the umbrella state file — the Pi's published `:5174`), bearer supplied via a mode-600 curl `-K` config file (never on argv). The card is FIXED at `__umbrella_verify__` — the viewer's store is latest-per-card and exposes no DELETE, so a fixed card keeps the store bounded at one inert probe field; uniqueness lives in the *text*. It is **non-rendered** (not one of the numbered slots `1`–`4`), so the household's real cards are never overwritten and nothing appears on the kiosk. Then SSH to the Pi and `curl -fsS 'http://localhost:5174/api/message?card=__umbrella_verify__'` against the Pi's own localhost API — the same store the kiosk reads, with no proxy cache in the path (the old 60s type-keyed proxy-cache concern is gone; the GET reads the Pi's own store directly) — and assert the unique text round-trips. This proves install-host→Pi reachability of the published endpoint AND the full producer→store→kiosk read path. Note this smoke exercises the *install-host*→Pi path, NOT the container→Pi-host hop the producers actually use — that distinct path is proven only by step 6 (the producers run inside the container). Expected: yes (sentinel visible end-to-end).

6. **Dashboard is populated by the producers (skills ran once, THIS run).** Within 600s of starting this check, do ALL FOUR rendered card slots — `1` (type `alert`), `2` (type `affirmation`), `3` (type `weather`), `4` (type `digest`) — return a non-null message of the slot's expected type from the Pi's own store (`curl 'http://localhost:5174/api/message?card=<c>'` over SSH) whose SHA-256 **differs from the activation baseline** (the per-card hashes the activation block snapshotted before running the producers)? The store is latest-per-card with no timestamps, so non-null alone would pass on a prior install's stale cards; the baseline comparison proves the producers executed **during this run**, in the Hermes runtime — which no on-disk or host-side check can prove. The umbrella's own smoke uses the non-rendered `__umbrella_verify__` card and never touches these slots. Expected: yes, all four non-null, correctly typed, and changed. A timeout, a missing baseline file, or a missing per-card baseline entry is a **verification failure** (terminal reason `failure`), not a cosmetic gap: it is exactly the silent-empty (or silently-stale) dashboard class this step exists to catch. Documented trade-off: a producer that re-emits byte-identical output on a re-run over an already-populated store (deterministic template, unchanged forecast) false-fails this check after 600s — the cards are agent-generated prose, so in practice output varies run-to-run; on a false-fail, re-run the install (a fresh agent turn regenerates the prose).

7. **Owner handoff delivered (final check).** Runs last, after step 6. In the co-located topology the scaffold lives **on the Pi**, so the connected gate, the welcome POST, and the delivery poll all run **on the Pi over SSH** (the `seed-durable-ssh` transport), parsing JSON with `node` (jq isn't in the Pi's package set). First a **hard gate**: read `<scaffold>/data/gateway_state.json` on the Pi and assert `.platforms.plow_chat.state == "connected"` — the chat is *bound* but Hermes only flows messages once *subscribed*; a not-connected gateway means the welcome would never arrive, so this FAILs. Then, **once-only across re-runs** (gated on `state.json.handoff_sent_at` — verification runs repeatedly and MUST NOT re-text the owner): if unset, POST `{"body":"<welcome/take-over text>"}` to `https://api.plow.co/v1/chats/$PLOW_CHAT_CHAT_UID/messages` (the Plow API origin is inlined — single-operator pre-PMF, no second origin to support; on the Pi, the `PLOW_CHAT_*` values are read from the scaffold's `data/.env` and the bearer rides a mode-600 curl `-K` config there — never on argv, never echoed, and **never leaving the Pi**; only the umbrella `state.json` `handoff_msg_uid`/`handoff_sent_at` are written on the install host) and capture the returned message `uid`. The welcome POST is its **own** SSH call (separate from the delivery poll), so the install host persists `handoff_msg_uid` **immediately** after the POST returns — before any poll GET can fail (the send is the only non-idempotent step). If `handoff_sent_at` is already set, SKIP the send entirely; if it is unset but a prior run already recorded `handoff_msg_uid` (an interruption after the POST but before delivery confirmed), **resume** by polling that existing message rather than POSTing a second one. (Only a lost POST *response* — the Pi's API call succeeds but its reply is dropped before the `uid` reaches us — can still re-text once on the next run; an accepted trade-off for a one-time best-effort welcome, deliberately not guarded with a nonce + chat-search at this operating point.) Then **confirm delivery** by polling `GET .../messages` for that `uid`'s `status` every 5s for up to 45s: `delivered` (or `read`) → **PASS**; record `handoff_sent_at` (UTC RFC3339) into `state.json` (atomic mktemp-in-`STATE_DIR` + rename, mode 600, existing keys preserved via jq merge). The confirmation bar is `delivered`, not `sent`: `sent` only means the API accepted the message (necessary, not sufficient); `delivered` means it reached the device. A POST that returns non-2xx is a **FAIL**, as is an unreadable/unparseable poll or a terminal non-delivered status (`failed`/`undeliverable`) — **only** `delivered`/`read` writes `handoff_sent_at`. A message still `sent` after 45s is a **WARN** (recipient device likely offline) that does **not** hard-fail (the message is queued for delivery; failing the whole install over an offline phone would be wrong) and does **NOT** write `handoff_sent_at`: `handoff_msg_uid` stays persisted so the next verification run resumes polling that same message (no re-send) until it reaches `delivered`/`read` — a merely-`sent` state is never calcified as a completed handoff. (`handoff_msg_uid` is bound to the `PLOW_CHAT_CHAT_UID` it was minted under; re-installing the same machine for a *different* owner/chat requires clearing it from `state.json` first, or the resume poll waits on the old uid against the new chat.) Finally print a take-over summary — kiosk endpoint, Pi target (phone numbers masked to last-4 for CI-log safety), the producer cron schedule (weather 06:00, affirmation 07:00, alert 07:05, digest Sun 17:00), and "reply to the Hermes chat thread to take over." Expected: gateway connected, welcome `delivered` (or a one-time WARN if the owner's device is offline). `read`/inbound-reply is two-way onboarding that needs the human — it belongs in this prose, not the automated gate.

A deterministic bash implementation lives at [`ref/verify.sh`](ref/verify.sh).

## Feedback

(default)

## Open Items

- **Remote-host transport is now a convention rule.** openseed adopted [remote-host SEED dependency](https://github.com/plow-pbc/openseed/blob/main/SEED.md#remote-host-seed-dependency) (this SEED is its worked example) and the transport prose here collapsed to a pointer. Remaining destination: the convention referencing a reusable access dep (`seed-durable-ssh`) so parents stop wiring probe/keygen/copy-id themselves — tracked in [seed-durable-ssh's Open Items](https://github.com/plow-pbc/seed-durable-ssh/blob/main/SEED.md#open-items).
- **Host is a `## Dependencies` concern, not a separate `## Host` section.** A SEED's host (here, a single Pi reachable over SSH — running both the container scaffold and the native viewer) is a *requirement* — part of "everything needed before install" — so it lives in `## Dependencies` (hardware), where it already does; a `## Host` H2 would only duplicate it. The one distinct thing such a section reached for was a machine-parseable *transport* hint so the runner could auto-switch to SSH — now carried by the viewer's `### Hardware` "Reachable over SSH" line plus this SEED's [transport contract](#viewer-is-installed-on-the-pi-over-ssh), a runner/execution concern, not a duplicate requirements section.
- **Multi-household.** Each household installs its own umbrella copy; Mary's deployment, Sam's deployment, and so on are independent. No shared infrastructure across households in v1.
- **No uninstall action.** Convention default.
- **Single install path.** One path only — agent-driven and one-shot, normative in [operator inputs are supplied by preflight](#operator-inputs-are-supplied-by-preflight). The SEED carries no interactive `/dev/tty` prompt path; missing required inputs fail fast at the input boundary with a clear, secret-safe message.

## Non-Goals

- Not a backup / migration / rollback tool. SEEDs are install-only.
- Not Hermes itself — the base Docker scaffold is [`seed-hermes`](https://github.com/plow-pbc/seed-hermes) (provisioned on the Pi) and the platform gateway is [`seed-hermes-plow`](https://github.com/plow-pbc/seed-hermes-plow). The agent half runs in that container on the Pi (arm64-native), not Mac-only and with no separate Docker host.
- Not a hosted multi-tenant backend. Each household's Pi serves its own.
