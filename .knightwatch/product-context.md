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

**This repo's `ref/` payload:** a single deterministic verifier (`ref/verify.sh`) for an umbrella that declares three direct external sub-SEEDs (`seed-durable-ssh`, `seed-life-dashboard-agent`, `seed-life-dashboard-viewer`; `seed-plow-app`/`seed-os-manager` arrive transitively through the agent) in dependency order — the viewer installing on the Pi over SSH per the `SEED.md` transport contract; reviewed as prose↔ref drift, not as nested sub-SEEDs. Operator inputs are collected once by the installer's preflight (one agent-driven path, no in-repo `/dev/tty` prompt script).
