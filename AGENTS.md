# zay development rules

## UX: pacman with native AUR awareness

- Preserve pacman-style commands, terminology, output, and behavior wherever
  practical. Delegate official repository operations to pacman.
- Keep normal output compact and script-friendly. Errors belong on stderr and
  should be concise and actionable; implementation/debug details do not belong
  in normal output.
- Prefer safe deterministic defaults over questions. Aim for one meaningful
  operation confirmation, without redundant confirmations.
- Do not add implementation-choice menus, decorative banners, spinners,
  dashboards, excessive colors, or long interactive questionnaires.
- Respect `NO_COLOR` and avoid added ANSI escapes in redirected output.
- When implementing mutating commands, respect `--noconfirm` for ordinary
  transaction confirmations. Never silently ignore it or reinterpret it as
  blanket authorization to execute untrusted AUR code.

## AUR trust boundary

- New or changed PKGBUILDs and associated build files are untrusted executable
  code. Identify them clearly and offer a concise review opportunity before
  execution, including relevant files or diffs.
- Combine review and operation consent where possible; do not add a questionnaire.
- `--noconfirm` must not bypass required trust approval. If approval for the exact
  build files is missing in a noninteractive invocation, fail with a concise
  instruction to review them interactively. Unavailable stdin is not consent.
- Never execute makepkg or downloaded build scripts as root. Elevate only the
  pacman operations that require it.

## Implementation discipline

- Inspect the installed Zig version and use its APIs. Keep modules focused and
  resource ownership explicit. Execute subprocesses with argument arrays, never
  shell interpolation of package data.
- Build, format, and run relevant safe tests for code changes. Do not run package
  installation/removal or AUR build scripts during development without explicit
  user authorization.
- Document only implemented features as working. The current read-only commands
  accept `--noconfirm` and pass it to pacman. Transaction confirmation and AUR
  review remain requirements for the future installation workflow.
