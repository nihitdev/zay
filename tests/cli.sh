#!/bin/sh
# Offline boundary tests. Only this temporary fake pacman can be executed.
set -eu
zay=$1
case "$zay" in /*) ;; *) zay="$PWD/$zay" ;; esac
scratch=$(mktemp -d "$PWD/.zig-cache/zay-cli.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir "$scratch/bin"
export ZAY_TEST_ARGS="$scratch/args"
export ZAY_TEST_MODE=normal
cat > "$scratch/bin/pacman" <<'MOCK'
#!/bin/sh
printf '%s\n' "$@" > "$ZAY_TEST_ARGS"
case "$ZAY_TEST_MODE" in
  signal) kill -TERM "$$" ;;
  nonzero) exit 7 ;;
  malformed) printf 'malformed output\n'; exit 0 ;;
  inventory_error) printf 'database unreadable\n' >&2; exit 1 ;;
esac
case "$1" in
  -Qm) exit 0 ;;
  -Slq)
    if [ "$ZAY_TEST_MODE" = repo_target ]; then printf 'mangowm\n'; else printf 'firefox\n'; fi
    ;;
  -Si) printf 'Repository      : extra\nName            : firefox\n' ;;
  -S|-S*) exit 0 ;;
  -R*|--remove) exit 0 ;;
  -Q*) printf 'local query\n' ;;
  *) exit 99 ;;
esac
MOCK
chmod +x "$scratch/bin/pacman"
cat > "$scratch/bin/sudo" <<'MOCK'
#!/bin/sh
exec "$@"
MOCK
chmod +x "$scratch/bin/sudo"
check() {
  expected=$1
  shift
  actual=0
  PATH="$scratch/bin" "$zay" "$@" > "$scratch/out" 2> "$scratch/err" || actual=$?
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL: wanted %s, got %s for %s\n' "$expected" "$actual" "$*" >&2
    cat "$scratch/err" >&2
    exit 1
  fi
}
check 0 --help
check 0 --version
check 2 -Ss
check 0 -Syu
printf '%s\n' '-Syu' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/args"
check 0 -Rns firefox
printf '%s\n' '-Rns' 'firefox' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/args"
check 2 -Ss one two
check 0 -Qi -- '$(false); a b'
printf '%s\n' '-Qi' '--' '$(false); a b' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/args"
check 0 -Qi --noconfirm pacman
printf '%s\n' '-Qi' '--noconfirm' 'pacman' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/args"
check 0 -Qi -noconfirm pacman
printf '%s\n' '-Qi' '--noconfirm' 'pacman' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/args"
printf 'local query\n' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/out"
[ ! -s "$scratch/err" ]
check 0 -Q -- --noconfirm
printf '%s\n' '-Q' '--' '--noconfirm' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/args"
check 0 -S --noconfirm firefox
printf '%s\n' '-S' '--noconfirm' 'firefox' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/args"
ZAY_TEST_MODE=repo_target
check 0 -S mangowm
printf '%s\n' '-S' 'mangowm' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/args"
ZAY_TEST_MODE=normal
check 0 -Sg base
printf '%s\n' '-Sg' 'base' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/args"
check 0 -R --noconfirm firefox
printf '%s\n' '-R' '--noconfirm' 'firefox' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/args"
check 0 --remove --recursive --nosave firefox
printf '%s\n' '--remove' '--recursive' '--nosave' 'firefox' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/args"
check 0 -S -refresh -sysupgrade -noconfirm
printf '%s\n' '-S' '--refresh' '--sysupgrade' '--noconfirm' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/args"
check 0 -Si firefox firefox
[ "$(grep -c '^Name ' "$scratch/out")" = 1 ]
grep -q '^Repository *: extra' "$scratch/out"
check 0 --noconfirm -Si firefox
printf '%s\n' '-Si' '--color' 'never' '--noconfirm' '--' 'firefox' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/args"
ZAY_TEST_MODE=nonzero
check 7 -Q
ZAY_TEST_MODE=signal
check 143 -Q
ZAY_TEST_MODE=inventory_error
check 2 -Si firefox
printf 'database unreadable\n' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/err"
ZAY_TEST_MODE=malformed
check 2 -Ss --noconfirm firefox
printf '%s\n' '-Ss' '--color' 'never' '--noconfirm' '--' 'firefox' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/args"
grep -q 'could not read pacman output' "$scratch/err"
ZAY_TEST_MODE=normal
chmod -x "$scratch/bin/pacman"
check 2 -Q
grep -q 'permission denied' "$scratch/err"
rm "$scratch/bin/pacman"
check 2 -Q
grep -q 'executable not found' "$scratch/err"
printf 'offline CLI integration tests passed\n'
