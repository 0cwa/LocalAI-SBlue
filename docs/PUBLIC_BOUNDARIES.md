# Public release boundaries

The public source checkout must not contain historical audit notes, handoff
material, PKI planning, or local deployment artifacts. The release archive
contains only the runtime, public configuration example, generic documentation,
and selected checks listed in `scripts/package-release.sh`.

Do not add local audit records, internal hostnames or addresses, root
certificates, private PKI notes, or service logs to the public manifest. Review
every manifest change for deployment-specific data before publishing a
release.
