# Source provenance

This repository starts from the reviewed release-candidate archive
`localai-secureblue-0.1.0-rc.1.tar.gz`, built from source commit
`1d4284d1d6eedde1712cab76bfbb6b4bacab6c9f`.

Archive SHA-256: `2b65b52cf23e3d64e7be7714e5af1569030d867b0fb48f868136b2abdd56064e`

The import creates fresh Git history. It contains the archive's allow-listed
files and the changes recorded on this export branch; earlier refs and history
were not copied. The export replaces developer-specific home paths in test
fixtures, uses a generic TLS key filename, and preserves static certificate
migration by matching the certificate public key. Static certificate paths are
constrained
to existing container mounts and checked for service-account readability.
Release archives normalize ownership metadata so the build host account is not
embedded in the public package.


The public repository is now the canonical development source. Changes start
on branches from its main branch and land through reviewed pull requests;
releases are built from this public tree. The earlier private checkout remains
an archive and is not exported into the public history. Repository checks help
prevent deployment-specific material from entering future changes.
