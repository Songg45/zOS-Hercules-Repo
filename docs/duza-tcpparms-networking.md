# DUZA.TCPPARMS TCP/IP configuration

Recorded: 2026-10-24. Environment: DUZA, z/OS V1.10, running under Hercules on
the Lubuntu `zos-vm` host.

These notes record the network section edited in the active TCP/IP profile
within **`DUZA.TCPPARMS`**. The screenshots did not show the member name. The
TCP/IP startup log identified the profile allocation as **`DD:PROFILE`**; that
DD name alone does not identify the member. Use the TCPIP started task's PROFILE
allocation to identify the active member before repeating the edits.

## Addresses and matching Hercules device

| Setting | Value used |
| --- | --- |
| Lubuntu host running Hercules | `192.168.140.196` |
| z/OS guest address | `192.168.140.200` |
| LAN subnet | `192.168.140.0/24` |
| Subnet mask | `255.255.255.0` |
| Default gateway | `192.168.140.1` |
| MTU | `1500` |
| Hercules LCS device pair | `0E20` / `0E21` |
| z/OS device name | `LCS1` |
| z/OS link name | `ETH1` |

The matching Hercules configuration line was verified as:

```text
0E20.2 LCS 192.168.140.200
```

The guest profile therefore uses an **LCS** device and an **Ethernet** link at
device address `E20`.

## Final profile section

Use this as the recorded network section of the existing profile, preserving
the other profile statements and avoiding duplicate device/link definitions:

```text
SACONFIG DISABLED

DEVICE LCS1 LCS E20
LINK ETH1 ETHERNET 0 LCS1

HOME
192.168.140.200 ETH1

PRIMARYINTERFACE ETH1

BEGINROUTES
ROUTE 192.168.140.0 255.255.255.0 = ETH1 MTU 1500
ROUTE DEFAULT 192.168.140.1 ETH1 MTU 1500
ENDROUTES

IPCONFIG NODATAGRAMFWD

UDPCONFIG RESTRICTLOWPORTS

TCPCONFIG RESTRICTLOWPORTS

START LCS1
```

## Changes and the naming error we corrected

1. Replaced the shown `DEVICE CTC1 CTC E20` definition with
   `DEVICE LCS1 LCS E20` to match the Hercules LCS adapter.
2. Replaced the shown CTC link with `LINK ETH1 ETHERNET 0 LCS1`. This provides
   the `ETH1` link already referenced by HOME, PRIMARYINTERFACE, and the routes.
3. Changed the subnet route destination from `192.168.140.200` to the canonical
   network address `192.168.140.0`, retaining mask `255.255.255.0`, link `ETH1`,
   and MTU `1500`.
4. Changed `START CTC1` to `START LCS1` so startup references the LCS device.

The intermediate edit accidentally left off the final `1`:

```text
LINK ETH1 ETHERNET 0 LCS
```

The final operand must match the device name exactly. The corrected pair is:

```text
DEVICE LCS1 LCS E20
LINK ETH1 ETHERNET 0 LCS1
```

That typo caused the following reported errors, with later errors following
from the failure to define `ETH1`:

```text
EZZ0328I DEVICE LCS ON LINE 91 HAS NOT BEEN DEFINED OR HAS BEEN DELETED
EZZ0328I LINK NAME ETH1 ... HAS NOT BEEN DEFINED OR HAS BEEN DELETED
EZZ0312I THE BEGINROUTES ROUTE BLOCK ENTRY ... CONTAINS AN INCORRECT VALUE ETH1
EZZ0353I DEVICE LCS1 ON LINE 107 IS DEFINED WITH NO LINKS
```

The names have distinct roles:

- `LCS1` is the device name, used by the LINK statement's last operand and START.
- `ETH1` is the link name, used by HOME, PRIMARYINTERFACE, and the ROUTE entries.
- `192.168.140.200` is the guest IP address assigned to that link.

The HOME address, PRIMARYINTERFACE, default gateway, SACONFIG, IPCONFIG, and
UDP/TCP low-port restrictions shown above were retained from the supplied
profile section. Correcting the device and link definitions connected those
existing references to the intended adapter.

## Applying the edit and observed results

Save the active profile member and have TCP/IP process it through the
installation's configured reload/start procedure. Saving in ISPF updates the
data set; the running stack must process the profile to apply the changes. The
exact operator command used in this session was not captured.

After the name correction, the supplied console output reported these
milestones. Timestamps and job IDs are omitted, and wrapped lines are joined:

```text
EZZ0316I PROFILE PROCESSING COMPLETE FOR FILE DD:PROFILE
EZB6473I TCP/IP STACK FUNCTIONS INITIALIZATION COMPLETE.
EZAIN11I ALL TCPIP SERVICES FOR PROC TCPIP ARE AVAILABLE.
EZZ4314I INITIALIZATION COMPLETE FOR DEVICE LCS1, LINK ETH1
TCPIP IS UP - UP
```

The user then ran `PING GOOGLE.COM` from the ISPF command shell. It resolved
to `172.253.63.139` and reported a response in `0.020` seconds. This confirmed
hostname resolution and an external ICMP round trip at the time of the test.

The z/OS FTP server subsequently answered on `192.168.140.200:21`, and the Linux
client successfully downloaded the sequential data set `IBMUSER.HELLO.HI`.
The earlier Linux `Permission denied` error while creating the local download
was traced to the Linux FTP client's AppArmor profile. The persistent allowance
for `/mainframe/ftp` is documented in the
[FTP/AppArmor setup instructions](../README.md#allow-ftp-downloads-into-mainframeftp)
and implemented by
[`configure-tnftp-apparmor.sh`](../scripts/configure-tnftp-apparmor.sh).

## Terminal and FTP connection addresses

| Connection | Address verified during this session | Result |
| --- | --- | --- |
| Hercules TN3270 listener | `192.168.140.196:23` | TCP connection succeeded; the VM listener belonged to Hercules and its configuration used `CNSLPORT 23`. |
| z/OS FTP server | `192.168.140.200:21` | FTP greeting and data set download succeeded. |
| Port 23 on the z/OS guest address | `192.168.140.200:23` | Connection was refused during testing. |

Keep `192.168.140.200` in the guest's HOME definition. Use the Lubuntu host's
`192.168.140.196:23` endpoint for the Hercules terminal connection.

## Other messages seen during startup

- `EZZ0334I IP FORWARDING IS DISABLED` agrees with the retained
  `IPCONFIG NODATAGRAMFWD` setting.
- `EZZ0338I TCP PORTS 1 THRU 1023 ARE RESERVED` and the corresponding UDP message
  agree with the retained low-port restrictions. These messages do not indicate
  that every one of those ports has a listening service.
- `EZZ0655I PORT ... IS ALREADY RESERVED` appeared for BBODMGR/BBODMNC port
  reservations. Those messages remained while the stack and LCS device completed
  initialization. No port-reservation cleanup was recorded in this session.

The separate, deferred JES2 JOE resource-shortage warning remains in
[Known issues](known-issues.md).

## References

- [IBM z/OS V1R10 Communications Server: IP Configuration Reference](https://publibfp.boulder.ibm.com/epubs/pdf/f1a1b480.pdf): DEVICE/LINK, HOME, PRIMARYINTERFACE, and routing statements.
- [IBM z/OS V1R10 Communications Server: IP Messages, Volume 4](https://publib.boulder.ibm.com/epubs/pdf/f1a1d180.pdf): EZZ profile-processing and initialization messages.
- [SDL Hercules configuration reference](https://sdl-hercules-390.github.io/html/hercconf.html): LCS device definitions and CNSLPORT terminal connections.
- [IBM FTP data set and member examples](https://www.ibm.com/docs/en/zos/2.5.0?topic=ftp-examples-get-mget-mvsget-subcommands).
