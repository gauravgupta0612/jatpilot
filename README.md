# JarPilot for IBM i  (v1.0.0)

Fast, safe JAR installation on IBM i. Every install: validate JAR → SHA-256 check → backup current JAR → atomic replace → CHGAUT / CHGOWN → optional restart CL → log + history. One-command rollback.

| Folder / file | What it is | Use it when |
|---|---|---|
| `scripts/jarpilot.sh` | Core installer, runs on IBM i (PASE/QSH) | Everything uses this |
| `scripts/jarpilot.ps1` | Windows one-click: upload to IFS + install over SSH | JAR is on your PC |
| `scripts/JARPILOT.clle` | CL wrapper (`CALL JARPILOT`) | 5250, job scheduler, CL programs |
| `scripts/jarpilot.config.sample.json` | Defaults (host, user, target…) – copy to `jarpilot.config.json` | Avoid retyping |
| `vscode-extension/jarpilot-1.0.0.vsix` | Editor extension (right-click a `.jar` → Install) | You work in the editor |
| `jarpilot-1.0.0.plugin` | Assistant plugin (skill + `/jarpilot` command) | Ask Claude to install it for you |

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

## Editor extension
`code --install-extension vscode-extension\jarpilot-1.0.0.vsix` → Ctrl+Shift+P → **JarPilot: Configure IBM i connection** → right-click any `.jar` → **Install JAR on IBM i**.

## Exit codes
0 OK · 1 usage · 2 validation · 3 copy · 4 authority · 5 checksum / invalid JAR · 6 no backup for rollback.
Logs: `<target>/.jarpilot/logs/` · history: `<target>/.jarpilot/history` · backups: `<target>/.jarpilot/backup/`.

Requirements: SSH server on IBM i (`STRTCPSVR *SSHD`), OpenSSH client on the PC, user with authority to the target directory (CHGOWN needs *ALLOBJ or ownership).
