#!/bin/bash

DRIVE="lto8-superloader"
CHANGER="/dev/sg8"
DB="/root/tapeCheck/tape-library.db"
LOGFILE="/var/log/tape-stats.log"
export FORCE_ALL="${1}"  # Mit Parameter "all" aufrufen um alle Bänder zu prüfen

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a $LOGFILE; }

log "=== LTO8 Smart-Check Start ==="

# PBS Media-List in Datei:
proxmox-tape media list --output-format json > /tmp/lto8-medialist.json 2>/dev/null

BARCODES_TO_CHECK=$(python3 << 'PYEOF'
import json, sqlite3, os, sys

force_all = os.environ.get('FORCE_ALL', '') == 'all'

with open('/tmp/lto8-medialist.json') as f:
    media = json.load(f)

db = sqlite3.connect('/root/tapeCheck/tape-library.db')
to_check = []

for m in media:
    label    = m.get('label-text', '')
    last_use = m.get('media-set-ctime', m.get('ctime', None))

    if not label:
        continue

    # Reinigungsband überspringen:
    if label.endswith('L1') or 'CLN' in label.upper():
        continue

    row = db.execute(
        "SELECT check_date FROM tape_status WHERE label=? ORDER BY check_date DESC LIMIT 1",
        (label,)
    ).fetchone()

    if row is None:
        # Noch nie gecheckt → immer prüfen:
        to_check.append(label)
    elif force_all:
        # Explizit alle prüfen:
        to_check.append(label)
    elif last_use:
        import datetime
        last_check = datetime.datetime.strptime(row[0], '%Y-%m-%d').timestamp()
        if last_use > last_check:
            to_check.append(label)

db.close()
print('\n'.join(to_check))
PYEOF
)

if [ -z "$BARCODES_TO_CHECK" ]; then
  log "Keine Bänder zu prüfen – fertig!"
  exit 0
fi

COUNT=$(echo "$BARCODES_TO_CHECK" | wc -l)
log "Zu prüfende Bänder: $COUNT"

while IFS= read -r BARCODE; do
  [ -z "$BARCODE" ] && continue

  SLOT=$(mtx -f $CHANGER status | grep "$BARCODE" | grep -oP 'Storage Element \K\d+')
  if [ -z "$SLOT" ]; then
    log "Band $BARCODE nicht im Changer – überspringe"
    continue
  fi

  log "Lade Band $BARCODE aus Slot $SLOT..."
  mtx -f $CHANGER load $SLOT

  # Warte bis Laufwerk bereit:
  for i in {1..20}; do
    proxmox-tape status --drive $DRIVE --output-format json > /tmp/lto8-status.json 2>/dev/null
    if python3 -c "
import json
with open('/tmp/lto8-status.json') as f: d=json.load(f)
exit(0 if 'medium-wearout' in d else 1)
" 2>/dev/null; then break; fi
    log "  Warte... ($i/20)"
    sleep 5
  done

  proxmox-tape volume-statistics --drive $DRIVE --output-format json > /tmp/lto8-vol.json    2>/dev/null
  proxmox-tape cartridge-memory  --drive $DRIVE --output-format json > /tmp/lto8-cart.json   2>/dev/null

  eval $(python3 << 'PYEOF'
import json, datetime

with open('/tmp/lto8-status.json') as f: s = json.load(f)
with open('/tmp/lto8-vol.json')    as f: v = json.load(f)
with open('/tmp/lto8-cart.json')   as f: cart_raw = json.load(f)

if isinstance(cart_raw, list):
    c = {item['name']: item.get('value','') for item in cart_raw}
else:
    c = cart_raw

def tib(b):
    try: return round(float(b)/1024**4, 3)
    except: return 0
def gib(b):
    try: return round(float(b)/1024**3, 3)
    except: return 0
def si(x):
    try: return int(x)
    except: return 0
def sf(x):
    try: return float(x)
    except: return 0.0

w = float(s.get('medium-wearout', s.get('wearout', 0)))
mfg = s.get('manufactured', None)
if mfg:
    try: mfg = datetime.datetime.fromtimestamp(int(mfg)).strftime('%Y-%m-%d')
    except: mfg = str(mfg)

print(f"WEAROUT={round(w*100,2)}")
print(f"SERIAL='{v.get('serial', c.get('Medium Serial Number',''))}'")
print(f"MANUFACTURED='{mfg or ''}'")
print(f"POOL='{s.get('pool','weekly-backup')}'")
print(f"PASSES_BEGIN={si(v.get('beginning-of-medium-passes',0))}")
print(f"PASSES_MIDDLE={si(v.get('middle-of-tape-passes',0))}")
print(f"LIFETIME_WRITTEN={tib(v.get('lifetime-bytes-written',0))}")
print(f"LIFETIME_READ={tib(v.get('lifetime-bytes-read',0))}")
print(f"LAST_WRITTEN={gib(v.get('last-mount-bytes-written',0))}")
print(f"LAST_READ={gib(v.get('last-mount-bytes-read',0))}")
print(f"VOL_MOUNTS={si(v.get('volume-mounts',0))}")
print(f"LOAD_COUNT={si(c.get('Load Count',0))}")
print(f"REC_READ_ERR={si(v.get('volume-recovered-read-errors',0))}")
print(f"REC_WRITE_ERR={si(v.get('volume-recovered-write-data-errors',0))}")
print(f"UNREC_READ_ERR={si(v.get('volume-unrecovered-read-errors',0))}")
print(f"UNREC_WRITE_ERR={si(v.get('volume-unrecovered-write-data-errors',0))}")
print(f"SERVO_ERR={si(v.get('volume-write-servo-errors',0))}")
print(f"COMP_READ={sf(v.get('last-load-read-compression-ratio',0))}")
print(f"COMP_WRITE={sf(v.get('last-load-write-compression-ratio',0))}")
print(f"NATIVE_CAP={tib(v.get('total-native-capacity',0))}")
PYEOF
)

  WEAROUT_INT=${WEAROUT%.*}
  if   [ "$WEAROUT_INT" -ge 100 ]; then TAPE_STATUS="BAD"
  elif [ "$WEAROUT_INT" -ge 80  ]; then TAPE_STATUS="WARN"
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
  '$(date +%Y-%m-%d)', '$BARCODE', '$SERIAL', 'LTO8', '$POOL', '$MANUFACTURED',
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

rm -f /tmp/lto8-*.json
log "=== LTO8 Smart-Check Ende ==="
