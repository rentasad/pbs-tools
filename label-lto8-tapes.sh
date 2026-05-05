#!/bin/bash

DRIVE="lto8-superloader"
CHANGER="/dev/sg8"

# Barcode = Label (aus mtx status von vorhin)
declare -A TAPE_SLOTS=(
  [1]="AQE230L8"
  [2]="AQE191L8"
  [3]="" # AQE193L8 schon gelabelt
  [4]="AQE194L8"
  [5]="AQE195L8"
  [6]="AQE196L8"
  [7]="AQE187L8"
  [8]="AQE181L8"
  [9]="AQE199L8"
  [10]="AQE186L8"
  [11]="AQE188L8"
  [12]="AQE184L8"
  [13]="AQE190L8"
  [14]="AQE182L8"
  [15]=""           # Slot 15 war leer laut mtx status
  # Slot 16 = Reinigungsband CLNU02L1 → wird übersprungen!
)

for SLOT in "${!TAPE_SLOTS[@]}"; do
  LABEL=${TAPE_SLOTS[$SLOT]}

  # Leere Slots überspringen
  if [ -z "$LABEL" ]; then
    echo "Slot $SLOT ist leer – überspringe"
    continue
  fi

  echo "=========================================="
  echo "Slot $SLOT → Label: $LABEL"
  echo "Lade Band aus Slot $SLOT..."

  mtx -f $CHANGER load $SLOT
  sleep 30

  echo "Formatiere Band..."
  proxmox-tape format --drive $DRIVE

  echo "Schreibe Label $LABEL..."
  proxmox-tape label --label-text "$LABEL" --drive $DRIVE

  echo "Entlade Band zurück in Slot $SLOT..."
  mtx -f $CHANGER unload $SLOT
  sleep 15

  echo "Slot $SLOT fertig!"
done

echo "=========================================="
echo "Alle Bänder fertig formatiert und gelabelt!"
