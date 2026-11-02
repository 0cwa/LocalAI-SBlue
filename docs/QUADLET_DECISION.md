# Quadlet decision: adopt later

Keep the existing backend unit and TLS Compose design for #2. Revisit Quadlet
when the generated lifecycle can preserve the existing container ownership and
writable-layer protections. This decision is based on the generator prototype,
not a secureblue host or GPU acceptance run.

Quadlet could remove the TLS Compose provider dependency and avoid rendering
Compose YAML. Its activation model can represent an idle install: omit
`[Install]` from the `.container` file. A proposed separate drop-in with
`WantedBy=default.target` expresses boot activation. Upgrades would preserve
the drop-in independently from active state, including enabled-but-stopped and
disabled-but-running cases. The generator handles the install section;
`systemctl enable` does not enable the generated transient service.

## Prototype and findings

The files in [`quadlet-spike/`](quadlet-spike/) are incomplete, non-deployable
examples for generator inspection only. They omit production paths, settings,
GPU devices, TLS trust material, and installer safeguards. Do not deploy them.
The backend and TLS accounts currently use the host network. A rootless network
belongs to one account, so the illustrative `.network` is not attached to
these separate-account containers; a shared network would need a separately
validated design. The root-owned HTTPS forwarding socket remains necessary.

A dry run of the local Podman Quadlet 5.8.9 generator with only these files in
`QUADLET_UNIT_DIRS` generated the backend and TLS services and a network service.
The backend command retained the three ownership labels, host networking,
`--userns keep-id`, and the requested group option. A separate activation
drop-in appeared in the generated service. This checks translation only: no
container, service manager, or live deployment was started or modified.

The generated container start uses `podman run --replace`, and its stop uses
`podman rm -v -f -i` by container name. Labels on a new container do not guard
those generated operations against an existing unrelated or legacy container
with the same name. `--rm` discards the writable layer when a container exits,
and `rm -v` can remove associated anonymous volumes. The current backend installer checks role, state path, and
name before replacement and refuses unowned containers; its stop command uses
label filters. An install-time check alone is insufficient for later direct
starts and stops. Until a design preserves those protections through every
lifecycle operation without losing legacy writable-layer data, adopting the
generated commands would weaken data safety.

A future migration must first prove safe handling of name collisions and
writable-layer data, preserve all four enabled/running combinations for each
unit, and validate name collisions, retained data, restart and stop, boot behavior,
the rootless account, linger, SELinux, TLS connectivity, and upgrade path in the disposable secureblue VM from #17. Migration must capture
states before changes and abort on ambiguous ownership. The user-provided VM
base image has not yet been identified. Repository and generator checks do not
prove runtime behavior or qualify a host or GPU.

Reference: [Podman 5.8 Quadlet documentation](https://docs.podman.io/en/v5.8.0/markdown/podman-systemd.unit.5.html).
