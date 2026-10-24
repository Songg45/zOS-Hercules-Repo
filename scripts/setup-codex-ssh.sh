#!/usr/bin/env bash
# Configure a key-authenticated account on an Ubuntu/Lubuntu SSH server.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: sudo bash scripts/setup-codex-ssh.sh [OPTIONS]

Required (choose one):
  --public-key-file FILE   File containing one Ed25519 public key.
  --public-key KEY         Ed25519 public key, quoted as one argument.

Options:
  --username NAME          Login account (default: codex-zos-user).
  --allow-from ADDRESS     Add a UFW rule for this IPv4 address or CIDR.
                          UFW is never enabled or installed by this script.
  --passwordless-sudo      Add the account to sudo and allow all sudo commands
                          without a password.
  -h, --help              Show this help without making changes.

Run on the Linux server from an existing administrator/root account.
The script creates a missing account with a locked password and /bin/bash.
It preserves existing passwords, authorized keys, and SSH configuration.
Generate the key pair on the client PC; supply only the public key here.
USAGE
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

valid_ipv4_source() {
    local source=$1 address prefix octet
    local -a octets
    [[ $source =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,2})?$ ]] || return 1
    address=${source%%/*}
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        [[ ${#octet} -le 3 ]] && (( 10#$octet <= 255 )) || return 1
    done
    if [[ $source == */* ]]; then
        prefix=${source#*/}
        (( 10#$prefix <= 32 )) || return 1
    fi
}

validate_public_key() {
    local key=$1 candidate=$2
    [[ $key != *$'\n'* && $key != *$'\r'* ]] || die 'Supply exactly one public key line.'
    [[ $key == ssh-ed25519\ * ]] || die 'An ssh-ed25519 public key is required.'
    printf '%s\n' "$key" > "$candidate"
    ssh-keygen -lf "$candidate" >/dev/null || die 'The public key is not valid.'
}

install_authorized_key() {
    local home=$1 uid=$2 gid=$3 key=$4
    local directory="$home/.ssh" authorized_keys="$home/.ssh/authorized_keys"
    [[ $home == /* && $home != / && -d $home ]] || die 'The account needs an existing, absolute home directory.'
    [[ ! -L $directory && ! -L $authorized_keys ]] || die 'Refusing to modify symlinked SSH paths.'
    [[ ! -e $authorized_keys || -f $authorized_keys ]] || die 'authorized_keys is not a regular file.'
    install -d -o "$uid" -g "$gid" -m 0700 "$directory"
    touch "$authorized_keys"
    chown "$uid:$gid" "$authorized_keys"
    chmod 0600 "$authorized_keys"
    if ! grep -qxF -- "$key" "$authorized_keys"; then
        # A leading newline also handles an existing file without a final newline.
        printf '\n%s\n' "$key" >> "$authorized_keys"
    fi
}

verify_passwordless_sudo() {
    [[ $(runuser -u "$1" -- sudo -n -k /usr/bin/id -u) == 0 ]]
}

configure_passwordless_sudo() {
    local username=$1 workdir=$2 sudoers_directory=${3:-/etc/sudoers.d}
    local rule="$sudoers_directory/99-$username" had_original=false
    [[ -d $sudoers_directory && ! -L $rule ]] || die 'The sudoers directory must exist and the rule must not be a symlink.'
    visudo -c || die 'Fix the existing sudoers configuration before continuing.'
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$username" > "$workdir/sudo-rule"
    visudo -cf "$workdir/sudo-rule" || die 'The new sudo rule did not validate.'
    if [[ -e $rule ]]; then
        cp -p -- "$rule" "$workdir/previous-sudo-rule"
        had_original=true
    fi
    usermod -aG sudo "$username"
    # Files containing a dot are ignored by sudoers' includedir processing.
    # Publish the complete, validated rule with an atomic rename.
    install -o root -g root -m 0440 "$workdir/sudo-rule" "$rule.tmp"
    mv -f -- "$rule.tmp" "$rule"
    if ! visudo -c || ! verify_passwordless_sudo "$username"; then
        if $had_original; then
            install -o root -g root -m 0440 "$workdir/previous-sudo-rule" "$rule"
        else
            rm -f -- "$rule"
        fi
        die 'Passwordless sudo failed verification; the previous rule was restored.'
    fi
}

main() {
    local username=codex-zos-user public_key='' key_source='' allow_from=''
    local passwordless_sudo=false workdir account uid gid home shell
    while (($#)); do
        case $1 in
            --username|--public-key|--public-key-file|--allow-from)
                (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "$1 requires a value."
                case $1 in
                    --username) username=$2 ;;
                    --allow-from) allow_from=$2 ;;
                    --public-key|--public-key-file)
                        [[ -z $key_source ]] || die 'Supply one public key option, not multiple.'
                        key_source=$1
                        public_key=$2
                        ;;
                esac
                shift 2
                ;;
            --passwordless-sudo) passwordless_sudo=true; shift ;;
            -h|--help) usage; return 0 ;;
            *) die "Unknown option: $1 (see --help)." ;;
        esac
    done
    [[ $username =~ ^[a-z_][a-z0-9_-]{0,31}$ && $username != root ]] || die 'Choose a non-root username of at most 32 lowercase letters, digits, underscores, or hyphens.'
    [[ -n $key_source ]] || die 'Supply --public-key-file or --public-key (see --help).'
    if [[ $key_source == --public-key-file ]]; then
        [[ -f $public_key && -r $public_key ]] || die 'The public key file is not readable.'
        public_key=$(cat -- "$public_key")
    fi
    public_key=${public_key%$'\r'}
    [[ -z $allow_from ]] || valid_ipv4_source "$allow_from" || die '--allow-from must be an IPv4 address or CIDR.'
    [[ $public_key == ssh-ed25519\ * && $public_key != *$'\n'* && $public_key != *$'\r'* ]] || die 'Supply one ssh-ed25519 public key line, never a private key.'
    (( EUID == 0 )) || die 'Run this script with sudo or from a root shell.'
    if ! command -v apt-get >/dev/null || ! command -v systemctl >/dev/null; then
        die 'Ubuntu/Lubuntu with apt-get and systemd is required.'
    fi

    workdir=$(mktemp -d /tmp/codex-ssh-setup.XXXXXXXX)
    # Expand the temporary path now: the EXIT trap runs after main's locals expire.
    # shellcheck disable=SC2064
    trap "rm -rf -- '$workdir'" EXIT
    if command -v ssh-keygen >/dev/null; then
        validate_public_key "$public_key" "$workdir/public-key"
    fi
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server sudo
    validate_public_key "$public_key" "$workdir/public-key"

    if ! getent passwd "$username" >/dev/null; then
        useradd --create-home --shell /bin/bash "$username"
    fi
    account=$(getent passwd "$username")
    IFS=: read -r _ _ uid gid _ home shell <<< "$account"
    [[ $uid != 0 && $shell != */nologin && $shell != */false ]] || die 'The account must be a non-root user with an interactive login shell.'
    install_authorized_key "$home" "$uid" "$gid" "$public_key"

    /usr/sbin/sshd -t
    systemctl enable --now ssh.service
    if [[ -n $allow_from ]]; then
        if command -v ufw >/dev/null; then
            ufw allow from "$allow_from" to any port 22 proto tcp
        else
            printf 'UFW is not installed; no firewall rule was added.\n'
        fi
    fi
    if $passwordless_sudo; then
        configure_passwordless_sudo "$username" "$workdir"
    fi

    printf '\nSSH setup complete.\nUsername: %s\nIP addresses: ' "$username"
    hostname -I
    printf 'SSH service: '
    systemctl is-active ssh.service
    printf 'Server Ed25519 host fingerprint (compare on the client):\n'
    ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
    id "$username"
    printf 'Verify a fresh SSH login from the client before relying on remote access.\n'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
