# zay

A small Arch Linux AUR helper in development, written in Zig 0.16.0.
Search, package information, and dependency planning work; this is **not production-ready**.
It implements its own AUR RPC client and does not depend on another AUR helper.

## UX principle

zay should feel like **pacman with native AUR awareness**. Preserve pacman's
commands, terminology, and repository behavior; use compact, script-friendly
output, concise actionable errors, and safe deterministic defaults. Prefer one
meaningful operation confirmation. Avoid questionnaires, implementation-choice
menus, decorative banners, spinners, and dashboards.

Supported commands accept `--noconfirm` and forward it when invoking pacman.
Read-only queries and plans require no confirmation. Future installation commands will respect the
flag for ordinary transaction confirmation. New or changed AUR build files still
require a clear untrusted-code notice and a concise review opportunity before
execution. `--noconfirm` does not
grant trust to those files; without the required approval, noninteractive builds
must fail safely and explain how to review them.

## Implemented

- `zay -Sp <package>...` (or `-S --print`) prints a non-mutating dependency plan.
  It prefers repository packages, checks installed satisfaction, resolves AUR
  runtime/make/check dependencies and providers, and orders builds by package base.
  Targets can include quoted version constraints, such as `'foo>=2'`.
- `zay -Ss <query>` searches the configured pacman sync databases and the live
  AUR RPC v5 `name-desc` endpoint. Repository results appear first. AUR results
  are sorted by name; names already returned by pacman are omitted from AUR output.
- `zay -Si <package>...` prefers packages in the configured repositories. Missing
  names are queried through batched AUR info requests. Every info block identifies
  its repository. Repeated targets are shown once.
- zay -Q... delegates pacman query operations using the original argument
  vector, preserving pacman query flags and exit status.
- `zay -S <package>...` installs repository packages through pacman and resolves
  AUR targets through the dependency planner. It fetches package-base Git data,
  validates pinned `.SRCINFO` against RPC metadata, displays first-seen or
  changed build-file review material, and requires approval for that exact
  commit before building. Builds run as the invoking user; package artifacts
  are checked with pacman and installed through `sudo pacman -U`.
- zay -R... delegates removals such as -Rns directly to pacman.
- zay -Syu checks installed foreign packages against AUR RPC versions before
  starting pacman. If an AUR package is outdated, zay refuses the partial
  upgrade. When no AUR version update is found, repository upgrade work is delegated.
- `--help`, `--version`, combined/separate short flags, `--`, and the long options
  `--sync`, `--remove`, `--query`, `--search`, `--info`, `--foreign`,
  `--refresh`, `--sysupgrade`, `--recursive`, `--nosave`, `--print`, and
  `--noconfirm`.
- Unsupported flags and combinations fail explicitly. Pacman remains
  responsible for transaction prompts and exit statuses for delegated
  operations; --noconfirm is passed through unchanged.
- Native HTTPS with certificate verification, status validation, an 8 MiB AUR
  body limit, encoded URL components, API error handling, and owned JSON data.
- Local Git acquisition primitives distinguish the local HEAD revision from a
  fetched upstream revision, reject dirty/mismatched repositories, and offer a
  no-checkout path for AUR cache repositories.
- A data-only .SRCINFO parser handles split packages, base/package scopes,
  repeated and architecture-qualified metadata, epoch versions, and resolver
  records. A pinned-revision loader checks package-base, package-name, version,
  and dependency/relationship metadata against the RPC snapshot.
- AUR terminal controls are sanitized. AUR search headings use color only on a
  terminal without `NO_COLOR`; redirected output contains no added ANSI escapes.
- Search shows package names, versions, descriptions and relevant status flags;
  votes and popularity are shown only in package info. Errors use plain-language
  messages, and pacman diagnostics are preserved without redundant summaries.

## Build and safe examples

Requires Arch Linux, Zig **0.16.0**, pacman (including libalpm headers/library and
pacman-conf), configured local sync databases, and system CA certificates.
The executable links to system libalpm and libc. Runtime AUR builds require
`git`, `bsdtar`, `makepkg`, and `sudo`. No Zig package dependencies are fetched.

```sh
zig build
zig build test
zig build test-integration
zig build test-planner
zig build test -Doptimize=ReleaseSafe
zig build run -- -Ss firefox
zig build run -- -Si firefox firefox-nightly
zig build run -- -Sp firefox aurutils
./zig-out/bin/zay -Q pacman
```

`zig build` installs the executable into `zig-out/bin/zay` inside this project.
It does not install anything into the host package database.

Unit tests cover parsing, malformed invocations, RPC envelopes/errors/nulls,
URL escaping, response/request limits, allocation failures, terminal text,
repository name extraction, and safe subprocess arguments/statuses. Offline CLI
integration tests use a temporary fake pacman, testing transaction delegation,
query forwarding, signals, missing executables, permission errors, and database failures. They never
install/remove packages, execute PKGBUILDs, or access the AUR. They require normal
Arch coreutils and `/bin/sh`. Live queries are deliberately separate from tests.
Planner unit tests additionally cover Arch version comparisons, versioned
providers, repository preference, dependency kinds, split package bases, cycles,
conflicts, replacements, reverse dependencies, and graph allocation failures.
`test-planner` uses synthetic local/sync databases and requires `bsdtar`. It checks
that no pacman, sudo, git, or makepkg process is launched by the planner.
Git acquisition, .SRCINFO parsing, review-state, and build-preparation tests use
local temporary repositories. They do not contact the network, run makepkg,
execute PKGBUILDs, or modify the host package database.

## Dependency planning

`-Sp` prints repository packages as one proposed pacman transaction, followed by
the AUR package bases in deterministic build order and their selected outputs.
It does not print pacman's download URLs. It never downloads build files, opens
a package transaction, refreshes databases, asks for confirmation, or installs
anything. Exit status is **0** for a complete metadata plan, **2** for failure.
Official repository targets are installed through pacman. AUR package bases are
built in graph order after metadata checks and review of each first-seen or
changed build revision. Approval is stored by package base and immutable commit
ID; `--noconfirm` cannot approve a changed revision. zay refuses to build AUR
packages when started as root. `-Syu` still refuses when it detects a newer AUR
package; combined AUR upgrades and source-only update detection are not yet
implemented.

The planner uses pacman-conf's resolved RootDir, DBPath, repository order, Usage,
IgnorePkg, and IgnoreGroup. It reads cached databases through libalpm and uses
`alpm_pkg_vercmp` for Arch versions, including epochs and package releases.
[libalpm dependency semantics](https://man.archlinux.org/man/libalpm_depends.3.en)
provide the underlying versioned package/provision model.

Selected packages are considered before installed satisfaction; unavailable
dependencies then prefer repository packages before AUR. The `base-devel`
metapackage is included as an AUR build prerequisite. AUR info/provider results
are cached within the plan. Exact names are preferred; a unique virtual provider
is selected without questions. Multiple unselected providers fail with an
instruction to specify a provider package explicitly. Versionless provisions
cannot satisfy version constraints.

Runtime, make, and check edges are separate. Selected split outputs share one
build and contribute their dependencies to that build. Intra-base runtime edges
are allowed; an unresolved intra-base make/check dependency fails rather than
guessing a bootstrap. AUR build cycles fail; repository runtime cycles are left
as part of a single proposed pacman transaction. Conflicts, replacements requiring
removal, ignored packages, and upgrades breaking retained installed consumers
fail explicitly.

The resolver is deliberately conservative, not complete:

- No solver backtracking, alternate version selection, removal planning, or
  automatic bootstrap. An incompatible earlier selection requires changing the
  requested package set, not silently changing a provider.
- No groups, repository-qualified targets, `AssumeInstalled`, `--needed`, or
  check-dependency suppression. `AssumeInstalled` configurations fail explicitly.
- Only selected/required split outputs are modeled. All build files and full
  `.SRCINFO` must be reviewed and reconciled before a future build; RPC metadata
  alone is not authorization to execute anything. Inconsistent split versions fail.
- A plan is a metadata snapshot, not a prepared pacman transaction. File conflicts,
  artifact signatures, architecture, disk space, and changes since planning must
  be checked by the eventual installation pipeline. Existing unrelated broken
  dependencies are not repaired. Cached database signatures are not revalidated
  during planning.
- Graphs are limited to 4096 packages. Provider searches with over 50 candidates
  fail rather than issuing unbounded requests.

## Semantics and limits

- Search currently accepts **one** nonempty query. Pacman uses regular expressions;
  AUR uses a name/description substring. The two sources can therefore return
  different matches. AUR may reject very short or excessively broad queries.
- Repository data is whatever pacman's configured local sync databases contain;
  zay does not refresh databases. Configured third-party repositories are included.
- Info accepts unqualified package names, not `repository/name`, groups, virtual
  dependencies, or version constraints. Repository inventory failure is an error,
  never a reason to assume a target belongs to AUR.
- Search/info exit codes: **0** successful match(es), **1** no matches or missing
  info target(s), **2** invalid usage, failed lookup, or incomplete results. AUR
  failure can leave useful repository output on stdout, but still returns 2.
  Local `-Q` queries preserve pacman's code; signals map to `128 + signal` (capped
  at 255). Diagnostics go to stderr; expected errors do not print stack traces.
- AUR info uses batches of at most 50 names and URLs of at most 8000 bytes.
  Oversized requests fail explicitly. Pacman captures are bounded to 16 MiB
  stdout and 1 MiB stderr.
- Standard HTTP(S)/ALL proxy variables are read through Zig's HTTP client.
  `NO_PROXY` bypass rules are not implemented. There is currently no application
  request deadline or retry policy; stalled connections use underlying OS/network
  timeouts. Redirects and compressed responses are rejected rather than followed
  or expanded implicitly.
- This remains a subset of pacman's CLI. Mixed AUR transactions currently
  support basic `-S` targets and `--noconfirm`; other pacman options are rejected
  rather than silently ignored. Custom pacman database/root settings are not
  integrated with AUR planning. Refresh, group, list, and query modes that zay
  does not combine with AUR behavior are delegated where recognized.
- AUR installation has not been exercised against a real package because that
  would execute third-party build code and mutate the host. Tests verify the
  components with inert local repositories and do not certify arbitrary AUR
  package behavior.

## Architecture

- `main.zig`: entry point and exit boundary.
- `app.zig`: command orchestration, source preference, batching, partial failures.
- `cli.zig`: operation/option/operand parser and validation.
- `process.zig`: explicit argv subprocesses, bounded capture, inherited I/O,
  termination status and ownership.
- `pacman.zig`: explicit-argv pacman calls and search-name extraction.
- `aur.zig`: RPC transport, encoding, envelope validation and owned responses.
- `package.zig`: transport-independent, borrowed package metadata.
- `output.zig`: AUR formatting and terminal sanitization.
- `diagnostic.zig`: concise user-facing error translations.
- `alpm.zig`: system libalpm bindings.
- `catalog.zig`: resolved pacman configuration, read-only database snapshot, and
  command-local AUR metadata cache.
- `dependency.zig`: dependency/provision syntax and Arch version constraints.
- `resolver.zig`: graph construction, safety checks, and build ordering.
- `planner.zig`: plan output and resolution diagnostics.
- `cache.zig`: XDG-derived repository, build, package, and review-state paths.
- `git.zig`: explicit-argv clone/fetch, origin and worktree checks, and separate
  local/upstream revision identities.
- `aur_repo.zig`: validated AUR package-base URLs, cache acquisition, pinned
  .SRCINFO loading, and RPC metadata reconciliation.
- `srcinfo.zig`: non-evaluating .SRCINFO parsing and split-package resolver
  records.
- `review.zig`: exact-commit review state, atomically stored per package base.
- `builder.zig`: pinned source preparation, non-root makepkg execution, and
  artifact path/identity validation.
- `transaction.zig`: AUR planning, review, build ordering, and pacman handoff.

Arguments and proxy configuration live for the command's lifetime. Each process
result and parsed RPC response owns its allocations and has explicit cleanup.
Package views borrow the owning response and cannot outlive it. No cache/config
framework is introduced before a command needs it. A planner-owned arena holds
snapshot strings/arrays; libalpm and RPC responses remain explicitly owned and
outlive the graph's borrowed records.

## Planned

Combined `-Syu` AUR upgrades, source-only AUR update detection, additional
pacman option compatibility for mixed transactions, and broader offline tests
remain planned. AUR code is untrusted and must never execute as root.
