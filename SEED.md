# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Dependencies

This is a SEED per the [openseed convention](https://github.com/plow-pbc/openseed). An agent installing this repo without the `seed-install` skill MUST first fetch [openseed's `SEED.md`](https://github.com/plow-pbc/openseed/blob/main/SEED.md) and follow its installer contract. Like the system-tools line below, this is an install-time environment prerequisite the installer checks, not a SEED dep it recurses into — an agent already running `seed-install` satisfies it trivially.

API / per-machine state — declared as the `### Requirements` manifest below so the installer's [preflight](https://github.com/plow-pbc/openseed/blob/main/SEED.md#preflight-is-rendered) aggregates and surfaces the whole graph's needs up front (routing the value-bearing rows into its generated prepare-script, which lands them in the standard [inputs file](https://github.com/plow-pbc/openseed/blob/main/SEED.md#inputs-file) `~/.config/seed/seed-life-dashboard-hermes.env`, mode 600, and constructing the single-shot prompt from it), instead of hand-copying child-SEED needs into prose here:

### Requirements

| kind     | label                       | phase     | satisfy                     | bypass                            |
|----------|-----------------------------|-----------|-----------------------------|-----------------------------------|
| hardware | Docker host running the seed-hermes scaffold (the container running, `./data:/opt/data`) | preflight | this machine (or the host the `--scaffold` dir lives on) | |
| hardware | Raspberry Pi over SSH (`user@host`) | preflight | LD_PI_SSH_TARGET            |                                   |
| input    | Calendar ICS URL            | preflight | LD_ICAL_URL                 |                                   |
| system   | Pi system packages (Node ≥20.6, npm, git, Chromium, emoji font) | preflight | pre-installed on the Pi (probed **up front** per [environment is probed up front](#environment-is-probed-up-front); with passwordless sudo the installer auto-runs the surfaced `apt` line, else the line is surfaced right after inputs land) | |
| auth     | Plow Chat activation        | in-flow   | the `plow_chat` gateway's one-time phone-bind activation (satisfied by `seed-hermes-plow`'s `create_plow_chat_curl.sh`; lands `PLOW_CHAT_*` into the scaffold's `data/.env`) | PLOW_CHAT_TOKEN |

Context the table can't hold: the Pi's first-contact host key is trusted TOFU via `StrictHostKeyChecking=accept-new` (a *changed* key still hard-fails), and key auth to the Pi is established up front by the `seed-durable-ssh` dep (`ssh-copy-id` at prepare time, only when a BatchMode probe fails); and Plow Chat activation lands `PLOW_CHAT_*` into the scaffold's `data/.env` — the producers read external data and `ld-calendar-nudge` notifies the owner through that gateway — so set `PLOW_CHAT_TOKEN` to skip that in-flow step entirely. The seed-hermes scaffold dir is `--scaffold <dir>` (default `./hermes-agent`); when the Hermes host differs from the install host, set `HERMES_SCAFFOLD` to its path.

Software (SEED deps):

- `https://github.com/plow-pbc/seed-durable-ssh` — listed **first** so SSH reachability and key auth to the Pi are proven (or fail loudly) before anything else installs, and every later SSH hop — viewer blocks, verification — rides its ControlMaster multiplexing (one authenticated connection for the whole install). Its `SEED_SSH_TARGET` input is derived, never re-collected: `SEED_SSH_TARGET=$LD_PI_SSH_TARGET`. When key auth is missing, its `ssh-copy-id` step is the prepare-script's one extra interactive moment (the Pi password, typed once in the operator's shell).
- `https://github.com/plow-pbc/seed-hermes-plow` — provides the **Docker Hermes scaffold** (a host `compose.yaml`, `./data:/opt/data`), the `plow_chat` gateway (its activation lands `PLOW_CHAT_*` into the scaffold's `data/.env`), and the `plow-connectors` skill the producers read Gmail / Google Calendar / Slack through. This Docker Hermes scaffold IS the producer runtime — the agent half installs into it; there is no Plow desktop app and no local agent daemon in this graph.
- `https://github.com/plow-pbc/seed-life-dashboard-hermes-agent` — installs the seven `ld-*` producer skills into the scaffold's `data/skills/` (a plain copy, not a marketplace POST) and registers one Hermes cron per producer via `docker compose exec <service> hermes cron create`. Its `DASHBOARD_ENDPOINT_URL`/`DASHBOARD_TOKEN` inputs are derived and exported by this umbrella before any recursion (see [rendezvous is minted](#rendezvous-is-minted)); they land in the scaffold's `data/.env`, not a Plow secrets mount.
- `https://github.com/plow-pbc/seed-life-dashboard-viewer` — the Pi kiosk, **reused unchanged**. **Installs on the Raspberry Pi, not the Docker host**: its [`### Hardware`](https://github.com/plow-pbc/seed-life-dashboard-viewer/blob/main/SEED.md#hardware) declares the host "Reachable over SSH", and the installer satisfies that host from `LD_PI_SSH_TARGET` (this SEED's `### Requirements` hardware row), running the viewer's clone, shell blocks, and `## Verify` prompts on the Pi per the transport contract in [viewer is installed on the Pi](#viewer-is-installed-on-the-pi-over-ssh). Listed last for the verification flow (inputs no longer impose an order between agent and viewer): before recursing into it, the installer derives the viewer's [inputs](https://github.com/plow-pbc/seed-life-dashboard-viewer/blob/main/SEED.md#inputs) from the minted rendezvous values and the operator inputs per [viewer inputs are derived](#viewer-inputs-are-derived).

Standard system tools (on `PATH`): `curl`, `ssh`, `jq`, `docker` (the agent recursion execs `hermes cron` inside the container via `docker compose exec`), `mkdir`, `mktemp`, `mv`, `rm`, `date`, `openssl`, `git`, `shasum`, `awk`.

Install is **one-shot and agent-driven**. The installer's [preflight](https://github.com/plow-pbc/openseed/blob/main/SEED.md#preflight-is-rendered) reads the `### Requirements` table above and routes every unsatisfied operator input **once, up front** into its generated prepare-script, landing the values in `~/.config/seed/seed-life-dashboard-hermes.env` (mode 600, off-transcript). Sourcing, validation, and probe order are normative in [operator inputs are supplied by preflight](#operator-inputs-are-supplied-by-preflight) and [environment is probed up front](#environment-is-probed-up-front); at that same boundary — before any recursion — the installer mints, exports, **and persists** the rendezvous values per [rendezvous is minted](#rendezvous-is-minted) (the umbrella itself owns them — no hosted middleman; the state file lands at minting, so a run that dies anywhere downstream leaves the source-of-truth token on disk for the rerun to reuse instead of minting a split-brain rotation); the leaves-first recursion order follows the `## Dependencies` list above, and the viewer's transport and derived inputs have their own sections. The root has exactly **one Phase-2 step**: the activation block below ([skills are activated](#skills-are-activated-first-run)), which runs after all recursions complete. There is exactly **one path**: the SEED never prompts.

After the children install, run the activation block. Installing the skills is necessary but NOT sufficient — code that has never executed in the Hermes runtime proves nothing (the runtime context differs from the install host: the container's `/opt/data` mount, its DNS, its copy of the skills). The block is **host-driven**: it snapshots the four card baselines over SSH to the Pi, then runs each card-producing Hermes cron job once via `docker compose exec` — deterministic, no chat round-trip — so [Verification](#verification) step 6 can assert the result:

```bash
set -euo pipefail
# Activation is HOST-DRIVEN: snapshot the four card baselines, then drive each
# card-producing Hermes cron job once via `docker compose exec`. The umbrella
# state dir holds the baseline (hashes only, never card text).
STATE_DIR="${SEED_LD_HERMES_STATE_DIR:-$HOME/.local/state/seed-life-dashboard-hermes}"
HERMES_SCAFFOLD="${HERMES_SCAFFOLD:-./hermes-agent}"
HERMES_SERVICE="${HERMES_SERVICE:-hermes-agent}"   # the seed-hermes compose service the producers run in
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
# Drive each card-producing job once via the Hermes container. The agent seed
# registered these jobs (keyed by name) during its recursion; running them
# host-side lands the four rendered cards (1 alert, 2 affirmation, 3 weather,
# 4 digest) through the same runtime path (mount, DNS, env) the scheduled
# ticks use. ld-sports (card 5) and ld-calendar-nudge are not part of the
# four-card baseline contract, so the activation kick does not run them.
COMPOSE="$HERMES_SCAFFOLD/compose.yaml"
for job in ld-morning-triage ld-morning-updates ld-weather ld-weekly-digest; do
  docker compose -f "$COMPOSE" exec -T "$HERMES_SERVICE" hermes cron run "$job" \
    || { echo "FAIL: activation run $job" >&2; exit 1; }
done
echo "activation runs dispatched"
```

## Objects

### Agent-side composition

- The Docker-host result of `seed-hermes-plow` + `seed-life-dashboard-hermes-agent`: the seed-hermes scaffold's container running with the `plow_chat` gateway activated (`PLOW_CHAT_*` in `data/.env`) and the `plow-connectors` skill installed, the seven `ld-*` producer skills copied into `<scaffold>/data/skills/`, one Hermes cron per producer registered, and `DASHBOARD_ENDPOINT_URL`/`DASHBOARD_TOKEN` landed in `<scaffold>/data/.env` (mode 600).

### Viewer-side composition

- The Pi-side result driven over SSH: `life-dashboard-viewer.service` + `life-kiosk-viewer.service` running, `.env` populated with `ICAL_URL`, `DASHBOARD_TOKEN`.

### Connection link

- The token-consistency invariant: the scaffold's `data/.env DASHBOARD_TOKEN` (the producers' write-side) and the Pi's `.env DASHBOARD_TOKEN` (viewer's read-side) MUST equal this SEED's [umbrella state file](#umbrella-state-file) `.dashboard_token` (the source-of-truth). The umbrella's [Verification](#verification) checks assert this invariant — it's the umbrella's primary post-install assertion.

### Umbrella state file

- `${SEED_LD_HERMES_STATE_DIR:-$HOME/.local/state/seed-life-dashboard-hermes}/state.json`, mode 600, owner-only (an XDG state path so the umbrella runs on a Linux or macOS Docker host alike). Records the install's Pi target, the derived message-API endpoint, the minted `dashboard_token`, and a timestamp. Written **at minting, before any recursion** ([rendezvous is minted](#rendezvous-is-minted)), so the source of truth exists before any child materializes a copy. The file is **secret-bearing** (it holds the live bearer token), so the mode-600 mktemp + atomic-rename write is load-bearing, not just hygiene — an interrupted run can never truncate the source-of-truth token while the agent and Pi hold materialized copies. Body shape:

```json
{
  "pi_ssh_target": "user@host",
  "endpoint_url": "http://<host>:5174",
  "dashboard_token": "<hex>",
  "installed_at": "<RFC3339-ts>"
}
```

### Activation baseline

- `${SEED_LD_HERMES_STATE_DIR:-$HOME/.local/state/seed-life-dashboard-hermes}/activation-baseline`: one `<card> <sha256>` line per rendered card slot (`1`–`4`), snapshotted by the activation block **before** it runs the producers. Carries hashes only — never card text. [Verification](#verification) step 6 requires every card to differ from it, which is what makes "populated" mean "populated by THIS run's producers" on a latest-per-card store with no timestamps.

## Actions

### Operator inputs are supplied by preflight

- The two operator-only inputs are declared in the [`### Requirements`](#requirements) table so the installer's [preflight](https://github.com/plow-pbc/openseed/blob/main/SEED.md#preflight-is-rendered) routes them **once, up front** into its generated prepare-script (the convention's two-artifact preflight); the operator runs it in their own shell, it lands them in the standard inputs file `~/.config/seed/seed-life-dashboard-hermes.env` (mode 600), and the installer sources + exports them **before any recursion runs**. There is exactly **one install path — agent-driven and one-shot**; the SEED never prompts interactively (no `/dev/tty` path, no interactive-vs-headless fork):
  - `LD_ICAL_URL` — the private calendar ICS URL. Acquisition recipe, surfaced by the preflight prompt (an operator otherwise stalls hunting for it): Google Calendar → Settings → [your calendar] → "Integrate calendar" → **"Secret address in iCal format"** — NOT the public address, which can omit event details (free/busy only, per the calendar's sharing settings) yet still passes the `BEGIN:VCALENDAR` fetch-check, silently producing a sparse dashboard.
  - `LD_PI_SSH_TARGET` — `user@host`, e.g. `odio@rpi5screen`.
- Both inputs are `tier-3` (open prose; only the operator knows them), so the prepare-script prompts for them (silent `read -s`) in its single up-front run — keeping the whole install within the convention's "ask everything early, then run autonomously" aspiration. The SEED itself only **consumes** the exported values; it does not re-collect them. The canonical `user@host` shape (e.g. `odio@rpi5screen`) is surfaced by the preflight so an operator doesn't paste a URL or a bare hostname.
- Each value MUST be **validated at the input boundary** — immediately after the installer sources the inputs file, **before** the first recursion (`seed-durable-ssh`) or any probe consumes a value — so a bad value fails fast before any SSH invocation: `LD_ICAL_URL` MUST be a non-empty, **single-line** `https://` URL — a first-time operator easily pastes the calendar's web page instead of its ICS feed, and a newline would later split the Pi's `.env` into a second injected assignment. Beyond the shape check, the URL is **fetch-validated**: `curl` it (`--max-time 10`) and require the body to contain `BEGIN:VCALENDAR`, so a wrong URL fails in ~10s instead of silently producing an empty dashboard (the viewer's `server.js` swallows a bad ICS fetch and renders nothing). Because the value is secret-bearing (a private calendar), it is fed to `curl` via a **mode-600 `-K` config file, not on argv** — argv is world-readable through `/proc/<pid>/cmdline` and `ps`, mirroring `ref/verify.sh`'s bearer-token handling — the body is drained by `awk` (never echoed, and no `pipefail` SIGPIPE window), and the failure message names the variable, not the value; `LD_PI_SSH_TARGET` MUST match the `user@host` allowlist (`[A-Za-z0-9_.-]`, neither side leading `-`), closing both the ssh option-injection surface and the operator copy-paste-injection surface — that check's executable site is the [rendezvous minting](#rendezvous-is-minted) block, which runs at this same boundary (the endpoint host derives from the target, and the agent recursion materializes that endpoint into secret files).
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
# recursion, the state write below) consumes the exported value.
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
TMP=$(mktemp "$STATE_DIR/state.json.XXXXXX")   # mktemp creates mode 600
trap 'rm -f "$TMP"' EXIT   # pre-rename failure (jq error, signal) cleans its orphan; SIGKILL/power-loss residue stays mode-600 and inert
jq -n --arg pi "$LD_PI_SSH_TARGET" --arg ep "$ENDPOINT_URL" \
   --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   '{pi_ssh_target: $pi, endpoint_url: $ep, dashboard_token: env.DASHBOARD_TOKEN, installed_at: $ts}' \
   > "$TMP"
mv "$TMP" "$STATE"
```

- The viewer recursion consumes `ICAL_URL` + `DASHBOARD_TOKEN` (landing in its `.env`; there is no `MESSAGE_API_URL` — the message backend IS the viewer's own server). The agent recursion consumes `DASHBOARD_ENDPOINT_URL` + `DASHBOARD_TOKEN`, which its installer writes into the seed-hermes scaffold's `data/.env` (mode 600) — the producers read both from the container environment; there is no Plow secrets mount.
- `http://` is deliberate: the endpoint lives on the household LAN or tailnet, and a Tailscale hostname is encrypted on the wire anyway — plaintext-LAN is the documented trade-off. A household whose Hermes container can't resolve the SSH hostname can set `LD_PI_SSH_TARGET` with an IP or tailnet FQDN instead.

### Environment is probed up front

The mid-install halts a first install can hit (unreachable Pi, missing Pi packages without passwordless sudo) MUST surface **at the start** — not three dependencies deep. The order is: inputs sourced + validated + rendezvous minted ([rendezvous is minted](#rendezvous-is-minted)) → the `seed-durable-ssh` recursion (first in `## Dependencies` — reachability and key auth proven, multiplexing landed) → the probes below → all remaining recursion. Any operator line the probes surface is handed back **once, consolidated, immediately after the inputs land** and before anything else installs. Probing early breaks nothing: everything below needs only the exported operator inputs.

1. SSH reachability and key auth: proven by the `seed-durable-ssh` recursion — no umbrella-side step; the probes below ride its multiplexed connection.
2. Pi system packages + sudo posture: run the viewer's system-packages probe (read from the viewer's SEED, already in the installer's host-side preflight cache, shipped over the SSH stdin transport) and `sudo -n true` now. Missing packages with passwordless sudo → nothing surfaces (the installer auto-runs the `apt` line at viewer time per [viewer is installed on the Pi](#viewer-is-installed-on-the-pi-over-ssh)); without passwordless sudo → the exact `apt` line joins the consolidated hand-back.

### Viewer inputs are derived

- The viewer's [`### Inputs`](https://github.com/plow-pbc/seed-life-dashboard-viewer/blob/main/SEED.md#inputs) are never re-collected from the operator — the installer **derives** them, immediately before recursing into the viewer, from the operator inputs and the minted rendezvous values ([rendezvous is minted](#rendezvous-is-minted)): `ICAL_URL` = `$LD_ICAL_URL`; `DASHBOARD_TOKEN` = the minted token verbatim. There is no `MESSAGE_API_URL` — the viewer's own server is the message backend, so it has no upstream to point at.
- The operator inputs were already validated at the input boundary ([operator inputs are supplied by preflight](#operator-inputs-are-supplied-by-preflight)), and the derived values above are pass-throughs of already-validated or umbrella-minted values — nothing is re-validated here. (A value that slips through still fails loudly downstream: the viewer's own `## Verify` calendar-proxy check and the umbrella's e2e smoke.)
- The derived values are exported for the viewer recursion only — never echoed, never on argv. The only file they reach is the viewer's own mode-600 `.env`, written **on the Pi by the viewer's Configure block**, not by this SEED.

### Viewer is installed on the Pi (over SSH)

The viewer is a declared SEED dep whose install host is the **Pi, not the Docker host**: its `### Hardware` declares the host "Reachable over SSH" and the installer satisfies it from `LD_PI_SSH_TARGET`. The transport itself — `user@host` allowlist validation (already satisfied at the input boundary per [rendezvous is minted](#rendezvous-is-minted), not re-run here), fail-fast reachability probe, TOFU `accept-new`, the Pi-side cache clone as the viewer's `$REPO_ROOT` (where its `install-report.json` also lands), every block over `ssh -- "$LD_PI_SSH_TARGET" bash -l -s` with the `printf %q` export preamble on stdin, and the display-and-announce gate applied locally before the wire — is the convention's [remote-host SEED dependency](https://github.com/plow-pbc/openseed/blob/main/SEED.md#remote-host-seed-dependency) rule (this SEED is its worked example), not restated here. Specific to this graph:

- Ongoing access is the `seed-durable-ssh` dep's job: key auth was proven at the start of the install, and every hop here rides its ControlMaster multiplexing — one authenticated connection across the viewer's blocks and the umbrella's verification.
- The login shell covers the *install blocks* only: the viewer's units hardcode `ExecStart=/usr/bin/node`, so Node must be system-installed — apt or NodeSource, not nvm-only — which the viewer's own probe and NodeSource hint already steer toward.
- **The install is autonomous — there is no opt-in flag and no manual checklist.** When the viewer's system-packages probe halts because the Pi is missing prerequisites, the installer runs the probe's *surfaced* `apt` line over SSH **only if the Pi grants passwordless sudo** (`sudo -n true`; a Pi configured with passwordless sudo has already opted into unattended administration), then re-runs the probe and continues; without passwordless sudo the halt stands and the operator runs the line once. A provisioned Pi passes the probe silently and installs end-to-end to a live kiosk with **no root step**: the viewer's units are rootless `systemctl --user` units, reboot-persistent via the Pi's autologin (it fails loudly if the user systemd manager isn't running rather than pretending the kiosk is enabled).

### Skills are activated (first run)

The install is NOT complete when the skills are merely on disk — it is complete when each dashboard producer has **executed** once in the Hermes runtime and the cards exist. This action is the root's single Phase-2 step (the block in [`## Dependencies`](#dependencies)); [Verification](#verification) step 6 asserts its observable outcome.

1. After every child recursion terminates `success` — the agent seed already registered one Hermes cron per producer (keyed by name) during its recursion — the installer snapshots the four card baselines over SSH and runs each card-producing job once host-side: `docker compose exec -T <service> hermes cron run <job>` for `ld-morning-triage`, `ld-morning-updates`, `ld-weather`, `ld-weekly-digest` (the activation block above). This is deterministic and needs no chat round-trip.
2. Each run lands its card on the dashboard — the `alert` (card `1`), `affirmation` (card `2`), `weather` (card `3`), and `digest` (card `4`) cards — through the same runtime path (the container's `/opt/data` mount, its `data/.env` credentials, the container network) the scheduled ticks will use.
3. The installer does not parse the cron run's output — the Pi store is the ground truth, asserted by Verification step 6. A populated store proves the whole producer chain: current skill code visible to the container, endpoint reachable *from inside the container* (not just from the Docker host), valid token, store writable.
4. Why this is a verification criterion and not a courtesy note: the failure class it catches is *silent* — skills installed but never executed (stale container-side copies, container-unresolvable endpoint host, unregistered crons). Every pre-condition check (files on disk, token equality, host-side smoke) passes in that state while the kiosk stays empty until 07:00 — or forever.
5. The install then **hands off to the owner**: once the kiosk is populated, [Verification](#verification) step 7 sends a one-time welcome over the `plow_chat` gateway and confirms it reached the owner's device (`delivered`), then prints the take-over summary. That send is gated on `state.json.handoff_sent_at`, so it happens exactly once — re-running verification never re-texts the owner. From that message on, the owner replies in the Hermes chat thread to take over two-way; that inbound reply is human onboarding, not part of the automated gate.

## Verification

1. **Each child's `## Verification` passed.** Recursion delegated this to each child SEED. This umbrella step asserts every child's terminal reason was `success` per the SEED convention's state machine — read from each child's `install-report.json` at its `$REPO_ROOT` (the installer cache for `seed-durable-ssh`, `seed-hermes-plow`, and `seed-life-dashboard-hermes-agent` on the Docker host; the Pi's cache clone, over SSH, for the viewer). Expected: all `success`.
2. **Token-consistency: agent ↔ umbrella state.** Does the `DASHBOARD_TOKEN` **value** in the scaffold's `data/.env` equal the umbrella state file's `.dashboard_token`? Value equality, whitespace-trimmed — the agent installer writes the `.env` line verbatim, so the RHS is compared after stripping the `DASHBOARD_TOKEN=` prefix. Compared in-process (the values never print). Expected: yes.
3. **Token-consistency: viewer ↔ umbrella state.** Does the SHA-256 of the Pi's `~/services/life-dashboard-viewer/.env DASHBOARD_TOKEN` value (extracted over SSH) equal the SHA-256 of the umbrella's state-file token? Compared via hash so the value never leaves the Pi in plaintext. Expected: yes.
4. **Units active + enabled.** SSH to the Pi and assert both `life-dashboard-viewer.service` and `life-kiosk-viewer.service` are `active` AND `enabled` (reboot-persistent) — closing the gap where the e2e smoke below proves the dashboard service serves but not that the kiosk unit is up or that either survives a reboot. The rootless `systemctl --user` namespace is the one supported install shape (the viewer SEED installs user units regardless of sudo availability). Expected: both active + enabled.
5. **End-to-end smoke.** POST a synthetic `{"card":"__umbrella_verify__","type":"probe","text":"<per-run-unique sentinel>"}` from the Docker host **directly** to `$endpoint_url/api/message` (from the umbrella state file), bearer supplied via a mode-600 curl `-K` config file (never on argv). The card is FIXED at `__umbrella_verify__` — the viewer's store is latest-per-card and exposes no DELETE, so a fixed card keeps the store bounded at one inert probe field; uniqueness lives in the *text*. It is **non-rendered** (not one of the numbered slots `1`–`4`), so the household's real cards are never overwritten and nothing appears on the kiosk. Then SSH to the Pi and `curl -fsS 'http://localhost:5174/api/message?card=__umbrella_verify__'` against the Pi's own localhost API — the same store the kiosk reads, with no proxy cache in the path (the old 60s type-keyed proxy-cache concern is gone; the GET reads the Pi's own store directly) — and assert the unique text round-trips. This proves host→Pi reachability of the published endpoint AND the full producer→store→kiosk read path. Expected: yes (sentinel visible end-to-end).

6. **Dashboard is populated by the producers (skills ran once, THIS run).** Within 600s of starting this check, do ALL FOUR rendered card slots — `1` (type `alert`), `2` (type `affirmation`), `3` (type `weather`), `4` (type `digest`) — return a non-null message of the slot's expected type from the Pi's own store (`curl 'http://localhost:5174/api/message?card=<c>'` over SSH) whose SHA-256 **differs from the activation baseline** (the per-card hashes the activation block snapshotted before running the producers)? The store is latest-per-card with no timestamps, so non-null alone would pass on a prior install's stale cards; the baseline comparison proves the producers executed **during this run**, in the Hermes runtime — which no on-disk or host-side check can prove. The umbrella's own smoke uses the non-rendered `__umbrella_verify__` card and never touches these slots. Expected: yes, all four non-null, correctly typed, and changed. A timeout, a missing baseline file, or a missing per-card baseline entry is a **verification failure** (terminal reason `failure`), not a cosmetic gap: it is exactly the silent-empty (or silently-stale) dashboard class this step exists to catch. Documented trade-off: a producer that re-emits byte-identical output on a re-run over an already-populated store (deterministic template, unchanged forecast) false-fails this check after 600s — the cards are agent-generated prose, so in practice output varies run-to-run; on a false-fail, re-run the install (a fresh agent turn regenerates the prose).

7. **Owner handoff delivered (final check).** Runs last, after step 6. First a **hard gate**: read `<scaffold>/data/gateway_state.json` and assert `.platforms.plow_chat.state == "connected"` — the chat is *bound* but Hermes only flows messages once *subscribed*; a not-connected gateway means the welcome would never arrive, so this FAILs. Then, **once-only across re-runs** (gated on `state.json.handoff_sent_at` — verification runs repeatedly and MUST NOT re-text the owner): if unset, POST `{"body":"<welcome/take-over text>"}` to `$PLOW_CHAT_BASE_URL/v1/chats/$PLOW_CHAT_CHAT_UID/messages` (the `PLOW_CHAT_*` values read from the scaffold's `data/.env`; the bearer rides a mode-600 curl `-K` config, never on argv or echoed — same hygiene as step 5) and capture the returned message `uid`; if already set, SKIP the send. Then **confirm delivery** by polling `GET .../messages` for that `uid`'s `status` every 5s for up to 45s: `delivered` (or `read`) → **PASS**; record `handoff_sent_at` (UTC RFC3339) + `handoff_msg_uid` into `state.json` (atomic mktemp-in-`STATE_DIR` + rename, mode 600, existing keys preserved via jq merge). The confirmation bar is `delivered`, not `sent`: `sent` only means the API accepted the message (necessary, not sufficient); `delivered` means it reached the device. A POST that returns non-2xx is a **FAIL**; a message still `sent` after 45s is a **WARN** (recipient device likely offline) that still records `handoff_sent_at` and does **not** hard-fail (the message is queued for delivery; failing the whole install over an offline phone would be wrong). Finally print a take-over summary — kiosk endpoint, Pi target (phone numbers masked to last-4 for CI-log safety), the producer cron schedule (weather 06:00, affirmation 07:00, alert 07:05, digest Sun 17:00), and "reply to the Hermes chat thread to take over." Expected: gateway connected, welcome `delivered` (or a one-time WARN if the owner's device is offline). `read`/inbound-reply is two-way onboarding that needs the human — it belongs in this prose, not the automated gate.

A deterministic bash implementation lives at [`ref/verify.sh`](ref/verify.sh).

## Feedback

(default)

## Open Items

- **Remote-host transport is now a convention rule.** openseed adopted [remote-host SEED dependency](https://github.com/plow-pbc/openseed/blob/main/SEED.md#remote-host-seed-dependency) (this SEED is its worked example) and the transport prose here collapsed to a pointer. Remaining destination: the convention referencing a reusable access dep (`seed-durable-ssh`) so parents stop wiring probe/keygen/copy-id themselves — tracked in [seed-durable-ssh's Open Items](https://github.com/plow-pbc/seed-durable-ssh/blob/main/SEED.md#open-items).
- **Host is a `## Dependencies` concern, not a separate `## Host` section.** A SEED's host (a Docker host; a Pi reachable over SSH) is a *requirement* — part of "everything needed before install" — so it lives in `## Dependencies` (hardware), where it already does; a `## Host` H2 would only duplicate it. The one distinct thing such a section reached for was a machine-parseable *transport* hint so the runner could auto-switch to SSH — now carried by the viewer's `### Hardware` "Reachable over SSH" line plus this SEED's [transport contract](#viewer-is-installed-on-the-pi-over-ssh), a runner/execution concern, not a duplicate requirements section.
- **Multi-household.** Each household installs its own umbrella copy; Mary's deployment, Sam's deployment, and so on are independent. No shared infrastructure across households in v1.
- **No uninstall action.** Convention default.
- **Single install path.** One path only — agent-driven and one-shot, normative in [operator inputs are supplied by preflight](#operator-inputs-are-supplied-by-preflight). The SEED carries no interactive `/dev/tty` prompt path; missing required inputs fail fast at the input boundary with a clear, secret-safe message.

## Non-Goals

- Not a backup / migration / rollback tool. SEEDs are install-only.
- Not Hermes itself — that's [`seed-hermes-plow`](https://github.com/plow-pbc/seed-hermes-plow). The agent half runs wherever the seed-hermes Docker scaffold runs (Linux or macOS), not Mac-only.
- Not a hosted multi-tenant backend. Each household's Pi serves its own.
