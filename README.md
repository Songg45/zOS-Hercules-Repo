# zOS Hercules setup

This repository contains the Ubuntu/Lubuntu SSH setup used for the `zos-vm`
Hercules environment. The setup script creates or reuses `codex-zos-user`,
installs OpenSSH, authorizes a supplied public key, and optionally configures
passwordless sudo and an SSH firewall allowance.

## 1. Generate the key on the Windows client

In PowerShell, generate a dedicated key pair **if you do not already have one**:

```powershell
New-Item -ItemType Directory -Path "$env:USERPROFILE\.ssh" -Force | Out-Null
ssh-keygen.exe -t ed25519 -f "$env:USERPROFILE\.ssh\codex-zos-user_ed25519" -C "codex-zos-user@192.168.140.196"
Get-Content "$env:USERPROFILE\.ssh\codex-zos-user_ed25519.pub"
```

Choose a passphrase or press Enter for an unencrypted key suitable for unattended
use. Keep the private key on the client. Copy only the `.pub` file or its single
line of text to the server. The script never generates, uploads, or publishes a
private key. Our existing key pair remains in the Windows user's `.ssh` directory
and does not need to be regenerated.

## 2. Run the setup on Lubuntu

Open QTerminal from the existing desktop account. Clone this repository or copy
the script to the server, then run it with root privileges:

```bash
git clone https://github.com/Songg45/zOS-Hercules-Repo.git
cd zOS-Hercules-Repo

sudo bash scripts/setup-codex-ssh.sh \
  --username codex-zos-user \
  --public-key-file /path/to/codex-zos-user_ed25519.pub \
  --allow-from 192.168.140.139 \
  --passwordless-sudo
```

Replace `/path/to/codex-zos-user_ed25519.pub` with the location where you copied
the **public** key. Alternatively, replace `--public-key-file ...` with
`--public-key 'ssh-ed25519 AAAA... your-comment'`, using the complete public key
line printed on Windows. Run `bash scripts/setup-codex-ssh.sh --help` for usage.

The example's server address is `192.168.140.196`; the Windows client's source
address is `192.168.140.139`. Use the appropriate addresses for another machine.

The script:

- Installs `openssh-server` and `sudo` using `apt-get`.
- Creates a missing account with a home directory, Bash, and a locked password.
  Existing accounts keep their password, shell, and existing authorized keys.
- Adds the public key only if the exact line is not already present. The `.ssh`
  directory has mode `0700`, and `authorized_keys` has mode `0600`, owned by the
  login account. Symlinked SSH paths are rejected.
- Checks the existing SSH configuration and enables/starts `ssh.service`.
- Adds a port 22 allowance for `--allow-from` if UFW is installed. It does not
  install, enable, disable, or reset the firewall. The allowance does not restrict
  other access already permitted by the firewall. Omit the option to leave UFW
  rules unchanged.
- With `--passwordless-sudo`, adds the account to the `sudo` group and installs
  `codex-zos-user ALL=(ALL:ALL) NOPASSWD: ALL` in
  `/etc/sudoers.d/99-codex-zos-user` with root ownership and mode `0440`.
  This grants full administrative access without a password prompt. The rule is
  validated before installation; the complete sudoers policy and a real
  passwordless root command are checked afterward. A failed check restores the
  previous rule. Omit the option to leave the account's sudo permissions unchanged.
- Prints the account, IP addresses, service status, and the server's host-key
  fingerprint.

The setup can be rerun; it preserves unrelated keys and existing SSH settings.
It expects the usual SSH port 22 and existing systemd configuration. It does not
rewrite `sshd_config`, enable password logins, or change SSH host keys. Package
installation, account creation, and firewall updates are not rolled back if a
later step fails; fix the reported error and rerun. A live USB session requires
persistent storage for changes to survive a reboot.

For password-protected sudo instead, omit `--passwordless-sudo` and run these
locally as an administrator:

```bash
sudo usermod -aG sudo codex-zos-user
sudo passwd codex-zos-user
```

The password is entered locally and is not needed for SSH key authentication.

## 3. Verify access from Windows

Compare the host fingerprint shown by SSH with the fingerprint printed by the
server before accepting a new host key:

```powershell
ssh.exe -o IdentitiesOnly=yes -i "$env:USERPROFILE\.ssh\codex-zos-user_ed25519" codex-zos-user@192.168.140.196
```

In the SSH session, verify the account and passwordless sudo:

```bash
id
sudo -n -k id
```

The second command should show `uid=0(root)` when the passwordless option was
used. `-n` prevents a password prompt, and `-k` ignores cached authentication.
For standard password-protected sudo, use `sudo id` and enter the account password.

During the original setup, Windows `ssh-keyscan` could not negotiate the server's
default key exchange. Regular SSH worked with
`-o KexAlgorithms=curve25519-sha256`. If that same compatibility error occurs,
add this option to the Windows SSH command; keep host-key verification enabled.

## Validation

The regression checks run in temporary directories without changing real users,
SSH services, firewall rules, or sudoers files. They require Bash, OpenSSH's
`ssh-keygen`, and standard Unix utilities:

```bash
bash -n scripts/setup-codex-ssh.sh
bash tests/setup-codex-ssh.test.sh
shellcheck scripts/setup-codex-ssh.sh tests/setup-codex-ssh.test.sh
```
