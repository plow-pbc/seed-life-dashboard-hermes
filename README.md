# seed-life-dashboard-hermes

## Purpose

The umbrella SEED for the **Hermes-based** life-dashboard install graph. One invocation walks five SEEDs in dependency order and stitches them together on a **single Raspberry Pi** (co-located topology): the Pi runs the seed-hermes Docker scaffold (the producer agent, in a container) *and* the kiosk viewer (native). The install is driven from your laptop/workstation over SSH; that install host needs no Docker of its own.

What gets installed:

- [`seed-durable-ssh`](https://github.com/plow-pbc/seed-durable-ssh) → durable unattended SSH access to the Pi, established **first**: key auth (`ssh-copy-id` once, only if a key-auth probe fails) + ControlMaster multiplexing every later SSH hop rides.
- [`seed-hermes`](https://github.com/plow-pbc/seed-hermes) → **stands up the base Hermes scaffold on the Pi** — clones it on the Pi, runs `prepare.sh`, drives the one-time ChatGPT OAuth, pulls `nousresearch/hermes-agent:latest` (native `linux/arm64`, no qemu), and `docker compose up -d` so the `hermes` container is **running** with `./data:/opt/data`. This is the SEED that creates `compose.yaml` + the image + the live container — the thing nothing in the graph used to provide. It installs on the Pi over SSH.
- [`seed-hermes-plow`](https://github.com/plow-pbc/seed-hermes-plow) → the `plow_chat` gateway (its one-time activation lands `PLOW_CHAT_*` in `data/.env`) and the `plow-connectors` skill the producers read Gmail / Google Calendar / Slack through, installed **into the scaffold `seed-hermes` just provisioned** (it does not create `compose.yaml` or pull the image — that is now `seed-hermes`'s job). That scaffold is the producer runtime — there is no Plow desktop app and no local agent daemon in this graph. Also runs on the Pi over SSH.
- [`seed-life-dashboard-hermes-agent`](https://github.com/plow-pbc/seed-life-dashboard-hermes-agent) → the seven `ld-*` producer skills copied into `<scaffold>/data/skills/`, one Hermes cron per producer registered (`docker compose exec … hermes cron create`, on the Pi), and the dashboard secrets landed in `<scaffold>/data/.env` from the umbrella-minted values.
- [`seed-life-dashboard-viewer`](https://github.com/plow-pbc/seed-life-dashboard-viewer) → a declared SEED dep that installs **on the Pi** (its blocks run over SSH), reused unchanged: `life-dashboard-viewer.service` + Chromium kiosk as rootless user units, `.env` wired with `ICAL_URL` + the minted `DASHBOARD_TOKEN` (the message backend is the viewer's own server).

The umbrella collects three operator inputs once at install time (tier-3 prompts; never echoed; persisted only in the mode-600 inputs file `~/.config/seed/seed-life-dashboard-hermes.env`, outside the repo):

- `LD_ICAL_URL` — your private calendar ICS URL (projected to the viewer's `.env` as `ICAL_URL`).
- `LD_PI_SSH_TARGET` — the Pi SSH target, e.g. `odio@rpi5screen` (consumed by the over-SSH viewer install).
- `LD_OWNER_NAME` — the household owner's display name, how the dashboard refers to you (hard-required by the agent child, which assembles `ld-config` from it).

`DASHBOARD_TOKEN` and the message-API endpoint are NOT prompted — the umbrella mints the token and derives the endpoint from `LD_PI_SSH_TARGET` automatically, then exports both into the scaffold's `data/.env` so the producers post to the kiosk. The endpoint is the Pi's own LAN/tailnet address (`http://<pi-host>:5174`), NOT `localhost`: the producers run inside the Hermes container on the Pi, and the viewer's server listens on the Pi host — so the container reaches it as an ordinary outbound LAN/tailnet connection. (`localhost` would be the container's own loopback, and `host.docker.internal` doesn't resolve on every Docker substrate.)

## Install

### What you'll need first

Gather these before you start:

- **A Raspberry Pi** reachable over SSH from the host you run the install on — this is the **single machine** for the whole stack: it runs the Hermes scaffold container (the producer agent) AND the native kiosk viewer. The base scaffold is **not** a precondition you build yourself — [`seed-hermes`](https://github.com/plow-pbc/seed-hermes) (the umbrella runs it for you, first) creates `compose.yaml`, pulls the Hermes image, and starts the container on the Pi. The Pi needs Docker + Compose v2 (the `seed-hermes` dep installs the Compose plugin if it's missing) and its viewer system packages (`node` ≥ 20.6, `npm`, `git`, Chromium, the emoji font). The installer probes packages up front and can `apt`-install them only if the Pi grants passwordless sudo — otherwise it hands you the exact `apt` line at the start, not mid-install. The Hermes image is native `linux/arm64`, so it runs on the Pi without qemu. Key auth doesn't need to exist yet: if a probe finds none, the prepare-script runs `ssh-copy-id` and you type the Pi's password once.
- **A ChatGPT account** — the Hermes scaffold authenticates its model through ChatGPT's `openai-codex` OAuth device-code flow. `seed-hermes` opens a device page during the install; you approve it once in a browser (see [The hands-on moments](#the-hands-on-moments)).
- **A Plow Chat activation** — the `plow_chat` gateway needs a one-time phone-bind activation (satisfied by `seed-hermes-plow`'s `create_plow_chat_curl.sh`; it lands `PLOW_CHAT_*` in the scaffold's `data/.env`). The producers read external data and `ld-calendar-nudge` notifies the owner through that gateway.
- **Your calendar's private ICS URL** — in Google Calendar: *Settings → [your calendar] → Integrate calendar → "Secret address in iCal format"* — NOT the public address, which can omit event details (free/busy only, per the calendar's sharing settings) and would silently produce a sparse dashboard. Treat it as a secret.

### The hands-on moments

Most of the install is automated, but a few steps need you on hand — they can't be scripted:

1. **ChatGPT OAuth** — when `seed-hermes` provisions the scaffold it opens a ChatGPT device-code page; approve it once in your browser. (The device code is minted live, so it can't be collected up front like the other inputs.)
2. **Plow Chat activation** — confirm the one-time phone-bind from your device when `seed-hermes-plow`'s activation helper prompts.
3. **The Pi's password** — typed once if a key-auth probe finds none (`ssh-copy-id` during the prepare-script).

### Run it

Tell any AI agent:

> Install `https://github.com/plow-pbc/seed-life-dashboard-hermes`

Or, from a host that already has the `seed-install` skill:

```
/seed-install https://github.com/plow-pbc/seed-life-dashboard-hermes
```

An agent without the `seed-install` skill should first fetch [openseed's `SEED.md`](https://github.com/plow-pbc/openseed/blob/main/SEED.md) and follow its installer contract — `SEED.md`'s [Dependencies](SEED.md#dependencies) declares this as an install-time prerequisite.

Install is **one-shot and agent-driven**: the `seed-install` skill's preflight reads the `### Requirements` table, routes your three inputs (the calendar ICS URL, the Pi SSH target, and your display name) into a short prepare-script it generates — you run it **once, up front** in your own shell, and the values land in `~/.config/seed/seed-life-dashboard-hermes.env` (mode 600, off-transcript) — then walks the whole graph leaves-first and runs to completion (pausing only for the in-flow ChatGPT and Plow Chat approvals above). To replay fully unattended, the inputs file already satisfies the preflight (any input already set in the environment is skipped). `seed-hermes`, `seed-hermes-plow`, the agent, and the viewer are all declared SEED deps that install **on the Pi**: the installer runs their blocks over SSH, autonomously, all the way to a running Hermes container and a **live, enabled, reboot-persistent kiosk** — rootless `systemctl --user` units for the viewer, persistent via the Pi's autologin, no flag and no manual checklist. After every child installs, the umbrella drives each card-producing Hermes cron job once on the Pi (`docker compose exec … hermes cron run` over SSH) so the four dashboard cards (1 alert, 2 affirmation, 3 weather, 4 digest) hold real data before [Verification](SEED.md#verification) asserts it. Pi reachability, key auth, Docker/Compose, and system packages are all probed **up front**, immediately after your inputs land.

## License

MIT
