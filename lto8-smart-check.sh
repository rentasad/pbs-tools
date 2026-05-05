#!/bin/bash

DRIVE="lto8-superloader"
CHANGER="/dev/sg8"
DB="/root/tape-library.db"
LOGFILE="/var/log/tape-stats.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a $LOGFILE; }

log "=== LTO8 Smart-Check Start ==="

# PBS Media-List holen – enthält last-use Timestamp:
MEDIALIST=$(proxmox-tape media list --output-format json 2>/dev/null)

# Für jedes Band prüfen ob es seit letztem Check verwendet wurde:
BARCODES_TO_CHECK=$(python3 << PYEOF
import json, sqlite3, datetime

media = json.loads('''$MEDIALIST''')
db = sqlite3.connect('$DB')

to_check = []
for m in media:
    label    = m.get('label','')
    last_use = m.get('last-write', m.get('ctime', None))
    if not label or not last_use:
        continue

    # Letzten DB-Eintrag für dieses Band holen:
    row = db.execute(
        "SELECT check_date FROM tape_status WHERE label=? ORDER BY check_date DESC LIMIT 1",
        (label,)
    ).fetchone()

    if row is None:
        # Noch nie gecheckt:
        to_check.append(label)
    else:
        last_check = datetime.datetime.strptime(row[0], '%Y-%m-%d').timestamp()
        if last_use > last_check:
            to_check.append(label)

print('\n'.join(to_check))
db.close()
PYEOF
)

if [ -z "$BARCODES_TO_CHECK" ]; then
  log "Keine Bänder seit letztem Check verwendet – fertig!"
  exit 0
fi

log "Zu prüfende Bänder: $(echo $BARCODES_TO_CHECK | tr '\n' ' ')"

# Für jedes zu prüfende Band:
while IFS= read -r BARCODE; do
  [ -z "$BARCODE" ] && continue

  # Slot des Bandes im Changer finden:
  SLOT=$(mtx -f $CHANGER status | grep "$BARCODE" | grep -oP 'Storage Element \K\d+')
  if [ -z "$SLOT" ]; then
    log "Band $BARCODE nicht im Changer – überspringe"
    continue
  fi

  log "Lade Band $BARCODE aus Slot $SLOT..."
  mtx -f $CHANGER load $SLOT

  # Warte bis Laufwerk bereit:
  for i in {1..20}; do
    STATUS=$(proxmox-tape status --drive $DRIVE --output-format json 2>/dev/null)
    if [ -n "$STATUS" ] && echo "$STATUS" | python3 -c "
import sys,json; d=json.load(sys.stdin); exit(0 if 'medium-wearout' in d else 1)
" 2>/dev/null; then break; fi
    sleep 5
  done

  VOLSTATS=$(proxmox-tape volume-statistics --drive $DRIVE --output-format json 2>/dev/null)
  CARTMEM=$(proxmox-tape cartridge-memory --drive $DRIVE --output-format json 2>/dev/null)

  eval $(python3 << PYEOF
import json
s  = json.loads('''$STATUS''')
v  = json.loads('''$VOLSTATS''')
c  = json.loads('''$CARTMEM''')
def tib(b): return round(b / 1024**4, 3) if b else 0
def gib(b): return round(b / 1024**3, 3) if b else 0
w = float(s.get('medium-wearout', s.get('wearout', 0)))
print(f"WEAROUT={round(w*100,2)}")
print(f"SERIAL='{v.get('serial','')}'")
print(f"PASSES_BEGIN={v.get('beginning-of-medium-passes',0)}")
print(f"PASSES_MIDDLE={v.get('middle-of-tape-passes',0)}")
print(f"LIFETIME_WRITTEN={tib(v.get('lifetime-bytes-written',0))}")
print(f"LIFETIME_READ={tib(v.get('lifetime-bytes-read',0))}")
print(f"LAST_WRITTEN={gib(v.get('last-mount-bytes-written',0))}")
print(f"LAST_READ={gib(v.get('last-mount-bytes-read',0))}")
print(f"VOL_MOUNTS={v.get('volume-mounts',0)}")
print(f"LOAD_COUNT={c.get('load-count',0)}")
print(f"REC_READ_ERR={v.get('volume-recovered-read-errors',0)}")
print(f"REC_WRITE_ERR={v.get('volume-recovered-write-data-errors',0)}")
print(f"UNREC_READ_ERR={v.get('volume-unrecovered-read-errors',0)}")
print(f"UNREC_WRITE_ERR={v.get('volume-unrecovered-write-data-errors',0)}")
print(f"SERVO_ERR={v.get('volume-write-servo-errors',0)}")
print(f"COMP_READ={v.get('last-load-read-compression-ratio',0)}")
print(f"COMP_WRITE={v.get('last-load-write-compression-ratio',0)}")
print(f"NATIVE_CAP={tib(v.get('total-native-capacity',0))}")
PYEOF
)

  if   [ $(echo "$WEAROUT >= 100" | bc) -eq 1 ]; then TAPE_STATUS="BAD"
  elif [ $(echo "$WEAROUT >= 80"  | bc) -eq 1 ]; then TAPE_STATUS="WARN"
  else TAPE_STATUS="OK"
  fi

  log "Band $BARCODE | Wearout: $WEAROUT% | Status: $TAPE_STATUS"

  sqlite3 $DB << SQLEOF
INSERT INTO tape_status (
  check_date, label, serial, drive_type, pool, manufactured,
  wearout_pct, passes_begin, passes_middle,
  lifetime_written_tib, lifetime_read_tib,
  last_mount_written_gib, last_mount_read_gib,
  volume_mounts, load_count,
  recovered_read_errors, recovered_write_errors,
  unrecovered_read_errors, unrecovered_write_errors,
  write_servo_errors, compression_ratio_read, compression_ratio_write,
  total_native_capacity_tib, status
) VALUES (
  '$(date +%Y-%m-%d)', '$BARCODE', '$SERIAL', 'LTO8', 'weekly-backup', '',
  $WEAROUT, $PASSES_BEGIN, $PASSES_MIDDLE,
  $LIFETIME_WRITTEN, $LIFETIME_READ,
  $LAST_WRITTEN, $LAST_READ,
  $VOL_MOUNTS, $LOAD_COUNT,
  $REC_READ_ERR, $REC_WRITE_ERR,
  $UNREC_READ_ERR, $UNREC_WRITE_ERR,
  $SERVO_ERR, $COMP_READ, $COMP_WRITE,
  $NATIVE_CAP, '$TAPE_STATUS'
);
SQLEOF

  log "Entlade Band $BARCODE zurück in Slot $SLOT..."
  mtx -f $CHANGER unload $SLOT
  sleep 15

done <<< "$BARCODES_TO_CHECK"

log "=== LTO8 Smart-Check Ende ==="
