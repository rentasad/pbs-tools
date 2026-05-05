#!/bin/bash

DRIVE="LTO6"
DB="/root/tape-library.db"
LOGFILE="/var/log/tape-stats.log"
TMP="/tmp/tape-stats"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a $LOGFILE; }

log "=== LTO6 Tages-Statistik Start ==="

proxmox-tape status           --drive $DRIVE --output-format json > $TMP-status.json 2>/dev/null
proxmox-tape volume-statistics --drive $DRIVE --output-format json > $TMP-vol.json    2>/dev/null
proxmox-tape cartridge-memory  --drive $DRIVE --output-format json > $TMP-cart.json   2>/dev/null

if [ ! -s $TMP-status.json ]; then
  log "Kein Band eingelegt – Abbruch"
  exit 1
fi

# Debug: zeige was die JSONs enthalten
# cat $TMP-cart.json

eval $(python3 << 'PYEOF'
import json, datetime

with open('/tmp/tape-stats-status.json') as f: s = json.load(f)
with open('/tmp/tape-stats-vol.json')    as f: v = json.load(f)
with open('/tmp/tape-stats-cart.json')   as f: cart_raw = json.load(f)

# cartridge-memory ist eine Liste von {name: ..., value: ...}
# → in Dict umwandeln:
if isinstance(cart_raw, list):
    c = {item['name']: item.get('value', '') for item in cart_raw}
else:
    c = cart_raw

def tib(b):
    try: return round(float(b) / 1024**4, 3)
    except: return 0
def gib(b):
    try: return round(float(b) / 1024**3, 3)
    except: return 0
def safe_int(x):
    try: return int(x)
    except: return 0
def safe_float(x):
    try: return float(x)
    except: return 0.0

w = float(s.get('medium-wearout', s.get('wearout', 0)))

mfg = s.get('manufactured', None)
if mfg:
    try: mfg = datetime.datetime.fromtimestamp(int(mfg)).strftime('%Y-%m-%d')
    except: mfg = str(mfg)

# Label aus status oder cartridge memory:
label = s.get('label','')
if not label:
    label = c.get('User Medium Text Label', 'unbekannt')

serial = v.get('serial', c.get('Medium Serial Number', ''))
pool   = s.get('pool', c.get('Media Pool', ''))

# Load Count aus Cartridge Memory:
load_count = safe_int(c.get('Load Count', 0))

# Capacity in MiB → TiB:
written_mib = safe_float(c.get('Total MBytes Written in Medium Life', 0))
read_mib    = safe_float(c.get('Total MBytes Read In Medium Life', 0))

print(f"LABEL='{label}'")
print(f"SERIAL='{serial}'")
print(f"POOL='{pool}'")
print(f"MANUFACTURED='{mfg or ''}'")
print(f"WEAROUT={round(w*100, 2)}")
print(f"PASSES_BEGIN={safe_int(v.get('beginning-of-medium-passes', 0))}")
print(f"PASSES_MIDDLE={safe_int(v.get('middle-of-tape-passes', 0))}")
print(f"LIFETIME_WRITTEN={tib(v.get('lifetime-bytes-written', 0))}")
print(f"LIFETIME_READ={tib(v.get('lifetime-bytes-read', 0))}")
print(f"LAST_WRITTEN={gib(v.get('last-mount-bytes-written', 0))}")
print(f"LAST_READ={gib(v.get('last-mount-bytes-read', 0))}")
print(f"VOL_MOUNTS={safe_int(v.get('volume-mounts', 0))}")
print(f"LOAD_COUNT={load_count}")
print(f"REC_READ_ERR={safe_int(v.get('volume-recovered-read-errors', 0))}")
print(f"REC_WRITE_ERR={safe_int(v.get('volume-recovered-write-data-errors', 0))}")
print(f"UNREC_READ_ERR={safe_int(v.get('volume-unrecovered-read-errors', 0))}")
print(f"UNREC_WRITE_ERR={safe_int(v.get('volume-unrecovered-write-data-errors', 0))}")
print(f"SERVO_ERR={safe_int(v.get('volume-write-servo-errors', 0))}")
print(f"COMP_READ={safe_float(v.get('last-load-read-compression-ratio', 0))}")
print(f"COMP_WRITE={safe_float(v.get('last-load-write-compression-ratio', 0))}")
print(f"NATIVE_CAP={tib(v.get('total-native-capacity', 0))}")
PYEOF
)

WEAROUT_INT=${WEAROUT%.*}
if   [ "$WEAROUT_INT" -ge 100 ]; then TAPE_STATUS="BAD"
elif [ "$WEAROUT_INT" -ge 80  ]; then TAPE_STATUS="WARN"
else TAPE_STATUS="OK"
fi

log "Band: $LABEL | Wearout: $WEAROUT% | Passes: $PASSES_BEGIN | Status: $TAPE_STATUS"

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
  '$(date +%Y-%m-%d)', '$LABEL', '$SERIAL', 'LTO6', '$POOL', '$MANUFACTURED',
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

rm -f $TMP-*.json
log "Gespeichert – Status: $TAPE_STATUS"
log "=== LTO6 Tages-Statistik Ende ==="
