#!/bin/bash

DRIVE="lto8-superloader"
CHANGER="/dev/sg8"
POOL="weekly-backup"
SLOTS=(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)

GOOD=()
WARN=()
BAD=()

wait_for_drive() {
  echo "  Warte auf Laufwerk..."
  for i in {1..20}; do
    STATUS=$(proxmox-tape status --drive $DRIVE --output-format json 2>/dev/null)
    if [ -n "$STATUS" ] && echo "$STATUS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
exit(0 if 'medium-wearout' in d or 'wearout' in d else 1)
" 2>/dev/null; then
      return 0
    fi
    echo "  Versuch $i/20 – warte 5 Sekunden..."
    sleep 5
  done
  return 1
}

show_summary() {
  clear
  echo ""
  echo "=================================================="
  echo "  LTO8 ZUSAMMENFASSUNG"
  echo "=================================================="
  echo "  ✅ OK (${#GOOD[@]} Bänder):"
  for b in "${GOOD[@]}"; do echo "     $b"; done
  echo ""
  echo "  ⚠️  Bald ersetzen (${#WARN[@]} Bänder):"
  for b in "${WARN[@]}"; do echo "     $b"; done
  echo ""
  echo "  ❌ Aussondern (${#BAD[@]} Bänder):"
  for b in "${BAD[@]}"; do echo "     $b"; done
  echo "=================================================="
  exit 0
}

trap show_summary INT

clear
echo "=================================================="
echo "  LTO8 Band-Prüfung (vollautomatisch)"
echo "  Strg+C für vorzeitige Zusammenfassung"
echo "=================================================="
echo ""

for SLOT in "${SLOTS[@]}"; do

  SLOT_STATUS=$(mtx -f $CHANGER status | grep "Storage Element $SLOT:")
  if echo "$SLOT_STATUS" | grep -q "Empty"; then
    echo "  Slot $SLOT: leer – überspringe"
    continue
  fi

  BARCODE=$(echo "$SLOT_STATUS" | grep -oP 'VolumeTag=\K\S+')

  echo ""
  echo "  ────────────────────────────────────────────"
  echo "  Slot $SLOT  |  Barcode: $BARCODE"
  echo "  Lade Band..."

  mtx -f $CHANGER load $SLOT

  if ! wait_for_drive; then
    echo "  ⚠️  Laufwerk antwortet nicht nach 100 Sekunden!"
    WARN+=("Slot $SLOT  $BARCODE – Timeout beim Lesen")
    mtx -f $CHANGER unload $SLOT
    sleep 15
    continue
  fi

  STATUS=$(proxmox-tape status --drive $DRIVE --output-format json 2>/dev/null)

  WEAROUT_NUM=$(echo "$STATUS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
w=float(d.get('medium-wearout', d.get('wearout', 0)))
print(int(w*100))
" 2>/dev/null)

  WEAROUT_DISPLAY=$(echo "$STATUS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
w=float(d.get('medium-wearout', d.get('wearout', 0)))
print(f'{w*100:.1f}%')
" 2>/dev/null)

  PASSES=$(echo "$STATUS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('medium-passes', d.get('passes', 'N/A')))
" 2>/dev/null)

  MFGDATE=$(echo "$STATUS" | python3 -c "
import sys,json,datetime
d=json.load(sys.stdin)
ts=d.get('manufactured',None)
print(datetime.datetime.fromtimestamp(int(ts)).strftime('%Y-%m-%d') if ts else 'N/A')
" 2>/dev/null)

  echo "  Hergestellt: $MFGDATE  |  Passes: $PASSES  |  Wearout: $WEAROUT_DISPLAY"
  echo ""

  if [ -z "$WEAROUT_NUM" ]; then
    echo "  ⚠️  Wearout nicht lesbar!"
    WARN+=("Slot $SLOT  $BARCODE – Wearout: unlesbar")

  elif [ "$WEAROUT_NUM" -ge 100 ]; then
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   ❌  BAND AUSSONDERN!               ║"
    echo "  ║   Wearout: $WEAROUT_DISPLAY           ║"
    echo "  ║   Über Limit – Datenverlustrisiko!   ║"
    echo "  ╚══════════════════════════════════════╝"
    BAD+=("Slot $SLOT  $BARCODE – Wearout: $WEAROUT_DISPLAY  Passes: $PASSES")

  elif [ "$WEAROUT_NUM" -ge 80 ]; then
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   ⚠️   BAND BALD ERSETZEN            ║"
    echo "  ║   Wearout: $WEAROUT_DISPLAY           ║"
    echo "  ╚══════════════════════════════════════╝"
    echo "  Weise Mediapool '$POOL' zu..."
    proxmox-tape media update --label-text "$BARCODE" --pool "$POOL"
    WARN+=("Slot $SLOT  $BARCODE – Wearout: $WEAROUT_DISPLAY  Passes: $PASSES – bald ersetzen!")

  else
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   ✅  BAND OK                        ║"
    echo "  ║   Wearout: $WEAROUT_DISPLAY           ║"
    echo "  ╚══════════════════════════════════════╝"
    echo "  Weise Mediapool '$POOL' zu..."
    proxmox-tape media update --label-text "$BARCODE" --pool "$POOL"
    GOOD+=("Slot $SLOT  $BARCODE – Wearout: $WEAROUT_DISPLAY  Passes: $PASSES")
  fi

  echo ""
  echo "  Entlade Band zurück in Slot $SLOT..."
  mtx -f $CHANGER unload $SLOT
  sleep 15

done

show_summary
