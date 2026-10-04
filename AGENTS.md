# zay project guidance

This file is the canonical contributor and coding-agent guide for this
repository. Keep it accurate when behavior or architecture changes.

## Project goals

zay is a native Arch Linux AUR helper written in Zig. Preserve pacman commands
and terminology where practical, delegate official repository operations to
pacman, and implement AUR behavior directly. Never wrap yay, paru, or another
AUR helper.

Prioritize correctness, safety, deterministic behavior, maintainability, and a
compact pacman-like user experience. Keep normal output concise and
script-friendly. Respect `NO_COLOR`; do not emit ANSI colors to redirected
streams. Avoid banners, dashboards, spinners, unnecessary questions, and
implementation details in ordinary output.

## Current behavior

The supported CLI includes AUR-aware `-Ss` and `-Si`, local pacman query
operations including `-Qs`, `-Qi`, and `-Qm`, dependency planning with `-Sp`,
repository and AUR installs with `-S`, pacman removal operations such as
`-Rns`, and repository/AUR upgrades with `-Syu`.

Official package database, query, install, upgrade, and removal work belongs to
pacman. AUR search and metadata use the official RPC API. AUR install/upgrade
planning uses repository and AUR metadata, acquired Git revisions, pinned
`.SRCINFO`, review state, makepkg as the invoking user, package metadata
validation, and pacman for installation.

`-Syu` discovers installed foreign packages with pacman, compares versions
using libalpm semantics, reviews AUR build revisions before the repository
upgrade, and replans against the refreshed repository state. If replanning
requires an AUR base that was not reviewed, stop before building it. When an
AUR update is present, unsupported mixed pacman options or explicit targets
must fail clearly rather than being silently discarded.

These features do not make zay or AUR build instructions risk-free. Do not
describe the project as production-ready unless that status has been explicitly
established by maintainers.

## AUR trust and privilege boundaries

- Treat `PKGBUILD`, `.install` files, and other AUR build inputs as untrusted
  executable code.
- Before executing new or changed build files, show the relevant files or diff
  and require an explicit interactive approval tied to the exact Git revision.
- `--noconfirm` may skip ordinary transaction prompts; it must never approve a
  first-seen or changed build revision.
- Missing or non-interactive stdin is not consent to execute unreviewed build
  files.
- Never run `makepkg` or downloaded AUR code as root. Keep builds under the
  invoking user and elevate only pacman operations that need it.
- Never weaken TLS verification or execute PKGBUILDs to extract metadata.
- Do not run package installation/removal, a system upgrade, or AUR build
  scripts during development/testing unless the user explicitly asks for that
  host operation. Prefer local fixtures, temporary directories, and mocks.

## Implementation rules

- Inspect `zig version` before selecting Zig APIs. This project currently
  targets Zig 0.16.0; when uncertain, inspect `/usr/lib/zig/std/` and compile
  against the installed toolchain.
- Preserve the existing module responsibilities: `app` coordinates,
  `cli` parses structured operations, `pacman` and `process` handle external
  commands, `aur` handles RPC, `resolver` plans dependencies, `transaction`
  coordinates reviewed builds/installations, and `output` formats user output.
- Keep modules focused and ownership explicit. Use error unions and concise,
  actionable diagnostics rather than crashing on expected failures.
- Run external tools with explicit argv arrays. Never use shell interpolation
  or `sh -c` for package names, metadata, paths, or user input.
- Do not discard existing working-tree changes, rewrite unrelated history,
  change global Git settings, push, or release unless the user asks.
- Document implemented behavior only. Update `README.md` and `CHANGELOG.md`
  when supported behavior changes.

## Build and verification

Requirements are Arch Linux, Zig 0.16.0, and pacman/libalpm development files.
Git, makepkg, bsdtar, and an elevation helper are needed for relevant AUR
transaction operations.

Format and run the checks appropriate to the change. The full maintainer check
is:

```sh
scripts/check.sh
```

It checks Zig formatting, Debug and ReleaseSafe unit tests, offline CLI and
planner integrations, a build, and `git diff --check`. The tests must remain
network-independent and must not execute PKGBUILDs or alter the host package
database.

Useful individual commands:

```sh
zig fmt src tests build.zig
zig build
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test-integration
zig build test-planner
```
