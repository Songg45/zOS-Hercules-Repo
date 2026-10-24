#!/usr/bin/env bash
# Automate the supplied Ubuntu/Lubuntu Hercules build, including the final reboot.
set -euo pipefail

hercules_usage() {
    cat <<'USAGE'
Usage: sudo bash scripts/install-hercules.sh [OPTIONS]

Installs build dependencies, clones/reuses SDL Hyperion, runs autogen/configure,
builds and installs Hercules, updates LD_LIBRARY_PATH, verifies, then REBOOTS.

Options:
  --work-dir DIR       Build parent directory (default: /mainframe).
  --profile-user USER  Account whose .bashrc receives LD_LIBRARY_PATH.
                       Default: the account invoking sudo, otherwise root.
  --skip-autogen       Use upstream's pre-generated configure script instead.
  --no-reboot          Finish successfully without rebooting.
  -h, --help           Print help without installing anything or rebooting.

The normal run reboots automatically after all steps succeed, without a prompt.
Existing clones are rebuilt at their current revision; they are never reset or
automatically pulled. No guest images or Hercules configuration are installed.
USAGE
}

hercules_die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

hercules_require_root() {
    (( EUID == 0 )) || hercules_die 'Run this script with sudo or from a root shell.'
}

hercules_update_bashrc() {
    local home=$1 uid=$2 gid=$3
    local bashrc="$home/.bashrc"
    local export_line='export LD_LIBRARY_PATH="/lib:/usr/lib:/usr/local/lib"'
    [[ $home == /* && -d $home ]] || hercules_die 'The profile account needs an existing absolute home directory.'
    [[ ! -L $bashrc && ( ! -e $bashrc || -f $bashrc ) ]] || hercules_die 'Refusing to edit a symlinked or non-regular .bashrc.'
    if [[ -f $bashrc ]] && grep -qxF "$export_line" "$bashrc"; then
        return 0
    fi
    if [[ -f $bashrc && ! -e $bashrc.hercules.bak && ! -L $bashrc.hercules.bak ]]; then
        cp -p -- "$bashrc" "$bashrc.hercules.bak"
    fi
    printf '\n# Hercules runtime libraries\n%s\n' "$export_line" >> "$bashrc"
    chown "$uid:$gid" "$bashrc"
}

hercules_verify_install() {
    # Unlike -v (verbose), this displays version information and then exits.
    /usr/local/bin/hercules --help=version
    /usr/local/bin/hercules --help=build
}

hercules_main() {
    local work_dir=/mainframe profile_user=${SUDO_USER:-root}
    local reboot_after=true run_autogen=true account uid gid home source_dir origin
    while (($#)); do
        case $1 in
            --work-dir|--profile-user)
                (($# >= 2)) && [[ -n $2 && $2 != --* ]] || hercules_die "$1 requires a value."
                case $1 in
                    --work-dir) work_dir=$2 ;;
                    --profile-user) profile_user=$2 ;;
                esac
                shift 2
                ;;
            --skip-autogen) run_autogen=false; shift ;;
            --no-reboot) reboot_after=false; shift ;;
            -h|--help) hercules_usage; return 0 ;;
            *) hercules_die "Unknown option: $1 (see --help)." ;;
        esac
    done
    [[ $work_dir == /* && $work_dir != / ]] || hercules_die '--work-dir must be an absolute directory other than /.'
    [[ $profile_user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || hercules_die 'Invalid profile username.'
    hercules_require_root
    command -v apt-get >/dev/null || hercules_die 'Ubuntu/Lubuntu with apt-get is required.'
    if $reboot_after; then
        command -v systemctl >/dev/null || hercules_die 'Automatic reboot requires systemd.'
    fi
    account=$(getent passwd "$profile_user") || hercules_die "No such profile account: $profile_user."
    IFS=: read -r _ _ uid gid _ home _ <<< "$account"
    [[ $home == /* && -d $home ]] || hercules_die 'The profile account needs an existing home directory.'

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git build-essential libtool libtool-bin libltdl-dev automake autoconf \
        libregina3-dev screen c3270 libbz2-dev bzip2 zlib1g-dev \
        ca-certificates cmake flex gawk m4 time wget libcap2-bin

    mkdir -p -- "$work_dir"
    source_dir="$work_dir/hyperion"
    if [[ -e $source_dir || -L $source_dir ]]; then
        [[ -d $source_dir/.git || -f $source_dir/.git ]] || hercules_die "$source_dir exists but is not a Git checkout."
        origin=$(git -C "$source_dir" remote get-url origin)
        origin=${origin%/}
        [[ ${origin%.git} == https://github.com/SDL-Hercules-390/hyperion ]] || hercules_die 'The existing checkout is not from SDL-Hercules-390/hyperion.'
        printf 'Reusing existing source revision: '
        git -C "$source_dir" rev-parse HEAD
    else
        git clone https://github.com/SDL-Hercules-390/hyperion.git "$source_dir"
    fi

    cd -- "$source_dir"
    if $run_autogen; then
        ./autogen.sh
    fi
    ./configure --enable-cckd-bzip2 --enable-regina-rexx
    grep -Eq '^#define[[:space:]]+CCKD_BZIP2[[:space:]]+1([[:space:]]|$)' config.h || hercules_die 'Configuration did not enable CCKD bzip2.'
    grep -Eq '^#define[[:space:]]+HAVE_REGINA_REXX[[:space:]]+1([[:space:]]|$)' config.h || hercules_die 'Configuration did not enable Regina REXX.'
    make
    make install

    hercules_update_bashrc "$home" "$uid" "$gid"
    export LD_LIBRARY_PATH='/lib:/usr/lib:/usr/local/lib'
    ldconfig
    hercules_verify_install
    printf '\nHercules installation and verification completed.\nSource: %s\nProfile: %s/.bashrc\n' "$source_dir" "$home"
    if $reboot_after; then
        printf 'Rebooting now. Reconnect after the machine starts.\n'
        systemctl reboot
    else
        printf 'Reboot skipped (--no-reboot).\n'
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    hercules_main "$@"
fi
