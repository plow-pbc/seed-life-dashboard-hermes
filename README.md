# seed-life-dashboard

## Purpose

The umbrella SEED for the life-dashboard install graph. One invocation walks five SEEDs in dependency order and stitches them together across two machines (a Mac running Plow, a Raspberry Pi running the kiosk).

What gets installed:

- [`seed-durable-ssh`](https://github.com/plow-pbc/seed-durable-ssh) → durable unattended SSH access to the Pi, established **first**: key auth (`ssh-copy-id` once, only if a key-auth probe fails) + ControlMaster multiplexing every later SSH hop rides.
- [`seed-os-manager`](https://github.com/plow-pbc/seed-os-manager) → `seedctl` + Apple-Event TCC principal.
- [`seed-plow-app`](https://github.com/plow-pbc/seed-plow-app) → `/Applications/Plow.app` + first-launch activation (drives Messages.app to send the activation code; lands `plow-api-token`).
- [`seed-life-dashboard-agent`](https://github.com/plow-pbc/seed-life-dashboard-agent) → five `ld-*` skill bundles POSTed to plowd; dashboard secrets landed from the umbrella-minted values.
- [`seed-life-dashboard-viewer`](https://github.com/plow-pbc/seed-life-dashboard-viewer) → a declared SEED dep that installs **on the Pi** (its blocks run over SSH): `life-dashboard-viewer.service` + Chromium kiosk as rootless user units, `.env` wired with `ICAL_URL` + the minted `DASHBOARD_TOKEN` (the message backend is the viewer's own server).

The umbrella collects two operator inputs once at install time (tier-3 prompts; never echoed; persisted only in the mode-600 inputs file `~/.config/seed/seed-life-dashboard.env`, outside the repo):

- `LD_ICAL_URL` — your private calendar ICS URL (projected to the viewer's `.env` as `ICAL_URL`).
- `LD_PI_SSH_TARGET` — the Pi SSH target, e.g. `odio@rpi5screen` (consumed by the over-SSH viewer install).

`DASHBOARD_TOKEN` and the message-API endpoint are NOT prompted — the umbrella mints the token and derives the endpoint from `LD_PI_SSH_TARGET` automatically.

## Install

### What you'll need first

Gather these before you start — the install leans on a few accounts:

- **A Mac** (macOS ≥ 13) with **Messages.app signed in** — Plow's activation sends an iMessage to land your API token.
- **Your calendar's private ICS URL** — in Google Calendar: *Settings → [your calendar] → Integrate calendar → "Secret address in iCal format"* — NOT the public address, which can omit event details (free/busy only, per the calendar's sharing settings) and would silently produce a sparse dashboard. Treat it as a secret.
- **A Raspberry Pi** reachable over SSH **from the machine you run the install on** (the Mac — they're typically on the same home network) — it's the kiosk display, and it's required. Key auth doesn't need to exist yet: if a probe finds none, the prepare-script runs `ssh-copy-id` and you type the Pi's password once. Ideally the Pi is already provisioned with its system packages (`node` ≥ 20.6, `npm`, `git`, Chromium, the emoji font): the installer probes for them up front, and can only `apt`-install them for you if the Pi grants passwordless sudo — otherwise it hands you the exact `apt` line at the start, not mid-install.

### The hands-on moments

Most of the install is automated, but a couple of steps need you at the Mac's screen — they can't be scripted:

1. **macOS "Automation: Allow"** dialog on the Mac — once, so Plow can be driven via Apple Events.
2. **Messages signed in** on the Mac (and confirm any activation prompt on your Apple device).

### Run it

Tell any AI agent:

> Install `https://github.com/plow-pbc/seed-life-dashboard`

Or, from a Mac that already has the `seed-install` skill:

```
/seed-install https://github.com/plow-pbc/seed-life-dashboard
```

An agent without the `seed-install` skill should first fetch [openseed's `SEED.md`](https://github.com/plow-pbc/openseed/blob/main/SEED.md) and follow its installer contract — `SEED.md`'s [Dependencies](SEED.md#dependencies) declares this as an install-time prerequisite.

Install is **one-shot and agent-driven**: the `seed-install` skill's preflight reads the `### Requirements` table, routes your two inputs (the calendar ICS URL and the Pi SSH target) into a short prepare-script it generates — you run it **once, up front** in your own shell, and the values land in `~/.config/seed/seed-life-dashboard.env` (mode 600, off-transcript) — then walks the whole graph leaves-first and runs to completion with no further prompts. To replay fully unattended, the inputs file already satisfies the preflight (any input already set in the environment is skipped). The viewer is a declared SEED dep that installs **on the Pi**: the installer runs its blocks over SSH, autonomously, all the way to a **live, enabled, reboot-persistent kiosk** — rootless `systemctl --user` units, persistent via the Pi's autologin, no flag and no manual checklist. Pi reachability, key auth, and system packages (`node` ≥ 20.6, `npm`, `git`, Chromium, the emoji font) are all probed **up front**, immediately after your inputs land: anything that needs your hands — `ssh-copy-id`'s one password entry during the prepare-script, then a consolidated follow-up with any remaining line (a missing-package `apt` line on a Pi without passwordless sudo) — surfaces before anything else installs, and the rest of the install runs untouched (with passwordless sudo, the installer runs the `apt` line itself at viewer time).

## License

MIT
