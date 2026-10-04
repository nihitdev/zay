# Claude Code instructions

Before changing this repository, read [`AGENTS.md`](AGENTS.md). It is the
canonical source for zay's architecture, implemented behavior, coding rules,
security boundaries, and required checks. Follow it whenever working in this
project; do not infer that an AUR build or package operation is safe just
because it is technically available.

Keep changes focused, preserve existing work, inspect the installed Zig 0.16
toolchain before using uncertain APIs, and run the relevant offline checks.
Never run package installation/removal, a real system upgrade, or an AUR build
script during development unless the user explicitly asks for that host
operation.
