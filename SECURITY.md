# Security policy

## Supported versions

SuperNotch is currently a pre-1.0 project. Security fixes are made on the latest `main` revision; older development snapshots are not maintained separately.

| Version | Supported |
| --- | --- |
| Latest `main` / newest release | Yes |
| Older snapshots | No |

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's **Report a vulnerability** flow in the repository's Security tab to create a private security advisory. Include:

- the affected revision or version;
- reproduction steps and required permissions;
- the expected and observed impact;
- relevant logs with credentials, clipboard content and personal paths removed;
- any suggested mitigation.

Maintainers will acknowledge a complete report as soon as practical, investigate it privately and coordinate disclosure after a fix is available. If private vulnerability reporting is temporarily unavailable, open a public issue that asks how to contact the maintainers without including security details.

## Sensitive areas

SuperNotch can observe clipboard content, execute commands explicitly entered by the user, expose selected files through temporary local links, use provider credentials for usage requests, modify a local Spotify installation after confirmation, and optionally install a privileged charge-control helper. Reports involving these boundaries are especially valuable.
