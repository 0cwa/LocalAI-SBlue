# LocalAI on secureblue

This repository installs LocalAI as a rootless Podman service managed by a
dedicated system account. An optional rootless Caddy service provides HTTPS,
and an optional desktop tray controls the same service facade.

The supported install path targets a normal secureblue host. The repository's
automated checks exercise parsers, controller behavior, templates, and package
contents; they do not qualify a live secureblue host, a GPU, or model
performance.

## Get the source

Clone the public repository and run the quick-start commands from its root:

```sh
git clone https://github.com/0cwa/LocalAI-SBlue.git
cd LocalAI-SBlue
```

## Quick start

1. Read the [prerequisites and support matrix](#prerequisites-and-support-matrix).
2. Copy and edit the data-only configuration example:

   ```sh
   cp config/localai.conf.example config/localai.conf
   ```

   The installer saves the shared installed configuration at
   `/etc/localai/localai.conf`. Keep `LOCALAI_BIND_HOST=127.0.0.1` unless you
   have a specific reason to expose the backend directly. Do not put passwords,
   API keys, or private keys in this file.
3. Install the backend from the host:

   ```sh
   cd secureblue-localai-install
   ./install.sh
   ```
4. Start only the loopback backend for the first administrator setup:

   ```sh
   cd ..
   bin/localaictl bootstrap-admin
   ```

   With the shipped settings, the endpoint is `http://127.0.0.1:11455`.
5. Open the local endpoint and register the intended administrator. LocalAI
   makes the first registered user an administrator, bypassing approval or
   invite requirements. Complete this step from the local machine before
   installing TLS. Then use `bin/localaictl doctor` and
   `bin/localaictl start` to check and start the configured stack.

The public HTTPS socket checks for an active administrator and an authenticated
loopback backend before binding. The internal Caddy listener must use loopback.
To expose the backend directly, first complete bootstrap on loopback, then
update the configuration and rerun the backend installer. An inaccessible or
unrecognized administrator database causes exposure checks to fail closed.
The shipped unit uses the SQLite database in `LOCALAI_DATA_PATH`; an external
authentication database is not supported by this bootstrap check.
If an older installation already has a public TLS listener or TLS-account
containers, inspect and stop them before bootstrap. The installer refuses to
start the backend while those existing resources cannot be verified; it does
not automatically stop an already-running legacy deployment.

The default configuration enables authentication and approval-based
registration. LocalAI supports `approval` and `invite` registration modes; see
its [authentication documentation](https://localai.io/docs/features/authentication/)
for current behavior.

## Prerequisites and support matrix

Run installers from a normal host session. Toolbox, distrobox, and Flatpak
sessions do not provide the host user manager, accounts, Podman storage, or
SELinux context that the installer configures.

| Area | Status | Requirements and limits |
| --- | --- | --- |
| secureblue host | Primary target | Uses `run0`, systemd user managers, SELinux, and rootless Podman. This repository's checks do not constitute a clean host acceptance run. |
| LocalAI backend | Supported by the install path | Uses the image selected in `localai/localai.lock` or `/etc/localai/localai.conf`. Model compatibility and performance depend on the selected image and model. |
| AMD GPU | Intended default | The default image is the ROCm/HIP build. The host needs compatible AMD drivers and access to `/dev/dri` and `/dev/kfd`; this repository does not claim GPU qualification. |
| CPU or Vulkan image | Configurable | Select another LocalAI image in the shared configuration. Hardware-specific behavior is not qualified here. |
| Optional HTTPS proxy | Supported when prerequisites are met | Requires a working `podman compose` provider, a configured public host, and client trust for the Caddy internal CA unless a static certificate chain is installed. |
| KDE/Qt tray | Optional | Requires host `/usr/bin/python3` with PyQt6 and an available system tray. The tray calls `localaictl`; it does not run Podman. |

The backend's direct HTTP listener defaults to loopback. The TLS socket uses an
explicit configured hostname or address; it does not use a wildcard default.
Only install the TLS socket on a network where the selected host and port are
intended to be reachable.

## Configuration

`/etc/localai/localai.conf` is the shared installed configuration. It is a
strict `KEY=VALUE` data file: do not quote values or use shell syntax. A
checkout can use `config/localai.conf` for local development. The example is
[`config/localai.conf.example`](config/localai.conf.example).
Literal percent signs are rejected because systemd expands `%` specifiers in
generated `Environment=` values; use only values that do not need percent
encoding.

Settings resolve in this order: defaults, config file, the process's original
environment, then explicit command-line overrides. Empty environment
placeholders are ignored. A same-process caller that reloads config should use
the loader's `localai_config_override` function for later changes.

For older installations, migration checks the existing shared config first;
when it is absent, an explicit `LOCALAI_CONFIG_FILE`, legacy
`/etc/localai.conf`, checkout config, and `localai/localai.lock` are considered
in that order. Existing shared config is preserved during upgrades. The
controller rereads the shared config for each command, so the tray follows
endpoint changes without reinstalling it.

The shared settings include persistent paths for models, downloaded backends,
download staging, backend scratch, application data, configuration, generated
content, uploads, cache, and logs. LocalAI uses the configured data directory
for its authentication database by default. See its
[CLI reference](https://localai.io/docs/reference/cli-reference/index.html)
for the current environment-variable names. Empty TLS config, cache, cert, and
Compose directory settings derive from `LOCALAI_TLS_STATE_DIR`; set a full
absolute path to keep one of those directories elsewhere.

The backend path probe first verifies the selected container's LocalAI
ownership labels and checks that each configured persistent path is mounted
from its exact host source to the same container destination. It also verifies
the managed volume mounted at `/backends`. The probe then runs inside that
existing container, using the service's rootless Podman storage, rendered
mounts, and container user. It checks create, write, read, and remove access
for each configured directory; missing or mis-mounted paths fail before any
write. The `LOCALAI_BACKENDS_PATH` bind is checked separately from the
image-provided `/backends` directory and the image's
`/var/lib/local-ai/backends` fallback.

| Path | Purpose and persistence expectation |
| --- | --- |
| `LOCALAI_MODELS_PATH`, `LOCALAI_BACKENDS_PATH` | Managed host bind mounts. Model and downloaded backend files persist across container restarts and upgrades; back them up if they matter. |
| `/backends` | Image-provided backend directory backed by a managed named volume. It is separate from `LOCALAI_BACKENDS_PATH`; inspect and preserve its contents during lifecycle changes. |
| `LOCALAI_DOWNLOAD_STAGING_PATH` | Managed bind mount for in-progress downloads. It survives container replacement, though incomplete staging files may be removed by LocalAI. |
| `LOCALAI_DATA_PATH` and `LOCALAI_AUTH_DATABASE_URL` | The data bind stores the authentication database by default. Preserve and back up the database with the data directory. |
| `LOCALAI_CONFIG_DIR`, `LOCALAI_GENERATED_CONTENT_PATH`, `LOCALAI_UPLOAD_PATH` | Managed bind mounts for configuration, generated content, and uploads. These survive container replacement and should be backed up when needed. |
| `LOCALAI_CACHE_DIR`, `LOCALAI_LOG_DIR` | Managed bind mounts. Cache files can be regenerated; logs persist at the configured path until rotated or removed. |
| `LOCALAI_BACKEND_TEMP_DIR` | Managed writable scratch bind. The directory remains mounted, but its temporary contents are not application state and may be cleared. |
| `/tmp` | Container scratch space. It is checked independently and is not persistent application storage. |
| Application `HOME` | A dedicated managed bind for application-local files. Keep required application state there; the service account's full host home is not mounted. |

The `/var/lib/local-ai/backends` image fallback is not the managed
`LOCALAI_BACKENDS_PATH` bind or the `/backends` image directory. The probe
reports it separately and does not write to it.

`LOCALAI_WEB_URL` and `LOCALAI_HTTPS_URL` are retained as accepted compatibility
keys. The controller derives its current endpoint from bind and TLS settings
instead of using those duplicate values.

## Install the optional HTTPS proxy

Choose a hostname that resolves to this host on the network where clients will
connect. Set `LOCALAI_TLS_HOSTNAMES` and, when the public socket is enabled,
`LOCALAI_TLS_PUBLIC_HOST` in the shared configuration. Then install the proxy:

```sh
cd localai-podman-compose
./install.sh
```

To bind the backend's direct HTTP listener to loopback while serving clients
through the proxy:

```sh
./install.sh --hide-direct-http
```

After installation, start the configured stack and check its components:

```sh
cd ..
bin/localaictl start
bin/localaictl status
bin/localaictl logs tls
```

Caddy uses its internal CA by default when no static certificate files are
present. If a static `fullchain.crt` is present, the installer verifies its
leaf certificate against the configured key. When
`LOCALAI_TLS_LEAF_KEY_PATH` is unset and the default key filename is absent,
it can adopt the single matching regular `.key` file in the configured
certificate directory. Static certificate paths must resolve inside the
existing Caddy bind mounts and be readable by the TLS service account. Caddy
validates the chain in-container before service activation; with `--no-pull`,
the image must already be available locally. Incomplete, invalid, unreadable,
or ambiguous static material stops the install instead of changing the trust
chain; set `LOCALAI_TLS_LEAF_KEY_PATH` to choose a key explicitly.

Clients must trust the public root certificate at
`/var/lib/localai-tls/caddy/pki/authorities/local/root.crt` before normal TLS
verification succeeds. Keep the CA state under `/var/lib/localai-tls` in
backups; replacing the CA requires clients to trust the new root certificate.

For an explicit health-check trust policy, use the local root certificate:

```sh
LOCALAI_DOCTOR_CACERT=/var/lib/localai-tls/caddy/pki/authorities/local/root.crt \
  bin/localaictl doctor
```

`doctor` uses normal certificate verification by default. The
`LOCALAI_DOCTOR_INSECURE=true` option is for a temporary diagnostic only.

## Service control and tray

From a repository checkout:

```sh
bin/localaictl status
bin/localaictl status --elevated
bin/localaictl start
bin/localaictl stop
bin/localaictl logs backend
bin/localaictl logs tls
```

A fresh install leaves the backend, optional TLS service, and optional
forwarding socket stopped and disabled. The application-menu launcher starts
the configured stack when selected; tray polling alone does not start it.
Service-account lingering can start the user managers without starting disabled
application units. On upgrade, existing service and socket states are retained.
If TLS configuration changes while its service is running, run `bin/localaictl restart`
to apply the changes.

To opt into boot activation, use the standard systemd enable commands for the
components you installed (omit TLS commands when TLS is not installed, and
omit the socket command when no public socket is installed):

```sh
run0 systemctl --user --machine=localai@.host enable localai.service
run0 systemctl --user --machine=localai-tls@.host enable localai-tls-compose.service
run0 systemctl enable localai-tls-forward.socket
```

These commands enable later boot activation. Use `bin/localaictl start` to
start the configured stack now. Use `disable` in place of `enable` to opt out.

The older start, stop, status, and logs scripts remain compatibility wrappers.
They use the same controller and preserve the separate `localai` and
`localai-tls` user managers.

Status reads are noninteractive by default. If a service manager is not
readable by the desktop user, the controller reports `unknown`; use
`bin/localaictl status --elevated` from a terminal to query through a `run0`
login shell. Tray polling always stays noninteractive and displays
“unavailable” for unknown manager state. Cross-user systemd manager access
has not been validated on every supported Secureblue release, so an unknown
state is not confirmation that the service is stopped.

To install the optional desktop tray after installing LocalAI:

```sh
cd localai-tray
./install.sh
```

The tray reports backend, TLS Compose, and HTTPS socket status independently,
opens or copies the current effective endpoint, and provides start/stop
controls. Endpoint values containing user information, query strings,
fragments, or paths are rejected before display or copying. **Run endpoint
health check** reports whether the endpoint answered, requires authentication,
or was unreachable. The tray reads shared configuration through `localaictl`
each time it checks status; polling never requests elevation. If a manager
state is unavailable, the tray suggests `localaictl status --elevated` in a
terminal. Backend and TLS log actions require confirmation first and then open
the logs in a terminal; logs may contain secrets and must be reviewed and
sanitized before sharing. The terminal stays open after the log command exits
until you press Enter, so the output remains available to review. Remove the
launcher with `localai-tray/uninstall.sh`.

## Lifecycle acceptance

A clean host or disposable VM can run the bounded lifecycle checks and produce
an allowlisted receipt. Host mode reboots automatically and refuses an
existing LocalAI installation. See [lifecycle acceptance](docs/ACCEPTANCE.md)
for setup, limitations, and resume instructions. The [VM acceptance receipt](docs/acceptance-issue-3-vm.md) records one CPU-only run; it does not qualify a physical host or GPU.

## Troubleshooting

| Symptom | Next step |
| --- | --- |
| Backend is inactive | Run `bin/localaictl status` and `bin/localaictl logs backend`. Check that the selected image can run on the host. |
| A component is `unknown` or the tray shows `unavailable` | The noninteractive status query could not read that manager. Run `bin/localaictl status --elevated` in a terminal; `unknown` is not proof that the service is inactive. |
| `doctor` reports HTTP 401 | The endpoint answered and authentication rejected the unauthenticated check. Use a protected token only when an authenticated check is required. |
| HTTPS certificate is untrusted | Install the Caddy root certificate on the client, or pass it through `LOCALAI_DOCTOR_CACERT` for the health check. |
| HTTPS socket is inactive | Check `bin/localaictl status`, `bin/localaictl logs tls`, the configured public host, port availability, and `podman compose version`. |
| AMD backend cannot access a GPU | Confirm the host driver, `/dev/dri`, `/dev/kfd`, and service-account access. A successful repository check does not establish GPU support. |
| Config load fails | Use one `KEY=VALUE` per line, no quoting, no shell expansion, valid absolute paths, and ports in `[1,65535]`. |

The TLS provider requires `podman compose`, not only `podman`:

```sh
podman compose version
```

## Backup, upgrade, and rollback

The backend installer labels containers with the LocalAI role, configured
state path, and container name. Install and uninstall refuse to stop or remove
a container unless all three labels match. Containers from older releases have
no ownership labels, so they are left running and the operation stops with an
error, including when `--purge-state` was requested. Inspect and back up any
data you need, then explicitly remove or rename an old container after review;
the installer does not adopt it automatically. Configured bind-mounted paths
hold persistent data. Files written elsewhere in a container's writable layer
are ephemeral and may be lost when its `--rm` container exits or is removed.

Installers do not run `podman system migrate` automatically because it can stop
every running container for the service account. If Podman reports that storage
migration is required, inventory and back up all containers and volumes for
that account, stop its running containers deliberately, run
`podman system migrate` as that account, then retry. If an installer needs to
add subordinate IDs while existing Podman storage is present, it stops before
changing the ID mappings and gives the same manual-migration guidance.
`--remove-image` also
uses non-force image removal; Podman leaves the image in place if any container
still uses it.

`--disable-linger` disables logind lingering without immediately terminating
service-account processes. Logind may retire the user manager after its last
session ends. `--remove-user` and `--all` ask for a separate account-wide
confirmation before terminating processes; this scope includes other
containers and services running as the dedicated service account. Passing
`--yes` with either option supplies that confirmation explicitly.

The LocalAI image directories `/backends`, `/models`, `/data`, and
`/configuration` use managed named Podman volumes under the service account’s
state directory. Upgrades refuse unrecognized existing volumes so their data
can be inspected and migrated safely before retrying.

Create a protected archive with `localaictl`:

The tray installation bundles the archive helper beside its controller, so
these commands also work outside the source checkout.

```sh
bin/localaictl backup /path/to/localai-backup.tar.gz
```

The command briefly stops active, verified LocalAI services, archives the
configuration and every configured persistent data path with numeric
ownership, modes, ACLs, extended attributes, and SELinux labels, then returns
services to their prior active state. Nested paths are stored once. The archive
records the configured backend and TLS image references and digests. Use
`backup --exclude-models` to leave the configured models directory out of the
archive; restoring such an archive leaves any existing models untouched. The
archive is created with mode `0600`.
Sensitive files may retain world-read bits only when every archived directory
from their configured root blocks world traversal; group/world write and
execute permissions remain unsafe.
Backup checks free bytes and inodes on both the private staging filesystem and
the archive destination, combining needs when they share a filesystem. The
estimate treats sparse files conservatively and may require space for their
expanded size.

When rootless Podman storage exists, backup stores it as a separate nested
archive created in the LocalAI account's `podman unshare` namespace. The
controller checks that the LocalAI account has no running containers before
reading or replacing that store. A GraphRoot outside the other persistent paths
is included as its own persistent root. GraphRoot mountpoints, nested mounts,
unsafe ancestry, or overlap with host user service-unit trees cause backup or
restore to stop before changing state. `--exclude-models` is refused if the
configured models path overlaps GraphRoot.
The installer keeps the default `$HOME/.local/share/containers` ancestors
service-owned, mode `0700`, and free of ACLs so other local users cannot
traverse toward the store. External GraphRoots must meet the same private
ancestry checks; backup and restore refuse to change a store that does not.

Backups contain the TLS CA private key and the LocalAI authentication database.
Store them as sensitive data. Restore into matching configured paths. It
rejects unsafe archive entries, privilege-bearing files, cross-path links, and
linked destination paths. Restore stages the archive on a disk-backed filesystem
after checking available space, then overlays archived files while preserving
unrelated files. If any archived path already exists, review the archive and
explicitly confirm the overlay:

```sh
bin/localaictl restore --yes /path/to/localai-backup.tar.gz
```

For a nested rootless GraphRoot, `--yes` also confirms replacing the complete
GraphRoot. Restore requires the matching GraphRoot to already exist and its
effective path plus UID/GID namespace mappings to match the backup. This binds
the backup to an installation with the same LocalAI subordinate ID mapping;
restoring it onto a host with different mappings is refused. Restore moves the
old GraphRoot aside on the same filesystem, extracts the validated inner tar
using `podman unshare`, and returns the old tree if restore fails. The inner
archive is never extracted as host root. Existing service unit trees remain
required on the destination host as described below.

Restore preserves validated ownership and non-SELinux xattrs. It rejects ACL
metadata and archived SELinux labels on ordinary persistent paths, then applies
and verifies the destination policy labels. Rootless GraphRoot SELinux labels
are accepted only when they match the stopped installed store. It starts
services in dependency order and restores their previous active state. `--yes`
does not remove unrelated files from state directories.

Before changing live state, restore writes a root-owned durable marker at
`/var/lib/.localaictl-backup-restore.pending`. The backend unit refuses to start
while the marker exists. A complete restore or verified rollback removes it. If
the process or host stops during an uncertain restore, backup, restore, and
backend startup stay blocked; keep the marker and the recorded original
GraphRoot rollback path for administrator recovery. Do not remove the marker
until the restored configuration, state, and GraphRoot have been verified.

User service unit files are included in backups, but restore never installs or
reloads archived unit definitions. Before changing any state, restore requires
every archived user-unit entry to match the already installed entry exactly;
missing or changed entries cause a refusal. On a new host, install the matching
LocalAI backend and TLS service units first. Restore does not reconstruct unit
definitions, and a unit tree excluded from the backup cannot be recovered by
this command. When the backend unit is present, restore also checks the archived
bind, authentication, and data database settings against the root-owned
installed unit template and the user manager's effective settings. A public
bind must retain authentication and the administrator bootstrap guard; restore
does not use the first-administrator loopback-only check for an already
configured public listener.

For an upgrade, keep a copy of the previous release and shared config, unpack
the new release, review changes to `config/localai.conf.example`, and rerun the
backend and TLS installers as needed. The installers preserve service state
unless a destructive purge option is selected. Pin image digests in the shared
config when you need to reproduce a specific backend image.
If an older project asset copy has another owner, the installer leaves that
copy untouched and uses the supplied release bundle; inspect the old copy
before removing it manually.

To roll back, stop the services, restore the previous release and shared
config, and rerun its installers to regenerate service files. Restore
`/var/lib/localai` or `/var/lib/localai-tls` only if the upgrade changed data
that must be reverted. Keep the TLS CA with the matching client trust setup.
Avoid `--all` or purge options unless removal of the corresponding state is
intended.

## Development and releases

Repository checks do not install host services or require a LocalAI account:

```sh
make check
scripts/test-package-relocation.sh
```

Create a source archive with:

```sh
make package
```

The `VERSION` file is the source for package names and `bin/localaictl --version`.
A release tag must match `VERSION` and have a matching changelog section with
its qualification level. A tag triggers checks, archive creation, SHA-256
checksums, and a build provenance attestation. Verify downloaded artifacts:

```sh
sha256sum -c localai-secureblue-0.1.0.tar.gz.sha256
gh attestation verify localai-secureblue-0.1.0.tar.gz --repo 0cwa/LocalAI-SBlue
```

Use the filenames for the release being verified. The release archive uses an explicit public-file manifest. Local deployment
records, private PKI notes, and local certificates are not included. See
[`SOURCE_PROVENANCE.md`](SOURCE_PROVENANCE.md),
[`docs/PUBLIC_BOUNDARIES.md`](docs/PUBLIC_BOUNDARIES.md),
[roadmap and milestones](https://github.com/0cwa/LocalAI-SBlue/issues/10),
[`docs/EVIDENCE_AND_SECRETS.md`](docs/EVIDENCE_AND_SECRETS.md),
[`CONTRIBUTING.md`](CONTRIBUTING.md), and
[`SECURITY.md`](SECURITY.md).
