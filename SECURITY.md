# Security

The [protocol](docs/architecture/protocol.md) describes the
trust boundary. Independent review of the workload VM device policy has not
happened yet, so do not use privileged containers as a sandbox for untrusted code.

## Reporting a vulnerability

Do not open a public issue for a security problem. Use GitHub private
vulnerability reporting: the repository's Security tab, then "Report a
vulnerability". That opens a private advisory only the maintainer can read.

Include the Noodle version, what you did and what happened. Expect a first
reply within a week. Noodle is maintained by one person, so fixes ship as
patch releases and are credited in the changelog if you want that.

Supported versions: the latest release.
