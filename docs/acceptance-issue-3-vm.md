# Secureblue lifecycle VM acceptance for issue 3

Date: 2026-11-05. Result: **pass** on a disposable CPU-only virtual machine.
This is not a physical-host, GPU, model-performance, full Caddy TLS, or other
secureblue-release qualification. A real clean-host run remains unverified.

- secureblue 44 kinoite-main-hardened, deployment
  `a21fc280bc53cfbb3c80622ec36cac9a1f574899623dadb731314c5c79efa817`;
  kernel `6.19.14-300.fc44.x86_64`, Podman `5.8.2`, systemd `259`.
- Project version `0.1.0`, source archive SHA-256
  `8204e1faac10b7c3a6ce8597b99f6848d71cb03cc1404ccbb67eedf57a3b7e2c`.
- CPU image `docker.io/localai/localai:latest`, resolved digest
  `sha256:ac48a6f50d9a7557df457c4abd886c0fd2eec74cc53265ecfce226393b6445f4`.
- SELinux enforcing; container-domain user namespaces requested. SSH and a
  guest-only firewall rule were enabled for test access; automatic boot-time
  OS updates were masked in the test image.

The run used `scripts/host-acceptance.sh --vm` with a pinned SSH host key and
a throwaway overlay. Each step had a timeout. The following checks passed:

1. Backend installer `--yes --enable-container-userns`; the service was neither
   active nor enabled after installation or reboot.
2. `localaictl start`, service-manager active/enabled state, `localaictl status
   --elevated`, `localaictl logs backend`, image digest and running-container
   inspection, and `localaictl doctor`.
3. Real first-admin registration on loopback; a temporary systemd test socket
   using the production guard was blocked before registration and active after.
4. Installer `--yes --no-pull` with service disabled/running, enabled/running,
   enabled/stopped, and disabled/stopped; service state was preserved in each.
5. Upgrades preserved the configuration and a persistent test marker;
   conservative backend uninstall `--yes` retained the marker and an unrelated
   test container.

No step failed in this run. TLS installation and Caddy listener behavior were
not exercised. Logs were discarded and no credential was recorded.
