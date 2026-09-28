# Security policy

## Reporting a vulnerability

Please report security issues privately through [GitHub Security Advisories](https://github.com/nihitdev/zay/security/advisories/new).
Include the affected revision, the command or input that triggers the issue,
its impact, and any safe reproduction details. Do not include secrets or run a
proof of concept against another person's system.

Please do not open a public issue for an unpatched vulnerability. If private
advisory reporting is unavailable, contact the maintainer through the GitHub
repository before publishing details.

## Security boundaries

- AUR build files are untrusted executable code. Review is tied to the exact
  fetched Git commit; `--noconfirm` is not approval to execute changed files.
- zay must run AUR builds as the invoking user. It must not invoke makepkg or
  downloaded build scripts as root.
- External programs receive argument vectors. Do not interpolate package names,
  metadata, or paths into shell source.
- Tests must not install/remove host packages, execute arbitrary PKGBUILDs, or
  depend on network access. Use temporary directories and local repositories.

See [README.md](README.md) for implemented behavior and current limitations.
