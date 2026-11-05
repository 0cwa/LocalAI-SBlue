# Changelog

This file records changes relevant to users. It does not claim that a release
has been runtime-qualified on secureblue or on a GPU.

## Unreleased

- Probe all configured writable LocalAI paths inside the existing container and document which paths hold persistent data or scratch files.

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
