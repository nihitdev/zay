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
    <a href="#aur-safety">AUR safety</a> ·
    <a href="#development">Development</a>
  </p>
</div>

---

## What is zay?

zay combines familiar pacman-style commands with native AUR support.

| pacman handles | zay adds |
| --- | --- |
| Official repository operations | AUR search and package metadata |
| System package database | AUR dependency planning and builds |
| Package installation and removal | Review of untrusted AUR build files |

zay implements its own AUR functionality. It does not wrap yay, paru, or
another AUR helper.

---

## Install

Choose one of the following methods.

### 1. Manual installation — recommended

Build zay directly from the upstream source. This requires Arch Linux, Git,
the standard build tools, and Zig 0.16.0.

**Install prerequisites**

```sh
sudo pacman -S --needed base-devel git zig
```

**Clone and build**

```sh
git clone https://github.com/nihitdev/zay.git
cd zay
zig build -Doptimize=ReleaseFast
```

**Check the binary, then install it**

```sh
./zig-out/bin/zay --version
sudo install -Dm755 zig-out/bin/zay /usr/local/bin/zay
```

The build links to pacman's local package database through libalpm. A standard
Arch installation provides the required files with pacman.

### 2. Install the `zay-git` AUR package

The [`zay-git` package](https://aur.archlinux.org/packages/zay-git) builds zay
from the upstream `main` branch using makepkg.

**Install prerequisites**

```sh
sudo pacman -S --needed base-devel git zig
```

**Get the AUR package and review its build files**

```sh
git clone https://aur.archlinux.org/zay-git.git
cd zay-git
less PKGBUILD
less .SRCINFO
```

**Build and install as your normal user**

```sh
makepkg -si
```

`-s` asks pacman to install missing dependencies; `-i` installs the package
after a successful build. **Do not run `makepkg` as root.** The PKGBUILD is
executable code supplied by the AUR, so review it before building.

### Verify the installation

Use these commands after either method:

```sh
command -v zay
zay --version
```

---

## Commands

| Command | Behavior |
| --- | --- |
| `zay -Ss query` | Search configured repositories and the AUR |
| `zay -Si package` | Show repository or AUR package information |
| `zay -Sp package` | Resolve dependencies and print a plan without installing |
| `zay -S package` | Install a repository package or review and build an AUR package |
| `zay -Rns package` | Remove a package through pacman |
| `zay -Qm` | List installed foreign packages |
| `zay -Syu` | Upgrade repository packages and handle outdated AUR packages |

### Command-line behavior

- Search, info, planning, and install classification use the local pacman sync
  databases.
- Outside `-Syu`, zay does not refresh sync databases automatically. Refresh
  them with pacman when needed.
- zay supports a practical subset of pacman's CLI, not every operation or
  option. Unsupported combinations fail clearly.
- Long options may use one or two leading dashes, such as `-noconfirm` or
  `--noconfirm`. Compact options such as `-Syu` remain unchanged.

### AUR package installation

For an AUR target, zay:

1. Resolves dependencies and fetches the package base.
2. Checks pinned `.SRCINFO` against AUR metadata.
3. Presents new or changed build files for review.
4. Builds as the invoking user after approval.
5. Validates package identity and version before handing artifacts to pacman.

Official repository packages continue to use pacman directly.

### System and AUR upgrades

With `-Syu`, zay checks installed foreign packages against AUR versions using
Arch-compatible version comparison. Changed AUR build files are reviewed
before the repository upgrade begins. After pacman upgrades the system, zay
replans AUR dependencies against the refreshed repository state.

If replanning needs an AUR base that was not reviewed, zay stops the AUR part
safely and asks you to run `zay -Syu` again. Foreign packages without a
matching AUR RPC entry are left alone.

When AUR updates are present, zay accepts basic `-Syu` forms (including
`-Syyu` and long operation names) and `--noconfirm`. Unsupported option
combinations and explicit package targets fail instead of being discarded.
`--noconfirm` skips ordinary prompts for already reviewed revisions; it never
approves first-seen or changed build files.

---

## AUR safety

> AUR packages are community build recipes, not reviewed binaries. PKGBUILDs
> and related files can execute arbitrary code.

- New or changed build files are shown for review, with approval tied to the
  exact Git commit being built.
- `--noconfirm` does not approve a new or changed build revision.
- makepkg and package functions run as the normal user, never as root.
- Only pacman operations that need elevated privileges are run with elevation.
- Package artifacts are checked before zay passes them to pacman.

Review gives you a chance to inspect build instructions; it is not a sandbox.
AUR build code can access files and services available to your user. See the
[security policy](SECURITY.md) for reporting and project security boundaries.

---

## Development

### Requirements

- Arch Linux
- Zig 0.16.0
- pacman/libalpm development files
- Standard build tools
- Git, makepkg, and bsdtar for AUR transactions
- A privilege helper for pacman operations that require elevation

### Build and test

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

---

## Project links

- [AUR package](https://aur.archlinux.org/packages/zay-git)
- [Source code](https://github.com/nihitdev/zay)
- [Website](https://get-zay.vercel.app/)
- [Changelog](CHANGELOG.md)
- [Contributing guide](CONTRIBUTING.md)
- [Code of conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md)
- [GPL-3.0-or-later license](LICENSE)
