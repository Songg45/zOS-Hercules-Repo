# zOS Hercules setup

This repository contains separate Ubuntu/Lubuntu scripts for the `zos-vm`
Hercules environment:

- [`scripts/setup-codex-ssh.sh`](scripts/setup-codex-ssh.sh) creates or reuses
  `codex-zos-user`, installs OpenSSH, authorizes a supplied public key, and
  optionally configures passwordless sudo and an SSH firewall allowance.
- [`scripts/install-hercules.sh`](scripts/install-hercules.sh) builds and installs
  SDL Hercules Hyperion and reboots automatically after successful verification.
- [`scripts/configure-tnftp-apparmor.sh`](scripts/configure-tnftp-apparmor.sh)
  allows the Linux FTP client to save directly into `/mainframe/ftp` while keeping
  its AppArmor profile enforced.

Startup and operations notes:

- [z/OS 1.10 startup reference](docs/zos-1.10-startup.md): subsystem sequence from
  the supplied walkthrough, console message prefixes, and TSO readiness messages.
- [Known issues](docs/known-issues.md): the deferred JES2 JOE resource-shortage
  warning reported at 81% utilization.

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

## Build and install Hercules

Run the separate installer from an existing root/admin account on Lubuntu:

```bash
sudo bash scripts/install-hercules.sh
```

**The default run automatically reboots the machine when installation and
verification succeed.** No final confirmation or manual reboot is required.
Any failed prerequisite, build, install, profile update, or verification stops
the script before its reboot step. An SSH session disconnects during reboot.

This automates the supplied shell history:

1. Installs the packages from the history plus `zlib1g-dev` and the current Ubuntu
   build prerequisites listed in the
   [upstream installation guide](https://sdl-hercules-390.github.io/html/hercinst.html).
2. Creates `/mainframe` and clones
   `https://github.com/SDL-Hercules-390/hyperion.git` into `/mainframe/hyperion`.
   A matching existing checkout is rebuilt at its current revision. Existing
   source changes are preserved; it does not run `git pull` or reset the checkout.
3. Runs `./autogen.sh`, then
   `./configure --enable-cckd-bzip2 --enable-regina-rexx`. Both requested features
   are checked in the generated `config.h` before compilation.
4. Runs `make` and `make install`, using the default `/usr/local` install prefix.
5. Adds `export LD_LIBRARY_PATH="/lib:/usr/lib:/usr/local/lib"` to the selected
   account's `.bashrc` once, preserving an existing file's original contents in
   `.bashrc.hercules.bak` before the first change. It also sets the variable for
   the current run and refreshes the loader cache with `ldconfig`.
6. Runs the installed binary with `--help=version` and `--help=build` to verify
   it loads and exits without starting an emulator session.
7. Runs `systemctl reboot` automatically.

When invoked through `sudo`, the profile account defaults to the invoking user.
When invoked directly as root, it defaults to root, matching `~/.bashrc` in the
supplied root-shell history. To edit `zosadmin`'s profile from a root shell:

```bash
bash scripts/install-hercules.sh --profile-user zosadmin
```

Optional flags include `--work-dir /another/absolute/directory` and `--no-reboot`.
Upstream now recommends its pre-generated configure script; `--skip-autogen`
uses that approach. The default retains the supplied history's autogen step.
Run `bash scripts/install-hercules.sh --help` to see all options.

The installer does not download guest operating systems, copy DASD images,
rewrite Hercules configuration, or start the emulator. Package installation and
installation under `/usr/local` are not transactional; if a step fails, inspect
the error before rerunning.

## Allow FTP downloads into /mainframe/ftp

On Lubuntu, run this once from the repository checkout:

```bash
sudo bash scripts/configure-tnftp-apparmor.sh
```

This fixes a local download failure such as:

```text
125 Sending data set IBMUSER.HELLO.HI FIXrecfm 80
ftp: Can't open `HELLO.HI': Permission denied
```

In our environment, the kernel logged an AppArmor denial for the `tnftp` client
creating `/mainframe/ftp/HELLO.HI`, even though FTP was running as root. The script
adds the following persistent exception to `/etc/apparmor.d/local/tnftp`:

```text
owner /mainframe/ftp/ r,
owner /mainframe/ftp/* rw,
```

The rules permit directory reads and owner-only file reads/writes directly inside
`/mainframe/ftp`. They do not cover nested directories. Linux ownership and mode
permissions still apply; an existing root-owned `0755` directory remains writable
only by root. The script creates the directory with mode `0755` if it is missing,
and preserves existing directory permissions.

The script preserves other local rules, avoids duplicate entries on reruns,
validates the complete candidate policy before installing it, reloads only the
`tnftp` profile, and checks that it remains in enforce mode. It uses Ubuntu's
[local override mechanism](https://ubuntu.com/server/docs/changing-package-files/)
and preserves the packaged `/etc/apparmor.d/tnftp` file. It requires the existing
profile to be loaded in enforce mode and to include `local/tnftp`; it does not
install packages, disable AppArmor, or change the profile to complain mode.

Before changing an override, it saves the original profile and any previous
override under `/var/backups/tnftp-apparmor.<timestamp>.<random>/`. That directory
also contains `restore.txt` describing how to restore the prior state. A failed
reload or enforce-mode check restores the previous override, or removes the new
override if none existed, and attempts to reload the restored policy. Directory
creation and backup files are retained if a later step fails. Symlinked policy
files and destination directories are rejected.

After configuration, run these commands **on Linux** to connect to the z/OS FTP
server. `192.168.140.200` is the guest's TCP/IP address; `192.168.140.196` is the
Lubuntu host providing the Hercules terminal connection.

```bash
ftp 192.168.140.200
```

Log in with your z/OS account, then enter at the `ftp>` prompt:

```text
lcd /mainframe/ftp
ascii
get 'IBMUSER.HELLO.HI' HELLO.HI
bye
```

Replace the data set name with your own. `ascii` is for JCL, source, and other
text; it requests EBCDIC-to-ASCII conversion. The sample is a sequential data
set. To retrieve a PDS member, use a name such as `'IBMUSER.TEST.JCL(HELLO)'`.
`lcd` chooses the local Linux directory; `cd` changes the remote z/OS location.
An existing local file with the requested output name can be overwritten by
`get`. See [IBM's FTP examples](https://www.ibm.com/docs/en/zos/2.5.0?topic=ftp-examples-get-mget-mvsget-subcommands)
for data set and member transfers.

## Validation

The regression checks run in temporary directories without changing real users,
SSH services, firewall rules, sudoers files, or AppArmor policy. Hercules build
tests also mock package installation, compilation, system installation, and
reboot. AppArmor tests mock the policy parser/reloader and exercise failure
recovery in isolated fixtures. If `apparmor_parser` is installed, they also
validate generated fixture policies with the native parser and kernel loading
disabled. They require
Bash, OpenSSH's `ssh-keygen`, and standard Unix utilities:

```bash
bash -n scripts/setup-codex-ssh.sh
bash -n scripts/install-hercules.sh
bash -n scripts/configure-tnftp-apparmor.sh
bash tests/setup-codex-ssh.test.sh
bash tests/install-hercules.test.sh
bash tests/configure-tnftp-apparmor.test.sh
shellcheck scripts/*.sh tests/*.sh
```

The [Shell checks workflow](.github/workflows/shell-checks.yml) runs these checks
on Ubuntu, including the native AppArmor parser validation. Its fixture tests do
not load policy into the runner's kernel.
