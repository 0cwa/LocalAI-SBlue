# Contributing

Contributions should keep host changes narrow, preserve existing models and
certificate state, and make configuration values data-only. Do not add
personal deployment records, public addresses, credentials, private keys, or
local certificates to commits or release archives.

## Before submitting

The checks require Bash, `make`, Python 3, and `ripgrep`. `shellcheck` and
`ruff` run when available; CI uses `shellcheck-py==0.11.0.1` and
`ruff==0.15.19`. If `desktop-file-validate` is installed, the check script
uses it; otherwise it checks the required desktop-entry keys directly.

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

## Canonical source and public changes

The public repository at https://github.com/0cwa/LocalAI-SBlue is the
canonical source. Develop on a branch of its current main and submit a pull
request; no export from the private archive is needed. This keeps reviews,
issues and releases connected to the same history. The old private checkout
is an archive, not a development source. Keep its deployment records and PKI
material outside this repository.

The public-tree check rejects private IPv4 and IPv6 addresses, internal hostnames,
user home paths, certificate or key files and PEM material. The generic
`localai.internal` and `/home/test-user` fixtures are permitted. Review changes
for secrets and deployment details too: automated checks cannot find every
sensitive value.

## Planning and evidence

The [roadmap and milestones](https://github.com/0cwa/LocalAI-SBlue/issues/10)
track planned work. Follow the [evidence and secrets policy](docs/EVIDENCE_AND_SECRETS.md)
when reporting results, handling credentials, or changing persisted data.
