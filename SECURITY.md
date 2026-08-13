# Security policy

## Report a vulnerability

Report security issues privately. Do not open a public issue for an unpatched vulnerability.

Use one of these methods:

- Open a [GitHub Security Advisory](https://github.com/BrunoSaPa/Epistoria/security/advisories/new).
- Email the address on the repository owner's GitHub profile.

Include:

- A description of the issue and its possible impact.
- Reproduction steps or a proof of concept that uses synthetic data.
- The affected component: iPad app, API, trusted Mac worker, or infrastructure.
- Any known preconditions or version information.

Do not include real recovery words, keys, tokens, exports, notes, or PDFs.

## Response expectations

Epistoria is a personal project. It has no paid security team or response service-level
agreement. The owner will review reports, investigate reproducible issues, and coordinate a
reasonable disclosure date when a fix is required.

## In-scope issues

- Encrypted synchronization and asset protocols.
- Device authentication, enrollment, and revocation.
- Plaintext disclosure through storage, logs, backups, or network handling.
- Key, recovery, export, or local database integrity failures.
- Conflict or sync behavior that can discard acknowledged data.
- Trusted worker and AI disclosure boundaries.

The bootstrap endpoint is designed for one-owner administration. It is not a general multi-tenant
authentication system.

## Out-of-scope activity

- Social engineering and phishing.
- Automated testing against a live personal deployment without written permission.
- Third-party dependency issues that have no project-specific impact or available upstream fix.
- Theoretical issues without a practical failure path.

## Disclosure

Keep technical details private until the owner provides a fix or agrees to disclosure. After the
advisory is resolved, coordinated public disclosure is permitted.

For a user-facing description of the product's data boundaries, see the public
[privacy overview](docs/public/PRIVACY.md).
