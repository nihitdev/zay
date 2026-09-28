# Changelog

Notable user-visible changes are recorded here. Versions follow the project's
`build.zig.zon` version.

## Unreleased

- Add AUR-aware search, package information, dependency planning, and reviewed
  AUR package build/install flow.
- Delegate official repository operations and local package queries/removals to
  pacman.
- Validate pinned `.SRCINFO`, package archive identity/version, and split/debug
  outputs before installation.
- Add concise terminal styling that respects `NO_COLOR` and redirected output.
- Add offline CLI/planner integration tests and maintainer verification scripts.
