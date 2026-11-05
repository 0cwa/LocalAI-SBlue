# Issue 19 container hardening VM acceptance

Date: 2026-11-05. Result: **pass** in a disposable secureblue VM using the
CPU image. This receipt covers the backend hardening controls, TLS forwarding
and cleanup, manager-safe uninstall behavior, and the post-reboot application
lifecycle. It does not qualify a physical host, a GPU, or model inference.

- Tested source commit: `9e267a8bcbd7bf41d4473605ca6eb1baa4cacd3d`.
- Project version: `0.2.0`; source archive SHA-256:
  `8e76598a4d658ad03bedad89eafc85be75938dc01112bf50a88f5477b97b7a8e`.
- OS: secureblue 44 kinoite-main-hardened; deployment
  `a21fc280bc53cfbb3c80622ec36cac9a1f574899623dadb731314c5c79efa817`.
- Kernel `6.19.14-300.fc44.x86_64`, Podman `5.8.2`, systemd `259`; SELinux
  enforcing.
- CPU image `docker.io/localai/localai:latest`, digest
  `sha256:c8556c4f7b6dd9b76e915d515ab5cfe5a765d8ea8fd3f0cf563f9c690b48a7f4`.
- Caddy image digest `sha256:84202bd39c87ddba4611c3c85e7cb9c96d529bd536acf96a6d66cee4057fe8a3`.

The first TLS installer attempt found no `podman compose` provider in the base
guest and stopped at that preflight. The bounded diagnostic installed Fedora's
`podman-compose` package inside the disposable overlay, then reran the
hardening and TLS checks in that same overlay. The base image was unchanged.
The retry and the complete runner exited successfully with status `0`.

The backend started with `--network=pasta` and its configured loopback host
publication passed inspection and API health checks. The backend outbound
fetch passed. TLS installation, Caddyfile SELinux labeling, both systemd
services, and the internal and public listeners passed. HTTPS returned
`http-401` for the unauthenticated API and `http-200` for `/readyz`. The doctor
check returned `http-401` when given Caddy's local CA; its default system trust
check reported certificate validation failure, as expected for this local
test certificate. The test did not separately qualify Caddy-container
outbound downloads.

The rendered backend unit contained `--cap-drop=all`; both effective and
bounding capability masks were zero. The read-only root filesystem, `/tmp`
tmpfs, configured writable paths, denied root-filesystem write, and pids limit
passed. SELinux port apply and rollback passed for exact port `8443` and custom
port `18444`. The memory limit remains unset; no model workload was used to
choose one.

Post-reboot lifecycle checks passed explicit start and health, first-admin
bootstrap ordering and registration, all four enabled/disabled and
running/stopped upgrade combinations, configuration and data preservation,
and conservative uninstall while preserving an unrelated container. The TLS
test account was absent after uninstall through the production cleanup path;
no test-only removal fallback was used. The process check now identifies the
user manager by its reported main PID, executable, UID and init cgroup instead
of trusting process arguments, and uninstall removes only its owned,
exact-target enablement links.

The run used a pinned SSH host key and a throwaway overlay. Its sanitized output
was saved as
`issue-19-vm-receipt-9e267a8-20261105-run1.txt` in task scratch (SHA-256
`9c79f98756b0b637e8cfc33a046266232fc88af5bcaf0ea29c8dcf57cf644bf5`); no
keys, credentials, raw logs, or VM overlays are part of this repository.
