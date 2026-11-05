# Issue 19 container hardening VM acceptance

Date: 2026-11-05. Result: **pass** in a disposable secureblue VM using the
CPU image. This receipt covers the final backend hardening controls, TLS
forwarding and cleanup, and the post-reboot application lifecycle. It does not
qualify a physical host, a GPU, or model inference.

- Tested source commit: `0e1445709cb0825486b25a80289e5369977d4ed2`.
- Project version: `0.2.0`; source archive SHA-256:
  `a67b79fba116e142eeb5e3deba2ee45251f8d7d8f183dc7852544e47eac8b2c4`.
- OS: secureblue 44 kinoite-main-hardened; deployment
  `a21fc280bc53cfbb3c80622ec36cac9a1f574899623dadb731314c5c79efa817`.
- Kernel `6.19.14-300.fc44.x86_64`, Podman `5.8.2`, systemd `259`; SELinux
  enforcing.
- CPU image `docker.io/localai/localai:latest`, digest
  `sha256:c8556c4f7b6dd9b76e915d515ab5cfe5a765d8ea8fd3f0cf563f9c690b48a7f4`.
- Caddy image digest `sha256:84202bd39c87ddba4611c3c85e7cb9c96d529bd536acf96a6d66cee4057fe8a3`.

The first TLS installer attempt found no `podman compose` provider in the base
guest. The bounded diagnostic installed Fedora's `podman-compose` package inside
the disposable overlay, then reran the hardening and TLS checks in that same
overlay. The base image was unchanged. The retry and the complete runner exited
successfully with status `0`.

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
and conservative uninstall while preserving an unrelated container. TLS test
uninstall removed its test account through the production cleanup path without
a test-only removal fallback.

The run used a pinned SSH host key and a throwaway overlay. Its sanitized output
was saved as
`issue-19-vm-receipt-0e14457-20261105-run3.txt` in task scratch (SHA-256
`c8b401ddce75aa5ec30d3937308983d707434c356718fc865a0968d81d76f285`); no keys,
credentials, raw logs, or VM overlays are part of this repository.
