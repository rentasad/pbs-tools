#!/bin/bash

DRIVE="LTO6"
POOL="LTO6-daily"
GOOD=()
WARN=()
BAD=()
TAPE_NUM=0
BANDNAME=""

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

format_and_label() {
  echo ""
  echo "  Wie soll das Band heißen?"
  echo "  (Prefix 'LTO6-' ist bereits gesetzt)"
  echo -n "  LTO6-"
  read -r BANDNAME_SUFFIX

  if [ -z "$BANDNAME_SUFFIX" ]; then
    echo "  Kein Name eingegeben – Band wird ohne Label ausgeworfen."
    BANDNAME=""
    return 1
  fi

  BANDNAME="LTO6-$BANDNAME_SUFFIX"
  echo ""
  echo "  Formatiere Band – bitte warten..."
  proxmox-tape format --drive $DRIVE

  echo "  Schreibe Label '$BANDNAME'..."
  proxmox-tape label --label-text "$BANDNAME" --drive $DRIVE --pool "$POOL"

  #echo "  Weise Mediapool '$POOL' zu..."
  #proxmox-tape media update --label-text "$BANDNAME" --pool "$POOL"

  echo ""
  echo "  ✅ Band '$BANDNAME' fertig – Pool: $POOL"
  return 0
}

show_summary() {
  clear
  echo ""
  echo "=================================================="
  echo "  ZUSAMMENFASSUNG LTO6"
  echo "=================================================="
  echo "  ✅ OK & gelabelt (${#GOOD[@]} Bänder):"
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
echo "  LTO6 Band-Prüfung  |  Strg+C für Zusammenfassung"
echo "=================================================="

while true; do
  TAPE_NUM=$((TAPE_NUM + 1))
  BANDNAME=""
  echo ""
  echo "  ──────────────────────────────────────────"
  echo "  Band #$TAPE_NUM einlegen und Enter drücken..."
  echo "  oder Strg+C für Zusammenfassung"
  echo "  ──────────────────────────────────────────"
  read -r

  if ! wait_for_drive; then
    echo "  ⚠️  Laufwerk antwortet nicht nach 100 Sekunden!"
    WARN+=("Band #$TAPE_NUM – Timeout beim Lesen")
    proxmox-tape eject --drive $DRIVE 2>/dev/null
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

  LABEL=$(proxmox-tape read-label --drive $DRIVE --output-format json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('label','unbekannt'))
" 2>/dev/null)

  clear
  echo "=================================================="
  echo "  Band #$TAPE_NUM  |  Label: ${LABEL:-unbekannt}"
  echo "  Hergestellt: $MFGDATE  |  Passes: $PASSES  |  Wearout: $WEAROUT_DISPLAY"
  echo "=================================================="

  if [ -z "$WEAROUT_NUM" ]; then
    echo ""
    echo "  ⚠️  Wearout nicht lesbar – Band prüfen!"
    WARN+=("Band #$TAPE_NUM ${LABEL:-unbekannt} – Wearout: unlesbar")
    proxmox-tape eject --drive $DRIVE

  elif [ "$WEAROUT_NUM" -ge 100 ]; then
    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   ❌  BAND AUSSONDERN!               ║"
    echo "  ║   Wearout: $WEAROUT_DISPLAY           ║"
    echo "  ║   Über Limit – Datenverlustrisiko!   ║"
    echo "  ╚══════════════════════════════════════╝"
    echo "  → Roten Stapel"
    BAD+=("Band #$TAPE_NUM ${LABEL:-unbekannt} – Wearout: $WEAROUT_DISPLAY  Passes: $PASSES")
    proxmox-tape eject --drive $DRIVE

  elif [ "$WEAROUT_NUM" -ge 80 ]; then
    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   ⚠️   BAND BALD ERSETZEN            ║"
    echo "  ║   Wearout: $WEAROUT_DISPLAY           ║"
    echo "  ║   Noch nutzbar – wird formatiert     ║"
    echo "  ║   und gelabelt                       ║"
    echo "  ╚══════════════════════════════════════╝"
    echo "  → Gelben Stapel (neu bestellen!)"
    if format_and_label; then
      WARN+=("Band #$TAPE_NUM $BANDNAME – Wearout: $WEAROUT_DISPLAY  Passes: $PASSES – bald ersetzen!")
    else
      WARN+=("Band #$TAPE_NUM ${LABEL:-unbekannt} – Wearout: $WEAROUT_DISPLAY – kein Label vergeben")
    fi
    proxmox-tape eject --drive $DRIVE

  else
    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   ✅  BAND OK                        ║"
    echo "  ║   Wearout: $WEAROUT_DISPLAY           ║"
    echo "  ╚══════════════════════════════════════╝"
    echo "  → Grünen Stapel"
    if format_and_label; then
      GOOD+=("Band #$TAPE_NUM $BANDNAME – Wearout: $WEAROUT_DISPLAY  Passes: $PASSES")
    else
      WARN+=("Band #$TAPE_NUM ${LABEL:-unbekannt} – Wearout: $WEAROUT_DISPLAY – kein Label vergeben")
    fi
    proxmox-tape eject --drive $DRIVE
  fi

done
