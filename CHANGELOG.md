# Changelog

This file records changes relevant to users. It does not claim that a release
has been runtime-qualified on secureblue or on a GPU.

## Unreleased

- Add tray endpoint diagnostics, safe endpoint copying, and warning-gated terminal log access that stays open for review while keeping backend and TLS states independent.
- Probe all configured writable LocalAI paths inside the existing container and document which paths hold persistent data or scratch files.

- Add protected `localaictl backup` and explicitly confirmed overlay restore,
  covering configured persistent paths and preserving ownership, modes, xattrs,
  ACLs, and SELinux labels.
- Include user service unit state in archives while requiring a byte-for-byte
  match with already installed unit entries before restore; restore does not
  install or reload unit definitions and refuses missing or changed entries.
- Match systemd paths at the configured service-home roots so inert unit files
  inside rootless Podman image layers do not block backups or get treated as
  active user unit definitions.
- Install the backup archive helper beside the tray controller so installed
  tray backup and restore commands work outside the source checkout.
- Store rootless Podman GraphRoot as a separately validated nested archive,
  create and extract it through the LocalAI user namespace, and roll back by
  same-filesystem no-replace renames with identity-checked cleanup.
- Retry only read-only rootless Podman and GraphRoot probes briefly after
  transient systemd user-bus errors; state-changing commands remain single-shot.
- Reduce VM restore acceptance failures to an allowlisted reason and source
  line numbers without retaining raw command output.
- Allow Podman to reassign dynamic rootless GraphRoot MCS ranges when restoring
  a same-host backup, while checking the stable SELinux identity and sensitivity.
- Include configured external GraphRoots, check backup/restore capacity on
  their actual filesystems, and refuse restores when the installed graph path
  or subordinate UID/GID mappings differ from the archive.
- Allow the installer's private 0750 service home while keeping GraphRoot
  descendants private, and require writable non-special GraphRoot root modes.
- Keep default rootless Podman GraphRoot ancestors private and ACL-free during
  installation so local users cannot traverse toward the store.
- Use the configured service account for rootless Podman inspection and add a
  durable restore marker that blocks backend startup after uncertain rollback.
- Bound archive member, path, pax metadata, and expanded-size processing; reject
  unsafe ownership, ACLs, and archived SELinux labels, and account for xattr/ACL
  bytes in destination and rollback capacity checks.
- Accept world-readable sensitive files only under archived directory chains
  that block world traversal; continue rejecting writable sensitive state.
- Omit the installer's regenerable state `build/` assets from backups and create
  backup acceptance markers with configured service-account ownership and
  verified SELinux labels.
- Preserve setuid/setgid bits in validated rootless image archives where
  namespace root maps to the service account; ordinary persistent paths still
  reject these bits.
- Validate rootless hardlink SELinux labels against their archived target when
  tar omits labels on hardlink entries; reject conflicting label metadata.

## 0.2.0

Qualification: repository checks for this release; a preceding 0.1.0 source snapshot passed disposable secureblue CPU VM lifecycle and first-admin checks. Physical host, GPU, and full Caddy TLS remain unverified.

- Record a disposable secureblue VM lifecycle acceptance run.

- Gate public listeners on completion of the first administrator bootstrap.
- Use the current upstream CPU image for VM acceptance.
- Keep image-declared LocalAI data volumes in labelled persistent Podman volumes.
- Add bounded host and disposable VM lifecycle acceptance with sanitized receipts.
- Leave new installations idle and preserve existing backend and TLS service states on upgrades.

- Record the Quadlet migration decision and generator prototype.

- Use one version source for packages and the controller, with attested tag-driven releases.

- Consolidate planning on the public roadmap and document evidence, secrets, and data safety.

- Run ShellCheck and Ruff in CI and when installed for local checks.

- Establish the public repository as canonical and check for deployment-specific data.

- Use a shared installed configuration and safer loopback, authentication, and
  registration defaults.
- Reject percent signs in configuration values to prevent systemd specifier
  expansion in generated environment settings.
- Add writable LocalAI path settings for backends, download staging, and
  backend scratch.
- Require LocalAI container role and state labels before replacing or removing
  an existing container; unlabelled legacy containers are refused for manual
  inspection and migration.
- Avoid account-wide Podman migration during install and keep images in use by
  containers; operators must inspect existing storage before manual migration.
- Make linger-only removal leave service-account processes running and require
  early account-scope confirmation before explicit user removal.
- Make the tray controller read current shared settings instead of a
  per-user install-time snapshot.
- Add public source packaging, security and contribution guidance, and
  portable repository checks.

## 0.1.0

Qualification: repository checks only; no secureblue host or GPU qualification.

- Initial public source snapshot.
