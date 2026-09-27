#!/bin/sh
# Offline libalpm integration against synthetic databases; never host databases.
set -eu
zay=$1
case "$zay" in /*) ;; *) zay="$PWD/$zay" ;; esac
scratch=$(mktemp -d "$PWD/.zig-cache/zay-plan.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/bin" "$scratch/db/local/runtime-2-1" "$scratch/db/sync" "$scratch/packages"
export ZAY_TEST_DB="$scratch/db"
export ZAY_TEST_MUTATION="$scratch/mutation"
export https_proxy=http://127.0.0.1:1 HTTPS_PROXY=http://127.0.0.1:1
printf '9\n' > "$scratch/db/local/ALPM_DB_VERSION"
cat > "$scratch/db/local/runtime-2-1/desc" <<'DESC'
%NAME%
runtime

%VERSION%
2-1

%PROVIDES%
virtual=2

%ARCH%
any

DESC
cat > "$scratch/bin/pacman-conf" <<'MOCK'
#!/bin/sh
printf '[options]\nRootDir = /\nDBPath = %s/\nIgnorePkg = ignored\n[fixture]\nUsage = All\n' "$ZAY_TEST_DB"
MOCK
cat > "$scratch/bin/pacman" <<'MOCK'
#!/bin/sh
printf 'unexpected command\n' > "$ZAY_TEST_MUTATION"
exit 99
MOCK
chmod +x "$scratch/bin/pacman-conf" "$scratch/bin/pacman"
for tool in makepkg git sudo doas; do cp "$scratch/bin/pacman" "$scratch/bin/$tool"; done
# Arguments after name/version are complete desc-file fragments, not shell code.
package() {
  name=$1
  version=$2
  data=$3
  mkdir "$scratch/packages/$name-$version"
  printf '%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n%%ARCH%%\nany\n\n%s\n' "$name" "$version" "$data" > "$scratch/packages/$name-$version/desc"
}
package app 1-1 '%DEPENDS%
virtual>=2
'
package provider 3-1 '%PROVIDES%
virtual=3
'
package ignored 1-1 ''
package broken 1-1 '%DEPENDS%
missing-fixture-dependency
'
package conflict 1-1 '%CONFLICTS%
runtime>=2
'
package replacement 1-1 '%REPLACES%
runtime
'
(cd "$scratch/packages" && bsdtar -czf "$ZAY_TEST_DB/sync/fixture.db" *)
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
  [ ! -e "$ZAY_TEST_MUTATION" ]
}
check 0 -Sp app --noconfirm
cat > "$scratch/expected" <<'EXPECTED'
:: dependency plan (no packages will be installed)
Repository packages (1):
  fixture/app 1-1
Satisfied by installed packages: 1
EXPECTED
cmp "$scratch/out" "$scratch/expected"
[ ! -s "$scratch/err" ]
check 0 -S --print virtual
 grep -q 'fixture/provider 3-1' "$scratch/out"
check 2 -S app --noconfirm
grep -q 'use -Sp' "$scratch/err"
check 2 -Sp 'app>=2'
grep -q 'required version is unavailable' "$scratch/err"
check 2 -Sp ignored
grep -q 'ignored by pacman' "$scratch/err"
check 2 -Sp broken
grep -q 'repository dependency is unavailable' "$scratch/err"
check 2 -Sp conflict
grep -q 'conflicts with' "$scratch/err"
check 2 -Sp replacement
grep -q 'requires replacing' "$scratch/err"
check 2 -Sp 'app=>2'
grep -q 'invalid package target' "$scratch/err"
rm "$scratch/db/sync/fixture.db"
check 2 -Sp app
grep -q 'could not read package databases' "$scratch/err"
printf 'offline planner integration tests passed\n'
