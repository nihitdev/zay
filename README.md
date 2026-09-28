<div align="center">
  <img src="website/public/favicon.svg" width="88" height="88" alt="zay logo">
  <h1>zay</h1>
  <p><strong>Pacman with native AUR awareness.</strong></p>
  <p>A small, native-feeling AUR helper for Arch Linux, written in Zig.</p>

  <a href="https://aur.archlinux.org/packages/zay-git"><img alt="AUR version" src="https://img.shields.io/aur/version/zay-git?style=for-the-badge&logo=archlinux&logoColor=white"></a>
  <a href="https://aur.archlinux.org/packages/zay-git"><img alt="AUR votes" src="https://img.shields.io/aur/votes/zay-git?style=for-the-badge&logo=archlinux&logoColor=white"></a>
  <a href="LICENSE"><img alt="License GPL-3.0-or-later" src="https://img.shields.io/github/license/nihitdev/zay?style=for-the-badge"></a>
  <a href="https://ziglang.org/"><img alt="Zig 0.16.0" src="https://img.shields.io/badge/Zig-0.16.0-f7a41d?style=for-the-badge&logo=zig&logoColor=white"></a>
  <a href="https://github.com/nihitdev/zay/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/nihitdev/zay?style=for-the-badge&logo=github"></a>
  <a href="https://github.com/nihitdev/zay/commits/main/"><img alt="Last commit" src="https://img.shields.io/github/last-commit/nihitdev/zay?style=for-the-badge"></a>

  <p>
    <a href="#install">Install</a> ·
    <a href="#commands">Commands</a> ·
    <a href="#security">AUR safety</a> ·
    <a href="#development">Development</a>
  </p>
</div>

---

zay combines pacman-style commands with its own AUR support. Official repository
operations stay with pacman; zay handles AUR search, dependency planning, source
review, and builds. It does not wrap yay, paru, or another AUR helper.

## Install

### From the AUR

The `zay-git` package is published on the [AUR](https://aur.archlinux.org/packages/zay-git).
On Arch Linux, install Git and the standard package build tools, then clone and
build the AUR package as a normal user:

```sh
sudo pacman -S --needed base-devel git

git clone https://aur.archlinux.org/zay-git.git
cd zay-git

# Read the build instructions before executing them.
less PKGBUILD
less .SRCINFO

makepkg -si
```

`makepkg -si` resolves the package's Zig build dependency and asks pacman to
install the finished package. **Do not run makepkg as root.** Check the current
[PKGBUILD and package metadata](https://aur.archlinux.org/packages/zay-git)
before each build; AUR build instructions are executable code.

After installation, verify zay is available:

```sh
zay --version
```

### Build from the upstream source

For development or to build directly from GitHub, use Zig 0.16.0 and the system
pacman/libalpm development files:

```sh
git clone https://github.com/nihitdev/zay.git
cd zay
zig build
./zig-out/bin/zay --version
```

To install that build system-wide:

```sh
sudo install -Dm755 zig-out/bin/zay /usr/local/bin/zay
```

## Commands

| Command | What it does |
| --- | --- |
| `zay -Ss query` | Search configured repository databases and the AUR |
| `zay -Si package` | Show repository or AUR package information |
| `zay -Sp package` | Resolve dependencies and print a plan without installing |
| `zay -S package` | Install a repository package or review/build an AUR package |
| `zay -Rns package` | Delegate package removal to pacman |
| `zay -Qm` | List installed foreign packages |
| `zay -Syu` | Check for AUR updates and refuse an unsafe partial upgrade |

zay uses the local pacman sync databases for repository search and planning; it
does not refresh them automatically. Use pacman to refresh databases when
needed. zay supports a practical subset of pacman's CLI, not every operation or
option. Unsupported combinations fail clearly.

### AUR-aware install

For an AUR target, zay resolves dependencies, fetches the package base, checks
pinned `.SRCINFO` against AUR metadata, and presents new or changed build files
for review. After approval, zay builds as the invoking user, validates the
resulting package identities and versions, and hands selected packages to
pacman. Official packages continue to use pacman directly.

### Upgrades

`-Syu` checks installed foreign packages against AUR versions before it starts
the official repository upgrade. If an installed AUR package is outdated, zay
stops instead of leaving the system in a partial-upgrade state. Combined
repository and AUR upgrades are not implemented yet.

## AUR safety

AUR packages are community build recipes, not reviewed binaries. PKGBUILDs and
related build files can execute arbitrary shell code.

- zay shows first-seen or changed build files and ties approval to the exact Git
  commit being built.
- `--noconfirm` does not approve new or changed build files.
- makepkg and package functions run as the normal user, never as root.
- Only pacman operations that need elevated privileges are run with elevation.
- Package artifacts are checked before zay passes them to pacman.

Review is a chance to inspect build instructions; it is not a sandbox. AUR
build code can access files and services available to your user. See
[SECURITY.md](SECURITY.md) for reporting and project security boundaries.

## Development

Requirements: Arch Linux, Zig 0.16.0, pacman/libalpm development files, and
standard build tools. AUR transaction code additionally uses Git, makepkg,
bsdtar, and a privilege helper for pacman installation.

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test-integration
zig build test-planner
scripts/check.sh
```

Tests use temporary directories, synthetic package databases, local Git
repositories, and fake subprocesses. They do not access the network, execute
PKGBUILDs, or install/remove host packages.

## Project links

- [AUR package](https://aur.archlinux.org/packages/zay-git)
- [Source code](https://github.com/nihitdev/zay)
- [Website](https://get-zay.vercel.app/)
- [Changelog](CHANGELOG.md)
- [Contributing guide](CONTRIBUTING.md)
- [Code of conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md)
- [GPL-3.0-or-later license](LICENSE)
