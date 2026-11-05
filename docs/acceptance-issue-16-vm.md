# First-administrator and backend lifecycle VM acceptance for issue 16

Date: 2026-11-05. Result: **pass** in a disposable virtual machine. The
first-administrator test used a temporary systemd socket with the production
guard; a complete Caddy TLS deployment, physical host and GPU were not tested.

- OS: secureblue 44 kinoite-main-hardened; deployment
  `a21fc280bc53cfbb3c80622ec36cac9a1f574899623dadb731314c5c79efa817`.
- Kernel `6.19.14-300.fc44.x86_64`, Podman `5.8.2`, systemd `259`.
- Project version `0.1.0`; tested source archive SHA-256
  `61fe3aa21afb6c3c3c859f6bb706efd25e15e329888df14df5bbd3c4d2848231`.
- CPU image `docker.io/localai/localai:latest`, resolved digest
  `sha256:ac48a6f50d9a7557df457c4abd886c0fd2eec74cc53265ecfce226393b6445f4`.
- SELinux enforcing; container-domain user namespaces requested. The isolated
  guest had SSH access and a guest-only firewall rule, and its automatic
  boot-time OS update was masked.

The run used `scripts/host-acceptance.sh --vm` with a pinned SSH host key and
throwaway overlay. Installation remained idle through reboot. Explicit start,
health and a real loopback administrator registration passed; the test socket
was blocked before registration and active afterwards. The run passed upgrades
in all four enabled/disabled and running/stopped combinations, preserved config
and data, and completed conservative uninstall while preserving an unrelated
container. The test credential was generated in guest memory and not recorded.

The archive identifies the exact tested snapshot. Subsequent changes narrowed
malformed image metadata handling and renamed a shell variable; those changes
were covered by local mocked checks and are not claimed as VM-tested here.
