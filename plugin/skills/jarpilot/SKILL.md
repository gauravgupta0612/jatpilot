---
name: jarpilot
description: Install, upgrade, roll back or check a JAR on IBM i (IFS) with JarPilot — upload from PC or use a JAR already on IFS. Also guided server setup from a server setup JAR with library / directory / instance / port overlap checks. Use for "install jar on ibmi", "deploy jar to IFS", "install server from setup jar", "jarpilot".
---

# JarPilot — IBM i JAR installation

Goal: install a JAR on the IBM i IFS quickly and safely: validate → checksum → backup → atomic replace → authorities → optional restart → log. Rollback is one command.

## 1. Collect inputs (one AskUserQuestion if missing)
- Source: (a) JAR on the PC → upload; (b) JAR already on IFS.
- IBM i host, user profile, SSH port (22), target IFS directory, final JAR name.
- Optional: owner (CHGOWN), *PUBLIC authority (default `*RX`), backups to keep (5), restart CL command.
Never ask for a password in chat — SSH prompts in the user's own terminal, or use a key file.

## 2. Install paths
(a) Upload from PC (PowerShell, in the `scripts` folder):
```powershell
.\jarpilot.ps1 -IbmiHost <host> -User <user> -Jar <C:\path\app.jar> -Target <ifs-dir> [-Name app.jar] [-Owner X] [-Restart "<CL>"]
```
(b) JAR already on IFS:
```powershell
.\jarpilot.ps1 -IbmiHost <host> -User <user> -IfsJar /path/app.jar -Target <ifs-dir>
```
or on IBM i: `/QOpenSys/usr/bin/sh /QOpenSys/jarpilot/jarpilot.sh install --jar /path/app.jar --target <ifs-dir>`
or 5250 / job scheduler: `CALL JARPILOT PARM('install' '/path/app.jar' '<ifs-dir>' '*RX')`

## 3. Other actions
- Rollback: `-Action rollback -Target <dir> -Name app.jar`
- Status: `-Action status`
- Preview: `-DryRun` / `--dry-run`

## 3b. Server setup from a setup JAR
Needs QSECOFR or equivalent. After the JAR is on the IFS the wizard asks the steps in the user's terminal and refuses anything already used by another server (existing library in *SYSBAS/iASP, non-empty directory, active instance name, busy port), proposing a free value. Then it runs the installer (auto-answers, or `--manual`), verifies, runs `ADDLIBLE` + the start command and checks `/about`.
```powershell
.\jarpilot.ps1 -IbmiHost <host> -User QSECOFR -Action server-setup -Jar <C:\path\setup-server.jar>
.\jarpilot.ps1 -IbmiHost <host> -User QSECOFR -Action server-setup -IfsJar /tmp/setup-server.jar -InstallDir /home/x -Lib MYLIB -Instance MYSRV -HttpPort 5258 -HttpsPort 52580 -JobUser X -StartCmd "<CL using &INSTANCE>" -Yes
.\jarpilot.ps1 -IbmiHost <host> -User QSECOFR -Action server-start -Lib MYLIB -Instance MYSRV -StartCmd "<CL using &INSTANCE>"
.\jarpilot.ps1 -IbmiHost <host> -User QSECOFR -Action server-check -HttpPort 5257
```
On IBM i (QSH): `sh /QOpenSys/jarpilot/jarpilot.sh server-setup --jar /tmp/setup-server.jar`
Defaults: iASP *SYSBAS, ports 5257/52570, job queue QGPL/QBATCH; library, instance and start command are asked.

## 4. Report
Installed path, SHA-256, backup created, authority set, restart result, log path (`<target>/.jarpilot/logs`). Exit codes: 2 validation, 3 copy, 4 authority (*ALLOBJ / ownership), 5 checksum / invalid JAR, 6 no backup, 7 server conflict (library/dir/instance/port in use — pick the proposed free value), 8 vendor installer failed (retry with `--manual`), 9 server did not start (check instance job log) — propose the fix.
