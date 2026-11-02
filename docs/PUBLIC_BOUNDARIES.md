# Public release boundaries

The source checkout may retain historical audit notes, handoff material, PKI
planning, and local deployment artifacts for maintenance context. Those files
are not product documentation or a supported install procedure. The release
archive contains only the runtime, public configuration example, generic
documentation, and selected checks listed in `scripts/package-release.sh`.

Do not add local audit records, internal hostnames or addresses, root
certificates, private PKI notes, or service logs to the public manifest. Review
every manifest change for deployment-specific data before publishing a
release.
