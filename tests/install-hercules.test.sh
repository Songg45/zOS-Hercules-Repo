#!/usr/bin/env bash
# Exercise the installer with mocked system operations, including reboot.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/hercules-install-test.XXXXXXXX")
cleanup() {
    case $test_root in
        "${TMPDIR:-/tmp}/hercules-install-test."*) rm -rf -- "$test_root" ;;
        *) printf 'Refusing to clean an unexpected test path.\n' >&2 ;;
    esac
}
trap cleanup EXIT
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export HERC_TEST_SCRIPT="$repo_root/scripts/install-hercules.sh"
export HERC_TEST_HOME="$test_root/home"
export HERC_TEST_FIXTURES="$test_root/fixtures"
export HERC_TEST_LOG="$test_root/operations.log"
mkdir -p "$HERC_TEST_HOME" "$HERC_TEST_FIXTURES"
printf '# existing profile without final newline' > "$HERC_TEST_HOME/.bashrc"

cat > "$HERC_TEST_FIXTURES/autogen.sh" <<'AUTOGEN'
#!/usr/bin/env bash
set -eu
printf 'autogen\n' >> "$HERC_TEST_LOG"
[[ ${HERC_TEST_FAIL:-} != autogen ]]
AUTOGEN
cat > "$HERC_TEST_FIXTURES/configure" <<'CONFIGURE'
#!/usr/bin/env bash
set -eu
printf 'configure:%s\n' "$*" >> "$HERC_TEST_LOG"
[[ ${HERC_TEST_FAIL:-} != configure ]] || exit 42
printf '#define CCKD_BZIP2 1\n' > config.h
if [[ ${HERC_TEST_FAIL:-} != missing-feature ]]; then
    printf '#define HAVE_REGINA_REXX 1\n' >> config.h
fi
CONFIGURE
chmod +x "$HERC_TEST_FIXTURES/autogen.sh" "$HERC_TEST_FIXTURES/configure"

# Run in a separate Bash process so expected failures still exercise errexit.
cat > "$test_root/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
source "$HERC_TEST_SCRIPT"
hercules_require_root() { :; }
getent() { printf 'fixture:x:1234:1234::%s:/bin/bash\n' "$HERC_TEST_HOME"; }
apt-get() {
    printf 'apt:%s\n' "$*" >> "$HERC_TEST_LOG"
    if [[ ${HERC_TEST_FAIL:-} == packages && $1 == install ]]; then return 42; fi
}
git() {
    if [[ $1 == clone ]]; then
        printf 'clone\n' >> "$HERC_TEST_LOG"
        mkdir -p "$3/.git"
        cp "$HERC_TEST_FIXTURES/autogen.sh" "$HERC_TEST_FIXTURES/configure" "$3/"
    elif [[ $3 == remote ]]; then
        printf '%s\n' "${HERC_TEST_ORIGIN:-https://github.com/SDL-Hercules-390/hyperion.git}"
    elif [[ $3 == rev-parse ]]; then
        printf 'mock-current-revision\n'
    else
        return 1
    fi
}
make() {
    printf 'make:%s\n' "${1:-build}" >> "$HERC_TEST_LOG"
    [[ ${HERC_TEST_FAIL:-} != "${1:-build}" ]] || return 42
}
chown() { :; }
ldconfig() {
    printf 'ldconfig\n' >> "$HERC_TEST_LOG"
    [[ ${HERC_TEST_FAIL:-} != ldconfig ]]
}
hercules_verify_install() {
    printf 'verify\n' >> "$HERC_TEST_LOG"
    [[ ${HERC_TEST_FAIL:-} != verify ]]
}
systemctl() {
    [[ $1 == reboot ]] || return 1
    printf 'reboot\n' >> "$HERC_TEST_LOG"
}
hercules_main "$@"
RUNNER

bash "$HERC_TEST_SCRIPT" --help > "$test_root/output.log"
grep -q 'REBOOTS' "$test_root/output.log" || fail 'help does not explain automatic reboot'
pass 'help explains automatic reboot and makes no changes'
for bad_argument in --unknown --work-dir --profile-user; do
    if bash "$HERC_TEST_SCRIPT" "$bad_argument" > "$test_root/output.log" 2>&1; then
        fail "invalid argument accepted: $bad_argument"
    fi
done
if bash "$HERC_TEST_SCRIPT" --work-dir relative > "$test_root/output.log" 2>&1; then
    fail 'relative build directory accepted'
fi
pass 'unknown options, missing values, and relative build paths are rejected'

: > "$HERC_TEST_LOG"
bash "$test_root/runner.sh" --work-dir "$test_root/build parent" --profile-user fixture > "$test_root/output.log" 2>&1
[[ $(tail -n 2 "$HERC_TEST_LOG") == $'verify\nreboot' ]] || fail 'default reboot did not follow verification'
grep -qxF 'configure:--enable-cckd-bzip2 --enable-regina-rexx' "$HERC_TEST_LOG" || fail 'configure flags changed'
grep -qxF 'make:install' "$HERC_TEST_LOG" || fail 'installation was skipped'
pass 'default flow builds with both requested options, installs, verifies, and reboots'
grep -q '^apt:install -y .* zlib1g-dev ' "$HERC_TEST_LOG" || fail 'zlib1g-dev was not installed'
pass 'zlib1g-dev is included in the automated dependency installation'
[[ $(cat "$HERC_TEST_HOME/.bashrc.hercules.bak") == '# existing profile without final newline' ]] || fail 'original profile was not backed up'
pass 'original bashrc is preserved before adding the library path'

printf 'keep this local change\n' > "$test_root/build parent/hyperion/local-change"
: > "$HERC_TEST_LOG"
bash "$test_root/runner.sh" --work-dir "$test_root/build parent" --profile-user fixture --no-reboot > "$test_root/output.log" 2>&1
if grep -qxE 'clone|reboot' "$HERC_TEST_LOG"; then fail 'rerun recloned or ignored --no-reboot'; fi
[[ $(grep -cxF 'export LD_LIBRARY_PATH="/lib:/usr/lib:/usr/local/lib"' "$HERC_TEST_HOME/.bashrc") == 1 ]] || fail 'profile export was duplicated'
[[ $(cat "$test_root/build parent/hyperion/local-change") == 'keep this local change' ]] || fail 'local source changes were lost'
pass 'rerun preserves local source and profile contents and honors --no-reboot'

: > "$HERC_TEST_LOG"
bash "$test_root/runner.sh" --work-dir "$test_root/build parent" --profile-user fixture --skip-autogen --no-reboot > "$test_root/output.log" 2>&1
if grep -qxF autogen "$HERC_TEST_LOG"; then fail '--skip-autogen was ignored'; fi
pass 'pre-generated configure can be used with --skip-autogen'

for failure in packages autogen configure missing-feature build install ldconfig verify; do
    : > "$HERC_TEST_LOG"
    if HERC_TEST_FAIL=$failure bash "$test_root/runner.sh" --work-dir "$test_root/build parent" --profile-user fixture > "$test_root/output.log" 2>&1; then
        fail "$failure failure was ignored"
    fi
    if grep -qxF reboot "$HERC_TEST_LOG"; then fail "reboot occurred after $failure failure"; fi
    pass "$failure failure stops the installer before reboot"
done

: > "$HERC_TEST_LOG"
if HERC_TEST_ORIGIN=https://example.invalid/unrelated.git bash "$test_root/runner.sh" --work-dir "$test_root/build parent" --profile-user fixture > "$test_root/output.log" 2>&1; then
    fail 'unrelated source checkout was accepted'
fi
if grep -qxE 'autogen|reboot' "$HERC_TEST_LOG"; then fail 'unrelated checkout was built or rebooted'; fi
pass 'unrelated source checkout is rejected without a build or reboot'

printf '\nAll Hercules installer checks passed.\n'
