# Contributing

Thanks for helping improve zay. Keep changes focused, explain the user-visible
reason for them, and preserve the project's pacman-like interface and AUR safety
boundaries.

## Development setup

- Arch Linux is the supported development target.
- Use Zig 0.16.0 and the system pacman/libalpm development files.
- AUR/runtime integration code may also need Git, makepkg, bsdtar, and sudo.
- Do not use another AUR helper as an implementation dependency.

## Before submitting

Run the maintainer check script:

```sh
scripts/check.sh
```

It formats-checks the Zig sources, runs Debug and ReleaseSafe unit tests, runs
the offline CLI and planner integrations, builds zay, and checks the diff.
Network access is not needed by the tests.

For behavior changes, add a regression test. Prefer pure tests, fake subprocesses,
temporary directories, and local Git repositories. Never run package install or
removal operations, execute an unrelated PKGBUILD, or mutate the host package
database in automated tests.

## Implementation expectations

- Use explicit argument arrays for subprocesses; never build shell commands from
  package input or metadata.
- Keep allocator ownership and error reporting explicit.
- Delegate official repository operations to pacman where appropriate.
- Treat AUR metadata and build files as untrusted. Do not weaken review or
  privilege boundaries to make a test pass.
- Keep normal output concise. Honor `NO_COLOR` and do not recolor subprocess
  output.
- Update README.md and CHANGELOG.md when supported behavior changes.

Open a pull request with a short problem statement, the resulting behavior, and
the checks you ran. See [SECURITY.md](SECURITY.md) for private vulnerability
reports and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for participation
expectations.
