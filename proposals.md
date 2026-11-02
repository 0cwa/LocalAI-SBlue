# Current public-readiness roadmap

This file tracks open validation work, not a promised release schedule. User-
facing changes and completed work belong in [`CHANGELOG.md`](CHANGELOG.md).

## Open work

- Run the backend and optional TLS lifecycle on a clean secureblue host. Record
  service startup, stop, upgrade, and conservative uninstall behavior before
  calling the host path accepted.
- Qualify the AMD ROCm image and GPU path separately from repository checks;
  record the exact image digest and hardware used.
- Keep the support matrix limited to environments with recorded runtime
  evidence. CPU, Vulkan, and tray paths remain configurable options until they
  receive their own acceptance evidence.
- Consider pinning LocalAI and Caddy image digests after a known-good runtime
  has been verified.
