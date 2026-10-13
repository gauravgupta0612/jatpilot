# JarPilot for IBM i

One-click JAR installation on IBM i from VS Code.

## Commands (Ctrl+Shift+P → "JarPilot")
- **Install JAR on IBM i (upload from PC)** – also on right-click of any `.jar` in the Explorer
- **Install JAR already on IFS**
- **Rollback last JAR install**
- **Show JAR install status**
- **Configure IBM i connection**

Each install: uploads to IFS staging → validates JAR → SHA-256 check → backs up the current JAR → atomic replace → CHGAUT/CHGOWN → optional restart CL command → log in `<target>/.jarpilot/logs`.

Requires an SSH client (`ssh`/`scp`, built into Windows 10/11) and SSH (5733-SC1 / `STRTCPSVR *SSHD`) on the IBM i.

## Server setup (v1.1.0)
Right-click a server setup `.jar` → **Install server from setup JAR (guided)**. The JarPilot terminal asks the installation steps (directory, library/iASP, instance, ports, job user, job queue, start command) and refuses any library, directory, instance or port that another server already uses, proposing a free one. Then it installs, runs `ADDLIBLE` + your start command, and checks `/about`. Also: **Start server** and **Check server (/about)**.
