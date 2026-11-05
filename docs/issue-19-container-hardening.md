# Issue #19: backend container hardening

The generated backend invocation is being qualified with the following
settings. These choices remain provisional until the isolated VM lifecycle run
exercises API access, TLS forwarding, and outbound downloads.

| Control | Current choice | Evidence / qualification still needed |
| --- | --- | --- |
| Network namespace | `--network=pasta` with the configured host address and port published to the same container port | The API process listens on `0.0.0.0` inside the private namespace. Confirm loopback reachability, the host TLS socket proxy's route to Caddy and LocalAI, and outbound model/backend downloads in the VM. |
| Capabilities | `--cap-drop=all` | `--group-add=keep-groups` remains for device access. Confirm the GPU startup and inference lifecycle in the VM. |
| Root filesystem | `--read-only` | Configured application paths remain managed mounts per the [writable-path classification](../README.md) and issue #18; `/tmp` is a 2 GiB `nosuid,nodev` tmpfs. Confirm no other image path requires writes during startup or inference. |
| Privilege escalation | `--security-opt=no-new-privileges` | Already present; retained. |
| Process count | `--pids-limit=4096` | Already present; retained. Confirm startup and model worker behavior in the VM. |
| Memory | No container memory cap yet | A safe limit depends on the model workload and host memory. Select or explicitly defer after VM lifecycle and model qualification; no failure is claimed. |

The TLS forward socket remains a host systemd socket that proxies to the TLS
service. The backend's published port preserves the configured host address;
the VM run must confirm that Caddy can still reach that address after the
backend moves to `pasta`. Rootless `pasta` outbound connectivity is also a
qualification item, not a result inferred from the rendered unit.

Rendered-unit checks validate the requested flags and port mapping. They do not
qualify Podman behavior, TLS routing, backend downloads, GPU access, or writable
paths. A sanitized VM receipt is required before treating these settings as
qualified.
