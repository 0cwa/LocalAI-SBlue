# Changelog

This file records changes relevant to users. It does not claim that a release
has been runtime-qualified on secureblue or on a GPU.

## Unreleased

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
