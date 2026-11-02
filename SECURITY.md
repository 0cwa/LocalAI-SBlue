# Security policy

## Reporting a vulnerability

Do not post credentials, private keys, exploitable details, or an unpatched
vulnerability in a public issue. Use GitHub's **Security and quality →
Advisories → Report a vulnerability** form for a private report. The repository
owner must enable private vulnerability reporting for the form to appear. If
the form is unavailable, open an issue asking maintainers for a private
reporting channel, but do not include vulnerability details in the issue.

Include the affected release or commit, the host environment, a concise impact
description, and safe reproduction steps. Redact public addresses, tokens,
account details, and certificate material that are not needed to demonstrate
the issue.

## Scope and response

Reports may cover the installers, service templates, configuration handling,
controller, tray, and release packaging in this repository. LocalAI, Podman,
systemd, secureblue, and other upstream components have their own reporting
channels; report issues there when the defect is upstream.

The maintainers will acknowledge a private report when they can and coordinate
disclosure after a fix or mitigation is available. This project does not
promise a particular response time or support for a specific release.
