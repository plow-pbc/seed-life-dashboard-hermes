# seed-life-dashboard-hermes

## Purpose

The umbrella SEED for the **Hermes-based** life-dashboard install graph. One invocation walks four SEEDs in dependency order and stitches them together across two machines: a Docker host running the seed-hermes scaffold (the producer agent) and a Raspberry Pi running the kiosk.

What gets installed:

- [`seed-durable-ssh`](https://github.com/plow-pbc/seed-durable-ssh) → durable unattended SSH access to the Pi, established **first**: key auth (`ssh-copy-id` once, only if a key-auth probe fails) + ControlMaster multiplexing every later SSH hop rides.
- [`seed-hermes-plow`](https://github.com/plow-pbc/seed-hermes-plow) → the Docker Hermes scaffold (`compose.yaml`, `./data:/opt/data`), the `plow_chat` gateway (its one-time activation lands `PLOW_CHAT_*` in `data/.env`), and the `plow-connectors` skill the producers read Gmail / Google Calendar / Slack through. This is the producer runtime — there is no Plow desktop app and no local agent daemon in this graph.
- [`seed-life-dashboard-hermes-agent`](https://github.com/plow-pbc/seed-life-dashboard-hermes-agent) → the seven `ld-*` producer skills copied into `<scaffold>/data/skills/`, one Hermes cron per producer registered (`docker compose exec … hermes cron create`), and the dashboard secrets landed in `<scaffold>/data/.env` from the umbrella-minted values.
- [`seed-life-dashboard-viewer`](https://github.com/plow-pbc/seed-life-dashboard-viewer) → a declared SEED dep that installs **on the Pi** (its blocks run over SSH), reused unchanged: `life-dashboard-viewer.service` + Chromium kiosk as rootless user units, `.env` wired with `ICAL_URL` + the minted `DASHBOARD_TOKEN` (the message backend is the viewer's own server).

The umbrella collects three operator inputs once at install time (tier-3 prompts; never echoed; persisted only in the mode-600 inputs file `~/.config/seed/seed-life-dashboard-hermes.env`, outside the repo):

- `LD_ICAL_URL` — your private calendar ICS URL (projected to the viewer's `.env` as `ICAL_URL`).
- `LD_PI_SSH_TARGET` — the Pi SSH target, e.g. `odio@rpi5screen` (consumed by the over-SSH viewer install).
- `LD_OWNER_NAME` — the household owner's display name (personalizes the dashboard; consumed by the `seed-life-dashboard-hermes-agent` child to assemble its `ld-config`).

`DASHBOARD_TOKEN` and the message-API endpoint are NOT prompted — the umbrella mints the token and derives the endpoint from `LD_PI_SSH_TARGET` automatically, then exports both into the scaffold's `data/.env` so the producers post to the kiosk.

## Install

### What you'll need first

Gather these before you start:

- **A Docker host running the seed-hermes scaffold** — the producer agent runs in that container. Install [`seed-hermes-plow`](https://github.com/plow-pbc/seed-hermes-plow) (the umbrella does this for you) so the scaffold's `compose.yaml` is present and the container is up before the agent skills land. The host can be Linux or macOS.
- **A Plow Chat activation** — the `plow_chat` gateway needs a one-time phone-bind activation (satisfied by `seed-hermes-plow`'s `create_plow_chat_curl.sh`; it lands `PLOW_CHAT_*` in the scaffold's `data/.env`). The producers read external data and `ld-calendar-nudge` notifies the owner through that gateway.
- **Your calendar's private ICS URL** — in Google Calendar: *Settings → [your calendar] → Integrate calendar → "Secret address in iCal format"* — NOT the public address, which can omit event details (free/busy only, per the calendar's sharing settings) and would silently produce a sparse dashboard. Treat it as a secret.
- **A Raspberry Pi** reachable over SSH **from the Docker host** (they're typically on the same home network) — it's the kiosk display, and it's required. Key auth doesn't need to exist yet: if a probe finds none, the prepare-script runs `ssh-copy-id` and you type the Pi's password once. Ideally the Pi is already provisioned with its system packages (`node` ≥ 20.6, `npm`, `git`, Chromium, the emoji font): the installer probes for them up front, and can only `apt`-install them for you if the Pi grants passwordless sudo — otherwise it hands you the exact `apt` line at the start, not mid-install.

### The hands-on moments

Most of the install is automated, but a couple of steps need you on hand — they can't be scripted:

1. **Plow Chat activation** — confirm the one-time phone-bind from your device when `seed-hermes-plow`'s activation helper prompts.
2. **The Pi's password** — typed once if a key-auth probe finds none (`ssh-copy-id` during the prepare-script).

### Run it

Tell any AI agent:

> Install `https://github.com/plow-pbc/seed-life-dashboard-hermes`

Or, from a host that already has the `seed-install` skill:

```
/seed-install https://github.com/plow-pbc/seed-life-dashboard-hermes
```

An agent without the `seed-install` skill should first fetch [openseed's `SEED.md`](https://github.com/plow-pbc/openseed/blob/main/SEED.md) and follow its installer contract — `SEED.md`'s [Dependencies](SEED.md#dependencies) declares this as an install-time prerequisite.

Install is **one-shot and agent-driven**: the `seed-install` skill's preflight reads the `### Requirements` table, routes your three inputs (the calendar ICS URL, the Pi SSH target, and the owner display name) into a short prepare-script it generates — you run it **once, up front** in your own shell, and the values land in `~/.config/seed/seed-life-dashboard-hermes.env` (mode 600, off-transcript) — then walks the whole graph leaves-first and runs to completion with no further prompts. To replay fully unattended, the inputs file already satisfies the preflight (any input already set in the environment is skipped). The viewer is a declared SEED dep that installs **on the Pi**: the installer runs its blocks over SSH, autonomously, all the way to a **live, enabled, reboot-persistent kiosk** — rootless `systemctl --user` units, persistent via the Pi's autologin, no flag and no manual checklist. After every child installs, the umbrella drives each card-producing Hermes cron job once (`docker compose exec … hermes cron run`) so the four dashboard cards (1 alert, 2 affirmation, 3 weather, 4 digest) hold real data before [Verification](SEED.md#verification) asserts it. Pi reachability, key auth, and system packages are all probed **up front**, immediately after your inputs land.

## License

MIT
