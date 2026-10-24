#!/usr/bin/env bash
# Permit direct tnftp downloads into /mainframe/ftp while retaining confinement.
set -euo pipefail

tnftp_apparmor_usage() {
    cat <<'USAGE'
Usage: sudo bash scripts/configure-tnftp-apparmor.sh

Adds these persistent owner-only rules to /etc/apparmor.d/local/tnftp:
  owner /mainframe/ftp/ r,
  owner /mainframe/ftp/* rw,

Validates the policy, reloads only the tnftp profile, and checks that it remains
enforced. Existing local rules and directory permissions are preserved. Files
directly inside the directory are covered; nested directories are not included.
Creates /mainframe/ftp if missing. Requires an installed, enforced tnftp profile.
Backups are saved under /var/backups before changing an existing configuration.
A failed reload restores the previous override and attempts to reload it.

Options:
  -h, --help  Show help without changing anything.
USAGE
}

tnftp_apparmor_die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

tnftp_apparmor_require_root() {
    (( EUID == 0 )) || tnftp_apparmor_die 'Run this script with sudo or from a root shell.'
}

tnftp_apparmor_is_enforced() {
    grep -qxF 'tnftp (enforce)' "$1"
}

# Paths are parameters so regression checks can use isolated fixtures. The public
# command always supplies the fixed system paths in tnftp_apparmor_main below.
tnftp_apparmor_apply() (
    set -euo pipefail
    profile=$1 override=$2 directory=$3 backup_base=$4 profiles_file=$5
    profile_dir=$(dirname -- "$profile")
    override_dir=$(dirname -- "$override")
    directory_parent=$(dirname -- "$directory")
    include_pattern='^[[:space:]]*include[[:space:]]+if[[:space:]]+exists[[:space:]]+<local/tnftp>[[:space:]]*$'
    directory_rule="owner $directory/ r,"
    files_rule="owner $directory/* rw,"
    work_dir='' stage='' backup_dir=''
    existed=false installed=false complete=false

    # ShellCheck does not track this subshell's EXIT-trap callback.
    # shellcheck disable=SC2329
    cleanup() {
        status=$1
        trap - EXIT
        if $installed && ! $complete; then
            printf 'Restoring the previous tnftp local override.\n' >&2
            if $existed; then
                restore=$(mktemp "$override_dir/.tnftp-restore.XXXXXXXX")
                if cp -p -- "$backup_dir/local-tnftp.before" "$restore" && mv -fT -- "$restore" "$override"; then
                    :
                else
                    printf 'ERROR: Restore failed; recover the override from %s.\n' "$backup_dir" >&2
                    rm -f -- "$restore"
                    status=1
                fi
            else
                rm -f -- "$override" || status=1
            fi
            if ! apparmor_parser -r -K "$profile"; then
                printf 'ERROR: Could not reload the restored profile; inspect %s.\n' "$backup_dir" >&2
                status=1
            fi
        fi
        [[ -z $stage ]] || rm -f -- "$stage"
        if [[ -n $work_dir ]]; then
            case $work_dir in
                /tmp/tnftp-apparmor.*) rm -rf -- "$work_dir" ;;
                *) printf 'Refusing to remove an unexpected work directory: %s\n' "$work_dir" >&2; status=1 ;;
            esac
        fi
        exit "$status"
    }
    trap 'cleanup "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    for path in "$profile_dir" "$override_dir" "$directory_parent" "$directory" "$backup_base"; do
        [[ ! -L $path ]] || tnftp_apparmor_die "Refusing a symlinked directory: $path"
        [[ ! -e $path || -d $path ]] || tnftp_apparmor_die "Not a directory: $path"
    done
    [[ -d $profile_dir && -d $override_dir ]] || tnftp_apparmor_die 'The AppArmor profile and local override directories must already exist.'
    [[ -f $profile && ! -L $profile ]] || tnftp_apparmor_die "Missing or symlinked tnftp profile: $profile"
    [[ ! -L $override && ( ! -e $override || -f $override ) ]] || tnftp_apparmor_die "Refusing a symlinked or non-regular override: $override"
    [[ $(grep -Ec "$include_pattern" "$profile") == 1 ]] || tnftp_apparmor_die 'Expected exactly one include if exists <local/tnftp> in the packaged profile.'
    tnftp_apparmor_is_enforced "$profiles_file" || tnftp_apparmor_die 'The tnftp profile must already be loaded in enforce mode.'

    work_dir=$(mktemp -d /tmp/tnftp-apparmor.XXXXXXXX)
    candidate="$work_dir/local-tnftp"
    : > "$candidate"
    if [[ -f $override ]]; then
        existed=true
        cp -p -- "$override" "$work_dir/local-tnftp.before"
        cat -- "$override" > "$candidate"
    fi
    if ! grep -qxF "$directory_rule" "$candidate" || ! grep -qxF "$files_rule" "$candidate"; then
        printf '\n# Permit owner-only FTP downloads directly into the mainframe transfer directory.\n' >> "$candidate"
        if ! grep -qxF "$directory_rule" "$candidate"; then printf '%s\n' "$directory_rule" >> "$candidate"; fi
        if ! grep -qxF "$files_rule" "$candidate"; then printf '%s\n' "$files_rule" >> "$candidate"; fi
    fi

    # Validate a candidate profile whose local include points at the staged file.
    # -Q avoids loading it; -K avoids reading or writing compiled policy caches.
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ $include_pattern ]]; then
            printf '  include "%s"\n' "$candidate"
        else
            printf '%s\n' "$line"
        fi
    done < "$profile" > "$work_dir/tnftp.profile"
    apparmor_parser -Q -K -b "$profile_dir" "$work_dir/tnftp.profile"

    if ! $existed || ! cmp -s -- "$candidate" "$override"; then
        mkdir -p -- "$backup_base"
        backup_dir=$(mktemp -d "$backup_base/tnftp-apparmor.$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
        cp -p -- "$profile" "$backup_dir/tnftp.profile.before"
        if $existed; then
            cp -p -- "$override" "$backup_dir/local-tnftp.before"
            # Do not overwrite an override edited since this run's initial read.
            cmp -s -- "$override" "$work_dir/local-tnftp.before" || tnftp_apparmor_die 'The local override changed during validation; rerun after inspecting it.'
            printf 'The local override existed; restore local-tnftp.before to %s.\n' "$override" > "$backup_dir/restore.txt"
        else
            [[ ! -e $override && ! -L $override ]] || tnftp_apparmor_die 'A local override appeared during validation; inspect it before rerunning.'
            printf 'The local override was absent; remove %s to restore that state.\n' "$override" > "$backup_dir/restore.txt"
        fi
        printf 'Then reload with: apparmor_parser -r -K %s\n' "$profile" >> "$backup_dir/restore.txt"
        stage=$(mktemp "$override_dir/.tnftp-install.XXXXXXXX")
        if $existed; then
            cp -p -- "$override" "$stage"
            cat -- "$candidate" > "$stage"
        else
            install -m 0644 -- "$candidate" "$stage"
        fi
        installed=true
        mv -fT -- "$stage" "$override"
        stage=
        printf 'Installed local override. Backup: %s\n' "$backup_dir"
    else
        printf 'Both rules already exist; the local override is unchanged.\n'
    fi

    if [[ ! -d $directory ]]; then
        install -d -m 0755 -- "$directory"
    fi
    apparmor_parser -Q -K "$profile"
    apparmor_parser -r -K "$profile"
    tnftp_apparmor_is_enforced "$profiles_file" || tnftp_apparmor_die 'The reloaded tnftp profile is not in enforce mode.'
    complete=true
    printf '\nPersistent tnftp exception configured for %s.\n' "$directory"
    printf 'AppArmor remains enforced. Existing directory permissions are unchanged.\n'
    printf 'Rules cover owner-owned files directly in the directory, not nested directories.\n'
    printf '\nAt the Linux ftp> prompt:\n  lcd %s\n  ascii\n  get '\''IBMUSER.HELLO.HI'\'' HELLO.HI\n' "$directory"
)

tnftp_apparmor_main() {
    if (($#)); then
        case $1 in
            -h|--help) (($# == 1)) || tnftp_apparmor_die 'Help takes no additional arguments.'; tnftp_apparmor_usage; return 0 ;;
            *) tnftp_apparmor_die "Unknown argument: $1 (see --help)." ;;
        esac
    fi
    tnftp_apparmor_require_root
    for command in apparmor_parser grep cmp cp mktemp install mv mkdir date dirname cat rm; do
        command -v "$command" >/dev/null || tnftp_apparmor_die "Required command is unavailable: $command"
    done
    tnftp_apparmor_apply /etc/apparmor.d/tnftp /etc/apparmor.d/local/tnftp \
        /mainframe/ftp /var/backups /sys/kernel/security/apparmor/profiles
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    tnftp_apparmor_main "$@"
fi
