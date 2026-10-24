# Known issues

## JES2 JOE resource shortage during z/OS 1.10 startup

- Reported: 2026-10-24.
- Status: Open; investigation and remediation deferred at the user's request.
- Environment: z/OS 1.10 on Hercules.
- User-reported startup message, preserved verbatim:

  ```text
  JES2 resource shortage of JOES - 81% utilization reached
  ```

The user cannot address this issue right now. The cause, operational impact,
current utilization, and configured resource limits have not been independently
verified. No JES2 settings or running workloads were changed in response to this
report.

When the user is ready to revisit it, first collect the full message (including
its message ID) and inspect the current JOE usage and limits before selecting a
remediation.
