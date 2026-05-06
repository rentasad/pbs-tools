#!/bin/bash

CONFIG="/root/tapeCheck/backup-config.yml"
LOGFILE="/var/log/tape-backup.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a $LOGFILE; }

log "=== LTO6 Backup Start ==="

# Config einlesen:
eval $(python3 << PYEOF
import yaml, json

with open('$CONFIG') as f:
    c = yaml.safe_load(f)

print(f"DATASTORE='{c['datastore']}'")
print(f"POOL='{c['pool']}'")
print(f"DRIVE='{c['drive']}'")
print(f"LATEST_ONLY='{str(c.get('latest_only', True)).lower()}'")
print(f"EJECT='{str(c.get('eject_after_backup', True)).lower()}'")
print(f"NOTIFY='{c.get('notify_email', '')}'")

# Groups als --groups Parameter:
groups = c.get('groups', [])
args = ' '.join([f"--groups include:{g}" for g in groups])
print(f"GROUP_ARGS='{args}'")
PYEOF
)

# Prüfen ob Band eingelegt:
proxmox-tape status --drive $DRIVE --output-format json > /tmp/lto6-cur.json 2>/dev/null
if [ ! -s /tmp/lto6-cur.json ]; then
  log "❌ Kein Band eingelegt – Abbruch"
  [ -n "$NOTIFY" ] && echo "LTO6 Backup fehlgeschlagen: Kein Band eingelegt" \
    | mail -s "⚠️ Tape Backup Fehler" $NOTIFY
  exit 1
fi

LABEL=$(proxmox-tape read-label --drive $DRIVE --output-format json 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('label',''))" 2>/dev/null)

if [ -z "$LABEL" ]; then
  log "❌ Kein PBS-Label auf Band"
  exit 1
fi

log "Band erkannt: $LABEL"
proxmox-tape load-media "$LABEL" --drive $DRIVE

log "Starte Backup → $GROUP_ARGS"
eval proxmox-tape backup $DATASTORE $POOL \
  --drive $DRIVE \
  --latest-only $LATEST_ONLY \
  --eject-media $EJECT \
  $GROUP_ARGS

EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
  log "✅ Backup erfolgreich auf Band $LABEL"
  [ -n "$NOTIFY" ] && echo "LTO6 Backup erfolgreich auf Band $LABEL" \
    | mail -s "✅ Tape Backup OK" $NOTIFY
else
  log "❌ Backup fehlgeschlagen – Exit Code: $EXIT_CODE"
  [ -n "$NOTIFY" ] && echo "LTO6 Backup fehlgeschlagen – Exit Code: $EXIT_CODE" \
    | mail -s "⚠️ Tape Backup Fehler" $NOTIFY
fi

rm -f /tmp/lto6-cur.json
log "=== LTO6 Backup Ende ==="
