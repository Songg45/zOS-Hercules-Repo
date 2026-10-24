# z/OS 1.10 startup reference

Recorded: 2026-10-24.

This reference organizes the supplied startup notes and the
[linked 2015 setup walkthrough](https://herculesmainferame.blogspot.com/2015/11/instalando-o-hercules-zos-110-no-windows.html).
The messages below are reference examples, not a capture confirming the current
VM has completed startup.

## Recognizing the startup phases

The walkthrough describes the following sequence:

**WLM → JES2 → VTAM → UNIX System Services/file systems → TSO**

Use this as a guide for reading that ADCD startup. Message streams can interleave,
and the selected LOADPARM, startup members, and automation policy determine the
actual startup sequence. It is not a mandatory ordering for every z/OS system.

| Phase | Component | Message prefix | What to recognize |
| --- | --- | --- | --- |
| 1 | **WLM — Workload Manager** | `IWM...` | Workload-management initialization and policy messages. The walkthrough shows a warning that WLM is using its default policy. |
| 2 | **JES2 — Job Entry Subsystem 2** | `$HASP...` | Job-entry, spool, and JES2 initialization messages. The walkthrough describes a cold start for its example system. |
| 3 | **VTAM — Virtual Telecommunications Access Method** | `IST...` | Communications initialization and activation of network resources. |
| 4 | **z/OS UNIX System Services (USS/OMVS), including file-system startup** | `BPX...` for UNIX services; `IOEZ...` for zFS | UNIX initialization and file-system activity. zFS is a file-system component used by UNIX services. |
| 5 | **TSO — Time Sharing Option** | `IKT...` for TSO/VTAM | Terminal-control initialization and whether TSO is accepting logons. |

Message IDs are the useful identifiers. The walkthrough displays the WLM warning
in red and JES2 messages in white, but console colors depend on the terminal and
display settings.

## WLM default-policy warning

The source walkthrough includes this warning:

```text
IWM048E WLM RUNNING IN GOAL MODE WITH THE DEFAULT POLICY
```

Record the full message if it appears on this installation. It describes the
policy WLM is using; this reference does not change or activate a policy.

## JES2 startup mode

The cold start described in the walkthrough belongs to that example. JES2 also
supports other startup types; a cold start is not an action to repeat at every
IPL merely to follow this list. Use the intended startup configuration and the
actual JES2 messages to identify the mode in use.
[IBM JES2 initialization message reference](https://www.ibm.com/docs/en/zos/2.5.0?topic=hundreds-hasp400)
describes how `$HASP493` identifies the type of initialization being performed.

The `COLD` reply previously given to the `AOF603D` automation prompt is a separate
automation-initialization choice. That reply alone does not confirm JES2's
startup mode.

## VTAM readiness

The key completion message is:

```text
IST020I VTAM INITIALIZATION COMPLETE FOR ...
```

IBM identifies this as completion of VTAM initialization, after which VTAM
operator commands can be processed and VTAM applications can be started.
[IBM VTAM startup guide](https://www.ibm.com/docs/en/zos-basic-skills?topic=startup-vtam)

## UNIX services and zFS

The original notes call the UNIX phase "ZFS." More precisely, USS/OMVS provides
the UNIX environment, and zFS is a file-system component used within it.
IBM documents `BPX` messages as UNIX kernel/REXX messages and `IOEZ` messages as
zFS messages.
[IBM UNIX message prefixes](https://www.ibm.com/docs/en/zos/3.1.0?topic=messages-message-prefixes-issuing-modules),
[IBM zFS message guide](https://www.ibm.com/docs/en/zos/2.5.0?topic=codes-understanding-zfs-messages)

An example UNIX initialization milestone is:

```text
BPXI004I OMVS INITIALIZATION COMPLETE
```

This is an OMVS initialization milestone; individual services and file systems
can have their own additional messages.
[IBM OMVS startup considerations](https://www.ibm.com/docs/en/z-system-automation/4.2.0?topic=considerations-omvs-setup)

## TSO readiness and the first logon

The walkthrough shows these TSO startup messages (timestamp omitted):

```text
$HASP373 TSO STARTED
IEF403I TSO - STARTED
IKT007I TCAS ACCEPTING LOGONS
```

The first two identify the start of the TSO started task. The decisive message for
attempting a TSO logon is **`IKT007I TCAS ACCEPTING LOGONS`**. IBM's z/OS 1.10
message manual states that TSO/VTAM logons are accepted at this point. It also
defines `IKT005I TCAS IS INITIALIZED` as completion of TCAS initialization and
`IKT008I TCAS NOT ACCEPTING LOGONS` as the opposite logon state.
[IBM z/OS V1R10 Communications Server: SNA Messages](https://publibfp.boulder.ibm.com/epubs/pdf/f1a1c680.pdf)

Once the console reports that logons are accepted, try the configured TSO entry
from a 3270 terminal. A successful user logon confirms access through that
terminal path; a task-start message alone does not establish it.

## Deferred startup issue

The reported JES2 JOE resource-shortage warning at **81% utilization** is tracked
separately in [Known issues](known-issues.md). Investigation and remediation
remain deferred at the user's request.
