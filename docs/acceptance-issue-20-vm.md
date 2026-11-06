# Backup and restore VM acceptance for issue 20

Date: 2026-11-06. Result: **pass** in a disposable virtual machine. This is
backend-only evidence; TLS, physical-host behavior and GPUs were not tested.

- OS: secureblue 44 kinoite-main-hardened; deployment
  `a21fc280bc53cfbb3c80622ec36cac9a1f574899623dadb731314c5c79efa817`.
- Kernel `6.19.14-300.fc44.x86_64`, Podman `5.8.2`, systemd `259`.
- Source commit `998681dcebca301bd4190ceb819fc671154fff70`; project version
  `0.2.0`; tested source archive SHA-256
  `19fa854a49df8c0e0b46298c1da2e013694b0ac8b578ad3b802b12aa7e31129c`.
- CPU image `docker.io/localai/localai:latest`, resolved digest
  `sha256:ac48a6f50d9a7557df457c4abd886c0fd2eec74cc53265ecfce226393b6445f4`.
- SELinux enforcing; container-domain user namespaces requested. The isolated
  guest had SSH access and a guest-only firewall rule, and its automatic
  boot-time OS update was masked.

The run used `scripts/host-acceptance.sh --vm` with a pinned SSH host key and a
throwaway overlay. Installation remained idle through reboot. Rootless archive
round-trip checks passed for setgid ownership, xattrs, SELinux labels, and host
UID/GID mappings. Explicit start, status, logs, image and container inspection,
doctor, and first-administrator registration passed; the guarded socket was
blocked before registration and active afterwards.

Backup and restore passed with root-owned configuration, persistent data and
GraphRoot markers, and SELinux checks. All four upgrade combinations passed:
running and boot-disabled, running and boot-enabled, stopped and boot-enabled,
and stopped and boot-disabled. The run preserved configuration, data, and an
unrelated container through conservative uninstall.

The bootstrap test credential was generated in guest memory and not recorded.
The archive digest identifies the tested source snapshot. The disposable
overlay was removed after the run.
