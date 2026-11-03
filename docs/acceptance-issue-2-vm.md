# Backend lifecycle VM acceptance for issue 2

Date: 2026-11-03. Result: **pass**, in a disposable virtual machine. This is
backend-only evidence; TLS, physical-host behavior and GPUs were not tested.

- OS: secureblue 44, kinoite-main-hardened; deployment
  `a21fc280bc53cfbb3c80622ec36cac9a1f574899623dadb731314c5c79efa817`.
- Kernel: `6.19.14-300.fc44.x86_64`; Podman: `5.8.2`; systemd: `259`.
- Project version: `0.1.0`; source archive SHA-256:
  `91ad4cf083898497cffbda10b30664ec77dc0a913e71fcfb33455f43ade40041`.
- CPU image: `docker.io/localai/localai:latest-cpu`; resolved digest:
  `sha256:b9fb7ed9888ef401d49002dc3227686d39339b7f487ee5ff40cd2bd82191f271`.
- SELinux was enforcing. The test requested secureblue's container-domain
  user-namespace policy. The disposable guest had SSH access enabled, a
  guest-only firewall rule to restore SSH after reboot, and its automatic
  boot-time OS update masked.

The run used `scripts/host-acceptance.sh --vm` with a pinned SSH host key and a
throwaway disk overlay. It passed fresh installation without starting or
boot-enabling the service, idle state after reboot, explicit start, service
state, status, logs, image and running-container inspection, and the doctor
health check. A separately labelled unrelated container was created for the
preservation check.

All four upgrade combinations passed: running and boot-disabled, running and
boot-enabled, stopped and boot-enabled, and stopped and boot-disabled. The run
confirmed the shared configuration and persistent test data were unchanged.
Conservative uninstall completed successfully and preserved both the test data
and the unrelated container. The overlay was removed after the run.
