# Product context

This is a **SEED-convention repo**: `SEED.md` and `README.md` (RFC-2119
prose) are the authoritative artifacts; `ref/` is a single-operator
reference implementation of that prose. Review for **convention conformance
and prose↔ref drift**, not for product-scale hardening.

Operating point (org default):

- **Stage:** pre-PMF, early. Iteration speed > hardening for scale.
- **Userbase:** fewer than 10 users, often a single operator. Abstractions,
  flags, parallel modes, and defensive edge-case handling sized for
  thousands of users are over-engineering here, not robustness.
- **Spec rigidity:** the SEED prose IS the contract; a handled edge case the
  spec never asked for is a cost, not a feature.

**This repo's `ref/` payload:** a single deterministic verifier (`ref/verify.sh`) for the **Hermes** umbrella that declares **five** direct external sub-SEEDs (`seed-durable-ssh`, `seed-hermes`, `seed-hermes-plow`, `seed-life-dashboard-hermes-agent`, `seed-life-dashboard-viewer`) in dependency order, in a **single-Pi (co-located) topology**: there is no separate Docker host. `seed-hermes` is the first software dep and a **remote-host dep on the Pi** — it **provisions** the producer-runtime scaffold there (clone + `prepare.sh` + ChatGPT `openai-codex` OAuth + `docker compose up -d` + ready-check), fixing the long-standing "nothing creates the scaffold" gap (#6); the `nousresearch/hermes-agent:latest` image runs natively (`linux/arm64`) on the Pi. `seed-hermes-plow` then installs the `plow_chat` gateway + `plow-connectors` skill **into that now-running scaffold** (the scaffold is no longer a precondition — it is created by `seed-hermes`); the `ld-*` skills land in `<scaffold>/data/skills/` and the derived `DASHBOARD_*` values in `<scaffold>/data/.env`, both on the Pi. Activation is install-host-driven over SSH (`docker compose exec … hermes cron run` **on the Pi**), not a chat POST. All four post-`seed-durable-ssh` deps install **on the Pi over SSH** per the `SEED.md` remote-host transport contract; their `install-report.json` is read from the **Pi's** cache clone. Reviewed as prose↔ref drift, not as nested sub-SEEDs. Operator inputs are collected once by the installer's preflight (one agent-driven path, no in-repo `/dev/tty` prompt script).
