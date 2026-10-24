#!/usr/bin/env bash
# Regression checks use temporary files and mocks, never the live OS configuration.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/scripts/setup-codex-ssh.sh"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-zos-test.XXXXXXXX")
cleanup() {
    case $test_root in
        "${TMPDIR:-/tmp}/codex-zos-test."*) rm -rf -- "$test_root" ;;
        *) printf 'Refusing to clean an unexpected test path: %s\n' "$test_root" >&2 ;;
    esac
}
trap cleanup EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
expect_failure() {
    local label=$1
    shift
    if ("$@") >"$test_root/expected-error.log" 2>&1; then
        fail "$label unexpectedly succeeded"
    fi
    pass "$label"
}

ssh-keygen -q -t ed25519 -N '' -f "$test_root/client-key"
public_key=$(cat "$test_root/client-key.pub")
validate_public_key "$public_key" "$test_root/candidate.pub"
pass 'valid Ed25519 public key is accepted'
expect_failure 'invalid key material is rejected' validate_public_key 'ssh-ed25519 invalid' "$test_root/invalid.pub"
expect_failure 'multiple public key lines are rejected' validate_public_key "$public_key"$'\n'"$public_key" "$test_root/multiple.pub"
expect_failure 'private key input is rejected' validate_public_key '-----BEGIN OPENSSH PRIVATE KEY-----' "$test_root/private.pub"

main --help >"$test_root/help.txt"
grep -q -- '--passwordless-sudo' "$test_root/help.txt" || fail 'help is incomplete'
pass 'help runs without system changes'
expect_failure 'missing public key is rejected' main
expect_failure 'missing option value is rejected' main --username
expect_failure 'unknown option is rejected' main --unknown
expect_failure 'root account is rejected' main --username root --public-key "$public_key"
expect_failure 'username injection is rejected' main --username $'user\nroot' --public-key "$public_key"
expect_failure 'duplicate key arguments are rejected' main --public-key "$public_key" --public-key-file "$test_root/client-key.pub"
expect_failure 'missing public key file is rejected' main --public-key-file "$test_root/missing.pub"
expect_failure 'invalid source address is rejected' main --public-key "$public_key" --allow-from 192.168.140.999

for source_address in 192.168.140.139 192.168.140.0/24 0.0.0.0/0 255.255.255.255/32; do
    valid_ipv4_source "$source_address" || fail "valid source rejected: $source_address"
done
for source_address in 256.1.2.3 1.2.3 1.2.3.4/33 1.2.3.4/ 1.2.3.4/999 $'1.2.3.4\nallow' --help; do
    if valid_ipv4_source "$source_address"; then
        fail "invalid source accepted: $source_address"
    fi
done
pass 'IPv4 and CIDR bounds are checked'

# Strip ownership flags for cross-platform tests; the real script uses root-owned
# install/chown. File contents, permissions, and rollback logic still run here.
install() {
    local -a arguments=()
    while (($#)); do
        case $1 in
            -o|-g) shift 2 ;;
            *) arguments+=("$1"); shift ;;
        esac
    done
    command install "${arguments[@]}"
}
chown() { :; }

home="$test_root/home"
mkdir -p "$home/.ssh"
printf '%s' 'existing unrelated authorized key' > "$home/.ssh/authorized_keys"
install_authorized_key "$home" 1234 1234 "$public_key"
install_authorized_key "$home" 1234 1234 "$public_key"
[[ $(grep -cxF "$public_key" "$home/.ssh/authorized_keys") == 1 ]] || fail 'rerun duplicated the key'
grep -qxF 'existing unrelated authorized key' "$home/.ssh/authorized_keys" || fail 'existing key was damaged'
pass 'rerun preserves existing keys and adds the public key once'

mkdir -p "$test_root/linked-home/.ssh"
printf 'untouched\n' > "$test_root/symlink-target"
ln -s "$test_root/symlink-target" "$test_root/linked-home/.ssh/authorized_keys"
expect_failure 'symlinked authorized_keys is rejected' install_authorized_key "$test_root/linked-home" 1234 1234 "$public_key"
[[ $(cat "$test_root/symlink-target") == untouched ]] || fail 'symlink target was modified'

sudoers_directory="$test_root/sudoers.d"
sudo_workdir="$test_root/sudo-workdir"
mkdir -p "$sudoers_directory" "$sudo_workdir"
mock_bad_candidate=false
mock_bad_active=false
mock_failed_root_check=false
visudo() {
    case $1 in
        -cf) ! "$mock_bad_candidate" ;;
        -c) ! "$mock_bad_active" ;;
        *) fail 'unexpected visudo invocation' ;;
    esac
}
usermod() { printf '%s\n' "$*" >> "$test_root/usermod.log"; }
verify_passwordless_sudo() { ! "$mock_failed_root_check"; }

configure_passwordless_sudo codex-zos-user "$sudo_workdir" "$sudoers_directory"
grep -qxF 'codex-zos-user ALL=(ALL:ALL) NOPASSWD: ALL' "$sudoers_directory/99-codex-zos-user" || fail 'wrong sudo rule'
configure_passwordless_sudo codex-zos-user "$sudo_workdir" "$sudoers_directory"
[[ $(wc -l < "$sudoers_directory/99-codex-zos-user") -eq 1 ]] || fail 'rerun duplicated sudo rule'
pass 'passwordless sudo installs one complete rule and supports reruns'

chmod u+w "$sudoers_directory/99-codex-zos-user"
printf 'previous sudo policy\n' > "$sudoers_directory/99-codex-zos-user"
# Each full invocation creates a fresh workspace, including its rollback backup.
sudo_workdir=$(mktemp -d "$test_root/sudo-workdir.XXXXXXXX")
mock_failed_root_check=true
expect_failure 'failed root verification rejects the new rule' configure_passwordless_sudo codex-zos-user "$sudo_workdir" "$sudoers_directory"
grep -qF 'Passwordless sudo failed verification' "$test_root/expected-error.log" || fail 'the verification failure path was not reached'
[[ $(cat "$sudoers_directory/99-codex-zos-user") == 'previous sudo policy' ]] || fail 'previous sudo rule was not restored'
pass 'failed verification restores the previous sudo rule'

rm -f "$sudoers_directory/99-codex-zos-user"
sudo_workdir=$(mktemp -d "$test_root/sudo-workdir.XXXXXXXX")
expect_failure 'failed verification rejects a newly created rule' configure_passwordless_sudo codex-zos-user "$sudo_workdir" "$sudoers_directory"
grep -qF 'Passwordless sudo failed verification' "$test_root/expected-error.log" || fail 'the verification failure path was not reached'
[[ ! -e $sudoers_directory/99-codex-zos-user ]] || fail 'failed new sudo rule was left installed'
pass 'failed verification restores the absence of a previous rule'

mock_failed_root_check=false
mock_bad_candidate=true
rm -f "$test_root/usermod.log"
expect_failure 'invalid sudo candidate is rejected' configure_passwordless_sudo codex-zos-user "$sudo_workdir" "$sudoers_directory"
[[ ! -e $sudoers_directory/99-codex-zos-user && ! -e $test_root/usermod.log ]] || fail 'invalid candidate changed sudo privileges'
mock_bad_candidate=false
mock_bad_active=true
expect_failure 'broken existing sudo policy stops the change' configure_passwordless_sudo codex-zos-user "$sudo_workdir" "$sudoers_directory"
[[ ! -e $sudoers_directory/99-codex-zos-user && ! -e $test_root/usermod.log ]] || fail 'broken baseline changed sudo privileges'

printf '\nAll regression checks passed.\n'
