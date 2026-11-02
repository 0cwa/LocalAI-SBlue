# Evidence, secrets, and data safety

## Evidence

Repository checks and mocks do not qualify a host, GPU, or model. Change support
claims only after a recorded, sanitized run on the relevant environment. A
receipt should identify versions, commands, and outcomes without hostnames,
addresses, tokens, certificates, model data, or personal paths. Describe what
was actually exercised and what remains unverified.

## Secrets

Never put credentials in shared configuration, generated units, process
arguments, tray output, examples, or fixtures. Project-generated summaries
must redact known sensitive fields. Upstream logs may contain secrets: do not
claim that arbitrary logs are safe, and review and sanitize them before sharing.

## Data safety

Recreate or remove a container destructively only for an isolated test install,
or with explicit authorization and a verified backup. Preserve legacy data in
a container's writable layer, or explicitly migrate it before recreation.
Treat configured persistent paths separately from scratch and temporary files.
