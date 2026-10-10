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
- `jarpilot-1.0.0.vsix` - editor extension (right-click a `.jar` → Install JAR on IBM i)
- `jarpilot-1.0.0.plugin` - assistant plugin (skill + `/jarpilot` command)
- Scripts (`jarpilot.sh`, `jarpilot.ps1`, `JARPILOT.clle`) are in the source code archive under `scripts/`

**Requirements**
SSH server on IBM i (`STRTCPSVR *SSHD`), OpenSSH client on the PC.
