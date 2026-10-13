#!/QOpenSys/usr/bin/sh
# =============================================================================
#  JarPilot for IBM i  (jarpilot)  v1.1.0
#  Installs / upgrades / rolls back a JAR on the IBM i IFS in one command.
#  Runs on IBM i (PASE / QSH). POSIX sh — no open-source packages required.
#
#  Usage:
#    jarpilot.sh install  --jar <ifs-path-of-new-jar> --target <ifs-dir>
#                         [--name <final.jar>] [--owner <USRPRF>]
#                         [--public-aut *RX|*R|*EXCLUDE] [--keep <n>]
#                         [--sha256 <expected>] [--restart "<CL command>"]
#                         [--dry-run]
#    jarpilot.sh rollback --target <ifs-dir> --name <final.jar> [--restart "<CL>"]
#    jarpilot.sh status   --target <ifs-dir> [--name <final.jar>]
#
#  Server setup (any server setup JAR, e.g. setup-server.jar) - guided,
#  every answer is checked so it cannot overlap an existing server:
#    jarpilot.sh server-setup --jar <ifs-path-of-setup-jar>
#                         [--install-dir </home/...>] [--lib <LIB>]
#                         [--iasp *SYSBAS] [--instance <NAME>]
#                         [--http-port 5257] [--https-port 52570]
#                         [--job-user <USRPRF>] [--jobq-lib QGPL]
#                         [--jobq QBATCH] [--host <name-for-url>]
#                         [--start-cmd "<CL using &INSTANCE>"]
#                         [--auto|--manual] [--yes] [--no-start] [--dry-run]
#    jarpilot.sh server-start --lib <LIB> --instance <NAME> --start-cmd "<CL>"
#                         [--iasp <IASP>]
#                         [--http-port 5257]
#    jarpilot.sh server-check [--http-port 5257] [--host <name>]
#
#  Exit codes: 0 OK, 1 usage, 2 validation, 3 copy, 4 authority, 5 verify,
#              6 rollback, 7 server conflict (library/dir/instance/port in use),
#              8 server installer failed, 9 server start/check failed
# =============================================================================

VERSION="1.1.0"
ACTION="$1"; [ $# -gt 0 ] && shift

JAR=""; TARGET=""; NAME=""; OWNER=""; PUBAUT="*RX"; KEEP=5
SHA=""; RESTART=""; DRYRUN=0
# server-setup defaults (from the installation guide)
S_DIR=""; S_LIB=""; S_IASP="*SYSBAS"; S_INST=""; S_STARTCMD=""
S_HTTP=5257; S_HTTPS=52570; S_JOBUSR=""; S_JOBQLIB="QGPL"; S_JOBQ="QBATCH"
S_HOST=""; S_MODE=""; S_YES=0; S_START=1; S_WAIT=120

while [ $# -gt 0 ]; do
  case "$1" in
    --jar)        JAR="$2"; shift 2 ;;
    --target)     TARGET="$2"; shift 2 ;;
    --name)       NAME="$2"; shift 2 ;;
    --owner)      OWNER="$2"; shift 2 ;;
    --public-aut) PUBAUT="$2"; shift 2 ;;
    --keep)       KEEP="$2"; shift 2 ;;
    --sha256)     SHA="$2"; shift 2 ;;
    --restart)    RESTART="$2"; shift 2 ;;
    --dry-run)    DRYRUN=1; shift ;;
    --install-dir) S_DIR="$2"; shift 2 ;;
    --lib)        S_LIB="$2"; shift 2 ;;
    --iasp)       S_IASP="$2"; shift 2 ;;
    --instance)   S_INST="$2"; shift 2 ;;
    --http-port)  S_HTTP="$2"; shift 2 ;;
    --https-port) S_HTTPS="$2"; shift 2 ;;
    --job-user)   S_JOBUSR="$2"; shift 2 ;;
    --jobq-lib)   S_JOBQLIB="$2"; shift 2 ;;
    --jobq)       S_JOBQ="$2"; shift 2 ;;
    --host)       S_HOST="$2"; shift 2 ;;
    --start-cmd)  S_STARTCMD="$2"; shift 2 ;;
    --wait)       S_WAIT="$2"; shift 2 ;;
    --auto)       S_MODE=auto; shift ;;
    --manual)     S_MODE=manual; shift ;;
    --yes)        S_YES=1; shift ;;
    --no-start)   S_START=0; shift ;;
    -h|--help)    ACTION="help"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

TS=$(date +%Y%m%d-%H%M%S)
LOGDIR="${TARGET:-/tmp}/.jarpilot/logs"
case "$ACTION" in server-*) LOGDIR="/tmp/jarpilot/.jarpilot/logs"; mkdir -p "$LOGDIR" 2>/dev/null ;; esac
LOG="$LOGDIR/jarpilot-$TS.log"

log()  { echo "[$(date +%H:%M:%S)] $*"; [ -d "$LOGDIR" ] && echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }
die()  { log "ERROR: $2"; exit "$1"; }
run()  { if [ $DRYRUN -eq 1 ]; then log "DRY-RUN: $*"; else "$@"; fi; }
cl()   { # run a CL command, fail on error
  if [ $DRYRUN -eq 1 ]; then log "DRY-RUN CL: $1"; return 0; fi
  /QOpenSys/usr/bin/system -v "$1" >> "$LOG" 2>&1
}

sha256() { # best effort checksum, PASE has openssl
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif [ -x /QOpenSys/usr/bin/openssl ]; then /QOpenSys/usr/bin/openssl dgst -sha256 "$1" | awk '{print $NF}'
  else echo "n/a"; fi
}

verify_jar() { # a JAR is a zip: check magic bytes PK\003\004
  magic=$(od -An -c -N2 "$1" 2>/dev/null | tr -d ' ')
  [ "$magic" = "PK" ]
}

usage() { sed -n '2,34p' "$0"; }

do_install() {
  [ -n "$JAR" ] && [ -n "$TARGET" ] || { usage; exit 1; }
  [ -f "$JAR" ] || die 2 "JAR not found on IFS: $JAR"
  [ -n "$NAME" ] || NAME=$(basename "$JAR")
  mkdir -p "$TARGET/.jarpilot/backup" "$LOGDIR" 2>/dev/null || die 2 "Cannot create $TARGET"
  log "JarPilot v$VERSION — install $JAR -> $TARGET/$NAME"

  verify_jar "$JAR" || die 5 "$JAR is not a valid JAR/ZIP file"
  NEWSUM=$(sha256 "$JAR"); log "SHA-256: $NEWSUM"
  if [ -n "$SHA" ] && [ "$SHA" != "$NEWSUM" ]; then die 5 "Checksum mismatch (expected $SHA)"; fi

  DEST="$TARGET/$NAME"
  if [ -f "$DEST" ]; then
    BK="$TARGET/.jarpilot/backup/$NAME.$TS"
    log "Backing up current JAR -> $BK"
    run cp -p "$DEST" "$BK" || die 3 "Backup failed"
  fi

  if [ "$(cd "$(dirname "$JAR")" && pwd)/$(basename "$JAR")" != "$DEST" ]; then
    log "Copying JAR"
    run cp "$JAR" "$DEST.jarpilot-tmp" || die 3 "Copy failed"
    run mv "$DEST.jarpilot-tmp" "$DEST" || die 3 "Rename failed"
  fi
  run setccsid 819 "$DEST" 2>/dev/null

  log "Setting authorities (*PUBLIC $PUBAUT)"
  cl "CHGAUT OBJ('$DEST') USER(*PUBLIC) DTAAUT($PUBAUT) OBJAUT(*NONE)" || die 4 "CHGAUT failed (see $LOG)"
  if [ -n "$OWNER" ]; then
    cl "CHGOWN OBJ('$DEST') NEWOWN($OWNER) RVKOLDAUT(*YES)" || die 4 "CHGOWN failed (see $LOG)"
  fi

  if [ $DRYRUN -eq 0 ]; then
    [ "$(sha256 "$DEST")" = "$NEWSUM" ] || die 5 "Post-copy checksum differs"
    verify_jar "$DEST" || die 5 "Installed file is not a valid JAR"
  fi
  echo "$TS $NAME $NEWSUM" >> "$TARGET/.jarpilot/history"

  # prune old backups
  ls -1t "$TARGET/.jarpilot/backup/$NAME".* 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r f; do
    log "Pruning old backup $f"; run rm -f "$f"; done

  if [ -n "$RESTART" ]; then log "Restart: $RESTART"; cl "$RESTART" || log "WARNING: restart command failed"; fi
  log "SUCCESS — $DEST installed. Log: $LOG"
}

do_rollback() {
  [ -n "$TARGET" ] && [ -n "$NAME" ] || { usage; exit 1; }
  mkdir -p "$LOGDIR"
  LAST=$(ls -1t "$TARGET/.jarpilot/backup/$NAME".* 2>/dev/null | head -1)
  [ -n "$LAST" ] || die 6 "No backup found for $NAME"
  log "Rolling back $NAME from $LAST"
  run cp -p "$LAST" "$TARGET/$NAME" || die 6 "Rollback copy failed"
  run rm -f "$LAST"
  echo "$TS $NAME ROLLBACK $(basename "$LAST")" >> "$TARGET/.jarpilot/history"
  if [ -n "$RESTART" ]; then cl "$RESTART" || log "WARNING: restart command failed"; fi
  log "SUCCESS — rollback complete"
}

do_status() {
  [ -n "$TARGET" ] || { usage; exit 1; }
  echo "== JarPilot status: $TARGET"
  ls -l "$TARGET"/*.jar 2>/dev/null
  echo "== Backups"; ls -lt "$TARGET/.jarpilot/backup/${NAME}"* 2>/dev/null
  echo "== History (last 10)"; tail -10 "$TARGET/.jarpilot/history" 2>/dev/null
}


# =============================================================================
#  SERVER SETUP  (any server setup JAR delivered for IBM i)
#  Guided Steps 3-9 with overlap checks: a new server never reuses an existing
#  library, install directory, instance name or TCP port.
# =============================================================================
ERR=""
up()      { echo "$1" | tr 'abcdefghijklmnopqrstuvwxyz' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'; }
name_ok() { echo "$1" | grep -Eq '^[A-Z$#@][A-Z0-9$#@_]{0,9}$'; }
is_num()  { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

sql_hit() { # true when the SELECT returns the marker J_HIT
  /QOpenSys/usr/bin/qsh -c "db2 \"$1\"" 2>/dev/null | grep -q 'J_HIT'
}
lib_exists() { # lib_exists <LIB> <IASP|*SYSBAS>
  [ -d "/QSYS.LIB/$1.LIB" ] && return 0
  [ "$2" != "*SYSBAS" ] && [ -d "/$2/QSYS.LIB/$1.LIB" ] && return 0
  return 1
}
port_busy() {
  sql_hit "SELECT 'J_'||'HIT' FROM QSYS2.NETSTAT_INFO WHERE LOCAL_PORT = $1 AND TCP_STATE = 'LISTEN' FETCH FIRST 1 ROW ONLY" && return 0
  netstat -an 2>/dev/null | grep -Eq "[.:]$1[[:space:]].*LISTEN" && return 0
  return 1
}
next_port() { # next_port <start> <avoid>
  p=$1; n=0
  while [ $n -lt 200 ]; do
    if [ "$p" != "$2" ] && ! port_busy "$p"; then echo "$p"; return 0; fi
    p=$((p + 1)); n=$((n + 1))
  done
  echo "$1"
}
next_lib() { # first free <first 8 chars of lib>01..99
  base=$(echo "$S_LIB" | cut -c1-8); i=1
  while [ $i -le 99 ]; do
    c=$(printf '%s%02d' "$base" $i)
    lib_exists "$c" "$S_IASP" || { echo "$c"; return 0; }
    i=$((i + 1))
  done
  echo ""
}

ask() { # ask <VAR> <prompt>  - current value is the default (Enter keeps it)
  eval "cur=\${$1}"
  if [ "$INTERACTIVE" -eq 1 ]; then
    printf '%s [%s]: ' "$2" "$cur"
    read -r ans || die 1 "No input received - rerun with --yes to use the given options/defaults"
    [ -n "$ans" ] && eval "$1=\$ans"
  fi
  return 0
}
retry() { # interactive: show problem and ask again; batch: stop
  [ "$INTERACTIVE" -eq 1 ] || die 7 "$ERR"
  echo "   !! $ERR"
}

chk_dir() {
  [ -n "$S_DIR" ] || { ERR="Installation directory is required (e.g. /home/myserver)"; return 1; }
  case "$S_DIR" in /*) ;; *) ERR="Installation directory must be an absolute IFS path"; return 1 ;; esac
  [ -e "$S_DIR" ] && [ ! -d "$S_DIR" ] && { ERR="$S_DIR exists and is a file"; return 1; }
  if [ -d "$S_DIR" ] && [ -n "$(ls -A "$S_DIR" 2>/dev/null)" ]; then
    ERR="$S_DIR already exists and is not empty - another server is probably installed there. Choose a new directory."
    return 1
  fi
  return 0
}
chk_lib() {
  S_LIB=$(up "$S_LIB")
  [ -n "$S_LIB" ] || { ERR="Library name is required"; return 1; }
  name_ok "$S_LIB" || { ERR="'$S_LIB' is not a valid library name (max 10 chars, starts with a letter)"; return 1; }
  if lib_exists "$S_LIB" "*SYSBAS"; then
    ERR="Library $S_LIB already exists - it belongs to another server and cannot be shared. Choose another name."
    sug=$(next_lib); [ -n "$sug" ] && { ERR="$ERR Suggested: $sug"; S_LIB="$sug"; }
    return 1
  fi
  return 0
}
chk_iasp() {
  S_IASP=$(up "$S_IASP")
  [ "$S_IASP" = "*SYSBAS" ] && return 0
  name_ok "$S_IASP" || { ERR="'$S_IASP' is not a valid iASP name"; return 1; }
  [ -d "/$S_IASP" ] || { ERR="iASP $S_IASP not found or not varied on"; return 1; }
  return 0
}
chk_inst() {
  S_INST=$(up "$S_INST")
  [ -n "$S_INST" ] || { ERR="Instance name is required"; return 1; }
  name_ok "$S_INST" || { ERR="'$S_INST' is not a valid instance name (max 10 chars)"; return 1; }
  if sql_hit "SELECT 'J_'||'HIT' FROM TABLE(QSYS2.ACTIVE_JOB_INFO(JOB_NAME_FILTER => '$S_INST')) X FETCH FIRST 1 ROW ONLY"; then
    ERR="A job named $S_INST is already active - instance name is in use. Choose another instance name."
    return 1
  fi
  return 0
}
chk_http() {
  is_num "$S_HTTP" || { ERR="HTTP port must be a number 1-65535"; return 1; }
  if port_busy "$S_HTTP"; then
    ERR="Port $S_HTTP is already used by another application."
    S_HTTP=$(next_port "$S_HTTP" "$S_HTTPS"); ERR="$ERR Next free port: $S_HTTP"; return 1
  fi
  return 0
}
chk_https() {
  is_num "$S_HTTPS" || { ERR="HTTPS port must be a number 1-65535"; return 1; }
  if [ "$S_HTTPS" = "$S_HTTP" ] || port_busy "$S_HTTPS"; then
    ERR="Port $S_HTTPS is already used."
    S_HTTPS=$(next_port "$S_HTTPS" "$S_HTTP"); ERR="$ERR Next free port: $S_HTTPS"; return 1
  fi
  return 0
}
chk_user() {
  S_JOBUSR=$(up "$S_JOBUSR")
  name_ok "$S_JOBUSR" || { ERR="'$S_JOBUSR' is not a valid user profile name"; return 1; }
  [ -e "/QSYS.LIB/$S_JOBUSR.USRPRF" ] || { ERR="User profile $S_JOBUSR does not exist"; return 1; }
  return 0
}
chk_jobqlib() {
  S_JOBQLIB=$(up "$S_JOBQLIB")
  [ "$S_JOBQLIB" = "*LIBL" ] && return 0
  name_ok "$S_JOBQLIB" || { ERR="'$S_JOBQLIB' is not a valid library name"; return 1; }
  lib_exists "$S_JOBQLIB" "*SYSBAS" || { ERR="Job queue library $S_JOBQLIB does not exist"; return 1; }
  return 0
}
chk_jobq() {
  S_JOBQ=$(up "$S_JOBQ")
  name_ok "$S_JOBQ" || { ERR="'$S_JOBQ' is not a valid job queue name"; return 1; }
  if [ "$S_JOBQLIB" = "*LIBL" ]; then
    /QOpenSys/usr/bin/system -q "CHKOBJ OBJ(*LIBL/$S_JOBQ) OBJTYPE(*JOBQ)" >/dev/null 2>&1 \
      || { ERR="Job queue $S_JOBQ not found in *LIBL"; return 1; }
  else
    [ -e "/QSYS.LIB/$S_JOBQLIB.LIB/$S_JOBQ.JOBQ" ] || { ERR="Job queue $S_JOBQLIB/$S_JOBQ does not exist"; return 1; }
  fi
  return 0
}

find_java() {
  JAVA=$(command -v java 2>/dev/null)
  if [ -z "$JAVA" ]; then
    for j in /QOpenSys/QIBM/ProdData/JavaVM/jdk*/64bit/bin/java; do [ -x "$j" ] && JAVA="$j"; done
  fi
}

server_url() { echo "http://${S_HOST:-$(hostname)}:$S_HTTP/about"; }

do_server_check() {
  [ -n "$S_HTTP" ] || S_HTTP=5257
  URL=$(server_url)
  if port_busy "$S_HTTP"; then log "Port $S_HTTP is LISTENING"; else log "Port $S_HTTP is not listening yet"; return 1; fi
  CURL=$(command -v curl 2>/dev/null); [ -z "$CURL" ] && [ -x /QOpenSys/pkgs/bin/curl ] && CURL=/QOpenSys/pkgs/bin/curl
  if [ -n "$CURL" ]; then
    t=0
    while :; do
      code=$("$CURL" -s -o /dev/null -w '%{http_code}' "http://localhost:$S_HTTP/about")
      [ "$code" = "200" ] || [ $t -ge 6 ] && break
      sleep 5; t=$((t + 1))
    done
    log "GET /about -> HTTP $code"
    [ "$code" = "200" ] || return 1
  fi
  log "Server is up. Check in your browser: $URL"
  return 0
}

do_server_start() {
  S_LIB=$(up "$S_LIB"); S_INST=$(up "$S_INST"); S_IASP=$(up "$S_IASP")
  log "Step 9 - Starting server instance $S_INST (library $S_LIB)"
  [ "$S_IASP" != "*SYSBAS" ] && { cl "SETASPGRP ASPGRP($S_IASP)" || die 9 "SETASPGRP $S_IASP failed (see $LOG)"; }
  cl "ADDLIBLE LIB($S_LIB)" || log "  ($S_LIB already in library list)"
  [ -n "$S_STARTCMD" ] || die 1 "Give the start command with --start-cmd \"<CL command using &INSTANCE>\""
  SC=$(echo "$S_STARTCMD" | sed "s/&INSTANCE/$S_INST/g")
  cl "$SC" || die 9 "$SC failed (see $LOG)"
  [ $DRYRUN -eq 1 ] && return 0
  log "Waiting for port $S_HTTP (max ${S_WAIT}s) ..."
  w=0
  while [ $w -lt "$S_WAIT" ]; do
    port_busy "$S_HTTP" && break
    sleep 5; w=$((w + 5))
  done
  do_server_check || die 9 "Server did not answer on port $S_HTTP - check job log of $S_INST"
}

do_server_setup() {
  [ -n "$JAR" ] || { usage; exit 1; }
  [ -f "$JAR" ] || die 2 "Setup JAR not found on IFS: $JAR"
  verify_jar "$JAR" || die 5 "$JAR is not a valid JAR file"
  [ -n "$S_JOBUSR" ] || S_JOBUSR=$(up "$(id -un 2>/dev/null)")
  INTERACTIVE=1; [ "$S_YES" -eq 1 ] && INTERACTIVE=0

  log "JarPilot v$VERSION - server setup from $JAR"
  echo "Steps 1-2 done: setup JAR is on the IFS. Answer the questions (Enter = value in [ ])."

  while :; do ask S_DIR   "Step 3  Installation directory";                 chk_dir   && break; retry; done
  while :; do
    while :; do ask S_LIB  "Step 4  Server installation library";     chk_lib   && break; retry; done
    while :; do ask S_IASP "Step 4  iASP for the library";      chk_iasp  && break; retry; done
    lib_exists "$S_LIB" "$S_IASP" || break
    ERR="Library $S_LIB already exists in iASP $S_IASP - choose another name."; retry
  done
  while :; do ask S_INST   "Step 5  Instance name";                         chk_inst  && break; retry; done
  while :; do ask S_HTTP   "Step 6  HTTP port";                             chk_http  && break; retry; done
  while :; do ask S_HTTPS  "Step 6  HTTPS port";                            chk_https && break; retry; done
  while :; do ask S_JOBUSR "Step 7  Job user that runs the server";         chk_user  && break; retry; done
  while :; do ask S_JOBQLIB "Step 8  Job queue library (*LIBL allowed)";    chk_jobqlib && break; retry; done
  while :; do ask S_JOBQ   "Step 8  Job queue";                             chk_jobq  && break; retry; done
  if [ "$S_START" -eq 1 ]; then
    while :; do ask S_STARTCMD "Step 9  CL command that starts the server (&INSTANCE = instance name)"
      [ -n "$S_STARTCMD" ] && break; ERR="Start command is required (or use --no-start)"; retry; done
  fi

  cat <<SUMMARY

  ===== Server installation summary (all checks passed) =====
   Setup JAR        : $JAR
   Install directory: $S_DIR
   Library / iASP   : $S_LIB / $S_IASP
   Instance         : $S_INST
   HTTP / HTTPS     : $S_HTTP / $S_HTTPS
   Job user         : $S_JOBUSR
   Job queue        : $S_JOBQLIB/$S_JOBQ
   Start command    : ${S_STARTCMD:-(not started)}
  ===========================================================
SUMMARY
  for v in S_DIR S_LIB S_IASP S_INST S_HTTP S_HTTPS S_JOBUSR S_JOBQLIB S_JOBQ S_STARTCMD; do eval "log \"  $v=\${$v}\""; done

  if [ "$INTERACTIVE" -eq 1 ]; then
    [ -n "$S_MODE" ] || { printf 'Answer the installer for you automatically? (A=auto / M=I will type the answers) [A]: '; read -r m || m=""; case "$m" in m|M) S_MODE=manual ;; *) S_MODE=auto ;; esac; }
    printf 'Proceed with installation? (y/N): '; read -r ok || ok=""
    case "$ok" in y|Y|yes|YES) ;; *) die 1 "Cancelled by user - nothing installed" ;; esac
  fi
  [ -n "$S_MODE" ] || S_MODE=auto

  find_java
  JDIR=$(cd "$(dirname "$JAR")" && pwd); JFILE=$(basename "$JAR")
  if [ $DRYRUN -eq 1 ]; then
    log "DRY-RUN: cd $JDIR && java -jar $JFILE  (mode $S_MODE)"
    [ "$S_START" -eq 1 ] && do_server_start; return 0
  fi

  RC_FILE="$LOGDIR/setup-rc-$TS"
  if [ "$S_MODE" = "manual" ]; then
    echo "Type these values when the installer asks: $S_DIR | $S_LIB | $S_IASP | $S_INST | $S_HTTP | $S_HTTPS | $S_JOBUSR | $S_JOBQLIB | $S_JOBQ"
    if [ -n "$JAVA" ]; then (cd "$JDIR" && "$JAVA" -jar "$JFILE"); else /QOpenSys/usr/bin/qsh -c "cd '$JDIR' && java -jar '$JFILE'"; fi
    echo $? > "$RC_FILE"
  else
    log "Running installer with the validated answers ..."
    { printf '%s\n' "$S_DIR" "$S_LIB" "$S_IASP" "$S_INST" "$S_HTTP" "$S_HTTPS" "$S_JOBUSR" "$S_JOBQLIB" "$S_JOBQ" \
        | if [ -n "$JAVA" ]; then (cd "$JDIR" && "$JAVA" -jar "$JFILE"); else /QOpenSys/usr/bin/qsh -c "cd '$JDIR' && java -jar '$JFILE'"; fi
      echo $? > "$RC_FILE"; } 2>&1 | tee -a "$LOG"
  fi
  rc=$(cat "$RC_FILE" 2>/dev/null); rm -f "$RC_FILE"
  [ "${rc:-1}" = "0" ] || die 8 "Installer ended with rc=$rc (see $LOG). If its questions differ, rerun with --manual"
  lib_exists "$S_LIB" "$S_IASP" || die 8 "Installer finished but library $S_LIB was not created (see $LOG). Rerun with --manual"
  [ -n "$(ls -A "$S_DIR" 2>/dev/null)" ] || die 8 "Installer finished but $S_DIR is empty (see $LOG)"
  log "Server installed in $S_DIR"
  echo "$TS SERVER $S_INST $S_LIB $S_DIR $S_HTTP" >> "$LOGDIR/../history"

  [ "$S_START" -eq 1 ] && do_server_start
  log "SUCCESS - start later with: jarpilot.sh server-start --lib $S_LIB --instance $S_INST --start-cmd \"<CL>\""
}

case "$ACTION" in
  install)  do_install ;;
  server-setup) do_server_setup ;;
  server-start) do_server_start ;;
  server-check) do_server_check ;;
  rollback) do_rollback ;;
  status)   do_status ;;
  version)  echo "JarPilot $VERSION" ;;
  *)        usage; [ "$ACTION" = "help" ] && exit 0 || exit 1 ;;
esac
