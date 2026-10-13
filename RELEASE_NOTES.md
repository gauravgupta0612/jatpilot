## JarPilot for IBM i v1.1.0

**New: guided server setup from a setup JAR**
- After the setup JAR is on the IFS, goes straight into the installation steps: install directory, library + iASP, instance, HTTP/HTTPS ports, job user, job queue library + job queue, start command
- Checks every answer on IBM i before installing - an existing library, non-empty directory, active instance name or busy port is refused and a free alternative is proposed, so a new server never overlaps an existing one
- Runs the installer with the checked answers (auto) or lets you answer it yourself (manual), then verifies the result
- Starts the server (`ADDLIBLE` + your start command), waits for the port and checks `/about`
- Editor commands: Install server from setup JAR (guided), Start server, Check server (/about)
- PowerShell: `-Action server-setup | server-start | server-check`
- New exit codes: 7 conflict, 8 installer failed, 9 server did not start

## JarPilot for IBM i v1.0.0

One-click, safe JAR installation on IBM i.

**Features**
- Upload a JAR from your PC to the IFS, or install one already on the IFS
- JAR validation and SHA-256 checksum check
- Automatic backup of the current JAR, atomic replace, one-command rollback
- CHGAUT / CHGOWN authority setup and optional restart CL command
- Logs and history under `<target>/.jarpilot/`
- Dry-run mode

**Downloads**
- `jarpilot-1.1.0.vsix` - editor extension (right-click a `.jar` → Install JAR on IBM i / Install server from setup JAR)
- `jarpilot-1.1.0.plugin` - assistant plugin (skill + `/jarpilot` command)
- Scripts (`jarpilot.sh`, `jarpilot.ps1`, `JARPILOT.clle`) are in the source code archive under `scripts/`

**Requirements**
SSH server on IBM i (`STRTCPSVR *SSHD`), OpenSSH client on the PC. Server setup: QSECOFR or equivalent.
