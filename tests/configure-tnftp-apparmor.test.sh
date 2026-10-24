#!/usr/bin/env bash
# Exercise policy preservation and failure recovery without changing real policy.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d /tmp/tnftp-apparmor-test.XXXXXXXX)
cleanup() {
    case $test_root in
        /tmp/tnftp-apparmor-test.*) rm -rf -- "$test_root" ;;
        *) printf 'Refusing to remove an unexpected test directory.\n' >&2 ;;
    esac
}
trap cleanup EXIT
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export TNFTP_TEST_SCRIPT="$repo_root/scripts/configure-tnftp-apparmor.sh"
export TNFTP_TEST_ROOT="$test_root"
export TNFTP_TEST_CASE TNFTP_TEST_FAIL
TNFTP_TEST_FAIL=

cat > "$test_root/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
source "$TNFTP_TEST_SCRIPT"
apparmor_parser() {
    printf '%s\n' "$*" >> "$TNFTP_TEST_CASE/parser.log"
    if [[ -n ${TNFTP_TEST_REAL_PARSER:-} ]]; then
        # Exercise the real parser, including the script's reload command shape,
        # but never load fixture policies into the running kernel.
        command "$TNFTP_TEST_REAL_PARSER" -Q "$@"
        return
    fi
    if [[ $1 == -Q && $TNFTP_TEST_FAIL == validation ]]; then return 42; fi
    if [[ $1 == -r && $TNFTP_TEST_FAIL == reload && ! -e $TNFTP_TEST_CASE/reload-failed ]]; then
        : > "$TNFTP_TEST_CASE/reload-failed"
        return 42
    fi
    if [[ $1 == -r && $TNFTP_TEST_FAIL == unenforced && ! -e $TNFTP_TEST_CASE/reload-failed ]]; then
        : > "$TNFTP_TEST_CASE/reload-failed"
        printf 'tnftp (complain)\n' > "$TNFTP_TEST_CASE/profiles"
    elif [[ $1 == -r && -e $TNFTP_TEST_CASE/reload-failed ]]; then
        printf 'tnftp (enforce)\n' > "$TNFTP_TEST_CASE/profiles"
    fi
}
tnftp_apparmor_apply "$TNFTP_TEST_CASE/apparmor/tnftp" \
    "$TNFTP_TEST_CASE/apparmor/local/tnftp" "$TNFTP_TEST_CASE/mainframe/ftp" \
    "$TNFTP_TEST_CASE/backups" "$TNFTP_TEST_CASE/profiles"
RUNNER

new_case() {
    TNFTP_TEST_CASE="$test_root/$1"
    TNFTP_TEST_FAIL=
    mkdir -p "$TNFTP_TEST_CASE/apparmor/local" "$TNFTP_TEST_CASE/mainframe"
    cat > "$TNFTP_TEST_CASE/apparmor/tnftp" <<'PROFILE'
profile tnftp /usr/bin/tnftp {
  include if exists <local/tnftp>
}
PROFILE
    cp "$TNFTP_TEST_CASE/apparmor/tnftp" "$TNFTP_TEST_CASE/packaged.before"
    printf 'tnftp (enforce)\n' > "$TNFTP_TEST_CASE/profiles"
}
run_case() { bash "$test_root/runner.sh" > "$TNFTP_TEST_CASE/output.log" 2>&1; }
assert_packaged_unchanged() {
    cmp -s "$TNFTP_TEST_CASE/apparmor/tnftp" "$TNFTP_TEST_CASE/packaged.before" || fail 'packaged profile changed'
}

bash "$TNFTP_TEST_SCRIPT" --help > "$test_root/help.log"
grep -q '/mainframe/ftp' "$test_root/help.log" || fail 'help omits the target directory'
if bash "$TNFTP_TEST_SCRIPT" --unknown > "$test_root/output.log" 2>&1; then fail 'unknown option accepted'; fi
pass 'help makes no changes and unknown arguments are rejected'

new_case fresh
run_case || { cat "$TNFTP_TEST_CASE/output.log"; fail 'initial configuration failed'; }
override="$TNFTP_TEST_CASE/apparmor/local/tnftp"
grep -qxF "owner $TNFTP_TEST_CASE/mainframe/ftp/ r," "$override" || fail 'directory rule missing'
grep -qxF "owner $TNFTP_TEST_CASE/mainframe/ftp/* rw," "$override" || fail 'flat file rule missing'
if grep -Fq '/**' "$override"; then fail 'exception unexpectedly covers nested directories'; fi
[[ -d $TNFTP_TEST_CASE/mainframe/ftp ]] || fail 'missing transfer directory was not created'
[[ $(stat -c %a "$override") == 644 ]] || fail 'new override permissions are incorrect'
[[ $(grep -c '^-r -K ' "$TNFTP_TEST_CASE/parser.log") == 1 ]] || fail 'profile was not reloaded exactly once'
if grep -qE '(^| )(-C|--Complain|-R|--remove)( |$)' "$TNFTP_TEST_CASE/parser.log"; then fail 'confinement was disabled'; fi
assert_packaged_unchanged
pass 'initial run installs only owner-only flat-directory rules and reloads the confined profile'

cp "$override" "$TNFTP_TEST_CASE/override.before-rerun"
backup_count=$(find "$TNFTP_TEST_CASE/backups" -mindepth 1 -maxdepth 1 -type d | wc -l)
run_case || fail 'rerun failed'
cmp -s "$override" "$TNFTP_TEST_CASE/override.before-rerun" || fail 'rerun changed or duplicated the rules'
[[ $(find "$TNFTP_TEST_CASE/backups" -mindepth 1 -maxdepth 1 -type d | wc -l) == "$backup_count" ]] || fail 'rerun created an unnecessary backup'
pass 'rerun preserves identical override contents without duplicate rules or backups'

new_case preserve
mkdir "$TNFTP_TEST_CASE/mainframe/ftp"
chmod 0750 "$TNFTP_TEST_CASE/mainframe/ftp"
printf '# existing rule without final newline\nowner /srv/existing/* r,' > "$TNFTP_TEST_CASE/apparmor/local/tnftp"
chmod 0640 "$TNFTP_TEST_CASE/apparmor/local/tnftp"
cp -p "$TNFTP_TEST_CASE/apparmor/local/tnftp" "$TNFTP_TEST_CASE/override.before"
run_case || fail 'configuration with an existing local override failed'
grep -qxF 'owner /srv/existing/* r,' "$TNFTP_TEST_CASE/apparmor/local/tnftp" || fail 'existing rule was lost or merged into a comment'
[[ $(stat -c %a "$TNFTP_TEST_CASE/apparmor/local/tnftp") == 640 ]] || fail 'existing override mode changed'
[[ $(stat -c %a "$TNFTP_TEST_CASE/mainframe/ftp") == 750 ]] || fail 'existing directory permissions changed'
saved_override=$(find "$TNFTP_TEST_CASE/backups" -name local-tnftp.before -type f)
cmp -s "$saved_override" "$TNFTP_TEST_CASE/override.before" || fail 'backup differs from the original override'
assert_packaged_unchanged
pass 'existing rules, file permissions, directory permissions, and the original backup are preserved'

new_case validation-failure
TNFTP_TEST_FAIL=validation
if run_case; then fail 'invalid candidate was accepted'; fi
[[ ! -e $TNFTP_TEST_CASE/apparmor/local/tnftp ]] || fail 'validation failure installed an override'
[[ ! -e $TNFTP_TEST_CASE/backups ]] || fail 'validation failure created a backup before validation'
if grep -q '^-r ' "$TNFTP_TEST_CASE/parser.log"; then fail 'invalid policy was loaded'; fi
assert_packaged_unchanged
pass 'candidate validation failure leaves the override and loaded policy untouched'

for scenario in reload unenforced; do
    for initial in absent existing; do
        new_case "$scenario-$initial"
        if [[ $initial == existing ]]; then
            printf 'owner /srv/keep/* r,\n' > "$TNFTP_TEST_CASE/apparmor/local/tnftp"
            chmod 0640 "$TNFTP_TEST_CASE/apparmor/local/tnftp"
            cp -p "$TNFTP_TEST_CASE/apparmor/local/tnftp" "$TNFTP_TEST_CASE/override.before"
        fi
        TNFTP_TEST_FAIL=$scenario
        if run_case; then fail "$scenario failure was ignored ($initial override)"; fi
        if [[ $initial == existing ]]; then
            cmp -s "$TNFTP_TEST_CASE/apparmor/local/tnftp" "$TNFTP_TEST_CASE/override.before" || fail 'rollback did not restore the original override'
            [[ $(stat -c %a "$TNFTP_TEST_CASE/apparmor/local/tnftp") == 640 ]] || fail 'rollback changed the original mode'
        else
            [[ ! -e $TNFTP_TEST_CASE/apparmor/local/tnftp ]] || fail 'rollback left a newly created override'
        fi
        [[ $(grep -c '^-r -K ' "$TNFTP_TEST_CASE/parser.log") == 2 ]] || fail 'rollback did not reload the original policy'
        grep -qxF 'tnftp (enforce)' "$TNFTP_TEST_CASE/profiles" || fail 'original enforce state was not restored'
        assert_packaged_unchanged
        pass "$scenario failure restores and reloads the $initial override state"
    done
done

new_case symlink
printf 'keep\n' > "$TNFTP_TEST_CASE/protected"
ln -s "$TNFTP_TEST_CASE/protected" "$TNFTP_TEST_CASE/apparmor/local/tnftp"
if run_case; then fail 'symlinked override was accepted'; fi
[[ $(cat "$TNFTP_TEST_CASE/protected") == keep ]] || fail 'symlink target was changed'
pass 'symlinked local overrides are rejected without modifying their targets'

new_case missing-include
printf 'profile tnftp /usr/bin/tnftp {\n}\n' > "$TNFTP_TEST_CASE/apparmor/tnftp"
if run_case; then fail 'profile without a local include was accepted'; fi
[[ ! -e $TNFTP_TEST_CASE/apparmor/local/tnftp ]] || fail 'unused override was installed'
pass 'profiles without the expected local include are rejected'

new_case complain
printf 'tnftp (complain)\n' > "$TNFTP_TEST_CASE/profiles"
if run_case; then fail 'initial complain mode was accepted'; fi
[[ ! -e $TNFTP_TEST_CASE/apparmor/local/tnftp ]] || fail 'configuration changed while the profile was unenforced'
pass 'initially unenforced profiles are rejected without changing their mode'

if command -v apparmor_parser >/dev/null; then
    new_case native-parser
    TNFTP_TEST_REAL_PARSER=$(command -v apparmor_parser)
    export TNFTP_TEST_REAL_PARSER
    run_case || { cat "$TNFTP_TEST_CASE/output.log"; fail 'native AppArmor parser rejected the generated candidate'; }
    cp "$TNFTP_TEST_CASE/apparmor/local/tnftp" "$TNFTP_TEST_CASE/override.before-rerun"
    run_case || { cat "$TNFTP_TEST_CASE/output.log"; fail 'native AppArmor parser rejected an idempotent rerun'; }
    cmp -s "$TNFTP_TEST_CASE/apparmor/local/tnftp" "$TNFTP_TEST_CASE/override.before-rerun" || fail 'native-parser rerun changed the rules'
    assert_packaged_unchanged
    pass 'native AppArmor parser accepts initial configuration and reruns without loading fixture policy'
else
    printf 'SKIP: native AppArmor parser check (apparmor_parser is not installed).\n'
fi

printf '\nAll tnftp AppArmor checks passed.\n'
