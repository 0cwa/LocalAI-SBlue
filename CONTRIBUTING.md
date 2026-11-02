# Contributing

Contributions should keep host changes narrow, preserve existing models and
certificate state, and make configuration values data-only. Do not add
personal deployment records, public addresses, credentials, private keys, or
local certificates to commits or release archives.

## Before submitting

Run the repository checks and package relocation validation:

```sh
make check
scripts/test-package-relocation.sh
```

These checks do not install services or qualify a secureblue host or GPU.
Describe any host-level validation separately, with the host details and
secrets removed.

For installer changes, document which files, accounts, services, labels, or
paths can change. Keep uninstall behavior conservative and state whether
models, certificates, and configuration are preserved.

## Configuration and releases

Use `config/localai.conf.example` for configuration examples. Keep secrets
outside the shared config; it is intended for non-secret runtime settings.
Update the explicit release manifest in `scripts/package-release.sh` when a
public runtime file, helper, or document is added. Check the generated archive
contents before including a new path.
