#!/QOpenSys/usr/bin/sh
# =============================================================================
#  JarPilot for IBM i  (jarpilot)  v1.0.0
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
#  Exit codes: 0 OK, 1 usage, 2 validation, 3 copy, 4 authority, 5 verify, 6 rollback
# =============================================================================

VERSION="1.0.0"
ACTION="$1"; [ $# -gt 0 ] && shift

JAR=""; TARGET=""; NAME=""; OWNER=""; PUBAUT="*RX"; KEEP=5
SHA=""; RESTART=""; DRYRUN=0

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
    -h|--help)    ACTION="help"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

TS=$(date +%Y%m%d-%H%M%S)
LOGDIR="${TARGET:-/tmp}/.jarpilot/logs"
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

usage() { sed -n '2,20p' "$0"; }

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

case "$ACTION" in
  install)  do_install ;;
  rollback) do_rollback ;;
  status)   do_status ;;
  version)  echo "JarPilot $VERSION" ;;
  *)        usage; [ "$ACTION" = "help" ] && exit 0 || exit 1 ;;
esac
