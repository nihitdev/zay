# zay

**Pacman with native AUR awareness.** zay is an Arch Linux package helper
written in Zig. It sends official repository operations to pacman and uses the
AUR RPC, Git, `.SRCINFO`, and makepkg for AUR packages. It does not wrap yay,
paru, or another AUR helper.

## Install

Build with Zig 0.16.0 on Arch Linux:

```sh
zig build
```

The executable is `zig-out/bin/zay`. To make it available system-wide:

```sh
sudo install -Dm755 zig-out/bin/zay /usr/local/bin/zay
```

The build links to the system libalpm. AUR builds also need pacman, Git,
makepkg, bsdtar, and sudo. Run zay as your normal user; it only uses privilege
elevation for pacman operations that need it.

## Use

```sh
zay -Ss firefox                 # Search repositories and AUR
zay -Si firefox                 # Show package information
zay -Sp firefox                 # Print a dependency plan; install nothing
zay -S firefox                  # Install a repository package
zay -S visual-studio-code-bin   # Review and install an AUR package
zay -Qm                          # List installed foreign packages
zay -Rns package                 # Delegate removal to pacman
zay -Syu                         # Upgrade only when an AUR partial upgrade is safe
```

zay follows pacman operation syntax where supported. Repository search results
come from the configured local sync databases; zay does not refresh them
automatically. Use pacman's normal refresh command when needed.

## AUR safety

AUR build files are executable code from package maintainers. On first use and
whenever the reviewed revision changes, zay identifies the untrusted files and
shows their contents or diff before asking to proceed. Approval is tied to the
exact Git commit. `--noconfirm` can skip the ordinary transaction confirmation,
but it never approves new or changed build files. If interactive review is
unavailable, zay stops safely.

AUR sources are built as the invoking user, never as root. zay checks pinned
`.SRCINFO` against AUR metadata, validates generated package identities and
versions, then passes selected artifacts to pacman. Split/debug artifacts are
validated too; only packages selected for the transaction are installed.
Official package operations and package removals are delegated to pacman.

`-Syu` checks installed foreign package versions before starting the pacman
upgrade. If an AUR package is outdated, zay refuses to start a partial upgrade.
Combined repository and AUR upgrades are not implemented yet.

## Output

zay keeps its own messages compact and pacman-like. On an interactive terminal,
informational markers, package names, versions, headings, warnings, and errors
use restrained color. Colors are disabled when `NO_COLOR` is set or output is
redirected. Pacman and makepkg output is passed through unchanged.

## What works

- `-Ss query`: search configured repository databases and the AUR.
- `-Si package...`: show repository or AUR package information.
- `-Sp package...`: resolve and print a dependency/build plan without changing
  the system.
- `-S package...`: install repository packages with pacman; acquire, review,
  build, validate, and install AUR packages.
- `-R...` and `-Q...`: delegate supported pacman remove/query operations.
- `-Syu`: block an unsafe partial upgrade when an installed AUR package has a
  newer AUR version; full AUR upgrades remain planned.
- `--help`, `--version`, `--noconfirm`, combined short flags, and common
  long-form operation options.

This is an actively developed Arch-specific tool, not a claim of complete
pacman compatibility. Unsupported options fail clearly. Mixed AUR transactions
currently accept basic package targets and `--noconfirm`; pacman-specific
options are not silently discarded.

## Development and tests

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test-integration
zig build test-planner
zig build run -- -Ss firefox
```

Unit tests cover CLI parsing, AUR responses, dependency planning, Git/cache
handling, `.SRCINFO`, review state, artifact validation, and transaction
bookkeeping. Offline integration tests use temporary data and a fake pacman;
they do not install/remove packages, execute PKGBUILDs, or contact the AUR.
Live searches and AUR builds are separate from the test suite.

## Current limits

- Combined AUR upgrades for `-Syu` are not implemented.
- The CLI supports a useful pacman subset, not every pacman option or mode.
- Repository data comes from the local pacman databases; zay does not refresh
  them for search, info, or planning.
- AUR builds execute upstream package scripts as the normal user after explicit
  review. Review reduces surprises; it does not sandbox those scripts.
- Use pacman directly for behavior zay does not yet support.

## Project layout

The implementation is split by responsibility: `cli.zig` parses operations,
`app.zig` routes commands, `catalog.zig` and `resolver.zig` plan dependencies,
`aur.zig` speaks AUR RPC, `srcinfo.zig` parses build metadata,
`aur_repo.zig` and `git.zig` acquire pinned sources, `review.zig` tracks
approved revisions, `builder.zig` prepares and validates builds, and
`transaction.zig` coordinates AUR installation. Official package management
is delegated through `pacman.zig` and the shared process layer.
