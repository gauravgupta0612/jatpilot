# JarPilot for IBM i  (v1.1.0)

Fast, safe JAR installation on IBM i. Every install: validate JAR → SHA-256 check → backup current JAR → atomic replace → CHGAUT / CHGOWN → optional restart CL → log + history. One-command rollback.

| Folder / file | What it is | Use it when |
|---|---|---|
| `scripts/jarpilot.sh` | Core installer, runs on IBM i (PASE/QSH) | Everything uses this |
| `scripts/jarpilot.ps1` | Windows one-click: upload to IFS + install over SSH | JAR is on your PC |
| `scripts/JARPILOT.clle` | CL wrapper (`CALL JARPILOT`) | 5250, job scheduler, CL programs |
| `scripts/jarpilot.config.sample.json` | Defaults (host, user, target…) – copy to `jarpilot.config.json` | Avoid retyping |
| `vscode-extension/jarpilot-1.1.0.vsix` | Editor extension (right-click a `.jar` → Install) | You work in the editor |
| `jarpilot-1.1.0.plugin` | Assistant plugin (skill + `/jarpilot` command) | Ask Claude to install it for you |

## Quick start
1. **Once on IBM i** (optional, for CL use): copy `jarpilot.sh` to `/QOpenSys/jarpilot/` and `CRTBNDCL PGM(MYLIB/JARPILOT) SRCSTMF('/QOpenSys/jarpilot/JARPILOT.clle')`.
2. **From PC (upload + install):**
   `.\jarpilot.ps1 -IbmiHost myibmi -User DEV -Jar C:\build\app.jar -Target /apps/java/lib`
3. **JAR already on IFS:**
   `.\jarpilot.ps1 -IbmiHost myibmi -User DEV -IfsJar /home/dev/app.jar -Target /apps/java/lib`
   or on IBM i: `sh /QOpenSys/jarpilot/jarpilot.sh install --jar /home/dev/app.jar --target /apps/java/lib`
   or 5250: `CALL JARPILOT PARM('install' '/home/dev/app.jar' '/apps/java/lib' '*RX')`
4. **Rollback / status:** `-Action rollback -Name app.jar` · `-Action status`
5. **Preview:** add `-DryRun`.

## Server setup from a setup JAR
After the server setup JAR is on the IFS, JarPilot goes straight into the installation steps and **checks every answer on IBM i first**, so a new server never overlaps an existing one:

| Step | Asked | Default | Refused when |
|---|---|---|---|
| 3 | Installation directory | – | directory exists and is not empty |
| 4 | Server library / iASP | – / `*SYSBAS` | library already exists (in *SYSBAS or the iASP) → a free name (`<LIB>01`…) is proposed; iASP not varied on |
| 5 | Instance name | – | an active job already uses the name |
| 6 | HTTP / HTTPS port | `5257` / `52570` | port already listening → next free port proposed |
| 7 | Job user | current user | profile does not exist |
| 8 | Job queue library / job queue | `QGPL` / `QBATCH` | library or job queue does not exist |
| 9 | Start command (CL, `&INSTANCE` = instance) | – | empty (skip with `--no-start`) |

Then: summary → confirm → runs `java -jar <setup>.jar` and feeds it the checked answers (**auto**, default) or lets you type them (**--manual**) → verifies the library and directory were created → `ADDLIBLE <lib>` + your start command → waits for the port → checks `http://<host>:<port>/about`.

- Editor: right-click the setup `.jar` → **Install server from setup JAR (guided)**; also **Start server** and **Check server (/about)**.
- PC: `.\jarpilot.ps1 -IbmiHost myibmi -User QSECOFR -Action server-setup -Jar C:\dl\setup-server.jar`
- On IBM i (QSH, as QSECOFR or equivalent): `sh /QOpenSys/jarpilot/jarpilot.sh server-setup --jar /tmp/setup-server.jar`
- Non-interactive: give all values as options and add `--yes` (stops with rc 7 on any conflict). `--no-start` skips Step 9; `--dry-run` previews.
- Later: `server-start --lib MYLIB --instance MYSRV --start-cmd "STRMYSVR INSTANCE(&INSTANCE)"` · `server-check --http-port 5257`

## Editor extension
`code --install-extension vscode-extension\jarpilot-1.1.0.vsix` → Ctrl+Shift+P → **JarPilot: Configure IBM i connection** → right-click any `.jar` → **Install JAR on IBM i**.

## Exit codes
0 OK · 1 usage · 2 validation · 3 copy · 4 authority · 5 checksum / invalid JAR · 6 no backup for rollback · 7 server conflict (library / directory / instance / port already used) · 8 server installer failed · 9 server did not start.
Server setup logs: `/tmp/jarpilot/.jarpilot/logs/`.
Logs: `<target>/.jarpilot/logs/` · history: `<target>/.jarpilot/history` · backups: `<target>/.jarpilot/backup/`.

Requirements: SSH server on IBM i (`STRTCPSVR *SSHD`), OpenSSH client on the PC, user with authority to the target directory (CHGOWN needs *ALLOBJ or ownership).
