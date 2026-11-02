# Lifecycle acceptance

`scripts/host-acceptance.sh` exercises an isolated LocalAI installation and
writes a sanitized receipt. It is destructive to its test installation: use a
clean machine or a disposable VM. The script refuses existing LocalAI service
accounts, shared configuration, installer metadata, service state, and managed
forwarding units. Never point it at a deployment you need to keep.

The receipt records mode, secureblue deployment checksum, kernel, Podman and
systemd versions, image reference and digest, and the command and outcome of
each bounded step. It does not include raw command output. A failed or timed-out
step stops the run. The receipt states when TLS has not been exercised; a VM
run does not qualify a physical host, a GPU, a model, or another secureblue
release. See [evidence and data safety](EVIDENCE_AND_SECRETS.md).

## Disposable VM

Provide a standalone qcow2 secureblue base with a root SSH public key already
installed, a corresponding private key, the guest's public SSH host key, and
an OVMF variables file. The guest must have SELinux enforcing and the debug
shell inactive. The script pins the host key, forwards SSH on loopback only,
creates a private qcow2 overlay and firmware-variable copy, and deletes both
when the run ends. The base is not modified. The guest needs enough writable
space for the CPU image. For the development run, the verified official
secureblue Kinoite ISO `secureblue-kinoite-main-hardened-20260502.iso` from
[secureblue's image service](https://isos.secureblue.dev/download?de=kinoite&nvidia=main)
was signature-verified and installed to a sparse 20 GiB base. Its SHA-256 is
`571324772d93c0e3d0ca90630888d4b4dc48265b933cdb68fc1a9cfad4f29e08`.
The boot-time OS updater was masked and a VM-only service restores the guest
firewall SSH rule after secureblue's boot cleanup for test access.

```sh
scripts/host-acceptance.sh --vm BASE.qcow2 SSH_PRIVATE_KEY OVMF_VARS SSH_HOST_PUBLIC_KEY
```

The command prints the receipt to standard output and progress to standard
error. It times out while waiting for boot, reboot and each lifecycle step.
Keep the base and keys outside the source tree; do not share private keys.

## Clean host

Host mode requests authorization once with `run0`, starts a root-owned
systemd runner, and **reboots the machine automatically** after installation.
Run it only on an isolated machine whose existing data is not needed by the
test. The runner requests secureblue's container-domain user-namespace policy
change if rootless Podman needs it. That policy change can persist after the
run; review and revert it separately when appropriate. The runner leaves the
application data and unrelated test container in place when checking
conservative uninstall. The asynchronous runner writes its
receipt and checkpoints under `/var/lib/localai-acceptance-run`; read the
receipt with `run0 cat /var/lib/localai-acceptance-run/receipt`.

```sh
scripts/host-acceptance.sh --host
```

If a named step fails, correct the cause and resume the same isolated run:

```sh
scripts/host-acceptance.sh --host --resume
```

The runner compares boot IDs before post-reboot checks and resumes completed
steps from root-owned checkpoints. A host-mode test performed inside a VM is
recorded as VM evidence. Never treat a VM or mocked run as GPU qualification.
