# 📼 TapeCheck – Tape Library Management for Proxmox Backup Server

A collection of shell scripts, a SQLite database and a Docker-based web dashboard for monitoring and managing LTO tape media in combination with [Proxmox Backup Server (PBS)](https://www.proxmox.com/en/proxmox-backup-server).

Built for an environment with:
- **HPE ML350 Gen10** as dedicated PBS host
- **Quantum Superloader 3** with 16 LTO8 slots (IBM Ultrium HH8 drive)
- **HP Ultrium 6** standalone drive for offsite rotation
- **Proxmox VE Cluster** (PVE1 + PVE2 + PVEQuorum) as backup source

---

## 📁 Repository Structure

```
tapeCheck/
├── README.md
├── tape-library.db              # SQLite database (auto-created, excluded from git)
├── backup-config.yml            # Backup job configuration (VMs, pool, options)
│
├── check-lto6-tapes.sh          # Interactive LTO6 tape check & labeling
├── check-lto8-tapes.sh          # Automated LTO8 tape check (Superloader)
├── label-lto8-tapes.sh          # Initial LTO8 format & label (first run)
├── lto6-daily-stats.sh          # Daily cron: reads stats from loaded LTO6 tape
├── lto6-backup-run.sh           # LTO6 tape backup job (reads backup-config.yml)
├── lto8-smart-check.sh          # Weekly cron: checks only tapes used since last run
│
└── docker/
    ├── docker-compose.yml
    ├── Dockerfile
    └── app/
        ├── app.py               # Flask web application
        └── templates/
            ├── index.html       # Dashboard overview
            ├── tape.html        # Per-tape history view
            └── config.html      # Backup configuration editor
```

---

## 🔧 Prerequisites

### On the PBS host

```bash
apt install -y multipath-tools lsscsi mtx sg3-utils sqlite3 python3 python3-yaml docker.io docker-compose-plugin
```

### Verify tape devices are recognized

```bash
lsscsi -g
# Expected:
# [x:x:x:x]  tape    HP       Ultrium 6-SCSI   ...  /dev/st0   /dev/sg0
# [x:x:x:x]  tape    IBM      ULTRIUM-HH8      ...  /dev/st1   /dev/sg7
# [x:x:x:x]  mediumx QUANTUM  UHDL             ...  /dev/sch0  /dev/sg8
```

### Configure drives in PBS

```bash
proxmox-tape drive create LTO6             --path /dev/st0
proxmox-tape drive create lto8-superloader --path /dev/st1 
  --changer quantum-sl3 --changer-drivenum 0
proxmox-tape changer create quantum-sl3    --path /dev/sg8
```

---

## 🗄️ Database Setup

```bash
sqlite3 ~/tapeCheck/tape-library.db << 'SQL'
CREATE TABLE IF NOT EXISTS tape_status (
  id                          INTEGER PRIMARY KEY AUTOINCREMENT,
  check_date                  TEXT,
  label                       TEXT,
  serial                      TEXT,
  drive_type                  TEXT,
  pool                        TEXT,
  manufactured                TEXT,
  wearout_pct                 REAL,
  passes_begin                INTEGER,
  passes_middle               INTEGER,
  lifetime_written_tib        REAL,
  lifetime_read_tib           REAL,
  last_mount_written_gib      REAL,
  last_mount_read_gib         REAL,
  volume_mounts               INTEGER,
  load_count                  INTEGER,
  recovered_read_errors       INTEGER,
  recovered_write_errors      INTEGER,
  unrecovered_read_errors     INTEGER,
  unrecovered_write_errors    INTEGER,
  write_servo_errors          INTEGER,
  compression_ratio_read      REAL,
  compression_ratio_write     REAL,
  total_native_capacity_tib   REAL,
  status                      TEXT,
  notes                       TEXT
);
CREATE INDEX IF NOT EXISTS idx_label_date ON tape_status(label, check_date);
SQL
```

---

## 📋 Script Reference

### `check-lto6-tapes.sh` – Interactive LTO6 Check & Label

Interactive script for manually checking LTO6 tapes one by one.

**Workflow:**
1. Insert tape → press Enter
2. Script reads wearout, passes, manufacture date
3. Decision:
   - ✅ `< 80%` → formats tape, prompts for name (`LTO6-` prefix pre-filled), assigns pool
   - ⚠️ `80–99%` → same as OK, but marks as WARN in summary
   - ❌ `≥ 100%` → ejects tape, adds to BAD list (set to `retired` manually in PBS)
4. Press `Ctrl+C` at any time → shows full summary (OK / WARN / BAD stacks)

```bash
./check-lto6-tapes.sh
```

**Tape naming convention:** `LTO6-Montag1`, `LTO6-Dienstag2`, `LTO6-Monat5`, etc.

---

### `check-lto8-tapes.sh` – Automated LTO8 Check

Fully automated – the Superloader loads and unloads each tape.

```bash
./check-lto8-tapes.sh
```

Slot 16 (cleaning tape `CLNU02L1`) is automatically skipped.

---

### `label-lto8-tapes.sh` – Initial LTO8 Format & Label

Run once to format all LTO8 tapes and write PBS labels matching the barcode.

```bash
# Run in a screen session – takes ~10–15 hours for 15 tapes:
screen -S tape-label
./label-lto8-tapes.sh 2>&1 | tee /root/tape-label.log
# Detach: Ctrl+A, D
# Reattach: screen -r tape-label
```

> ⚠️ Slot 16 (cleaning tape) is skipped automatically.

---

### `lto6-daily-stats.sh` – Daily LTO6 Statistics

Reads the currently loaded LTO6 tape and stores all stats to the SQLite database.
Designed to run as a daily cron job – staff insert the tape in the morning, cron reads it automatically.

```bash
./lto6-daily-stats.sh
```

**Data collected:** wearout, passes, lifetime written/read, last mount bytes, load count, recovered/unrecovered errors, compression ratio, native capacity.

---

### `lto8-smart-check.sh` – Weekly Smart Check

Checks only LTO8 tapes that have been used since the last database entry.
On first run (empty database), all tapes are checked automatically.

```bash
# Normal weekly run (only changed tapes):
./lto8-smart-check.sh

# Force all tapes (first run or manual full inventory):
FORCE_ALL=all ./lto8-smart-check.sh all
```

---

### `lto6-backup-run.sh` – LTO6 Tape Backup Job

Replaces a static PBS tape backup job. Reads `backup-config.yml`, identifies the currently loaded tape, and starts the backup with the configured VM groups and options.

```bash
./lto6-backup-run.sh
```

**Workflow:**
1. Reads `backup-config.yml` for VM groups, pool, latest-only flag
2. Checks if a tape is loaded → aborts with notification if not
3. Reads the tape label → loads it explicitly into PBS
4. Runs `proxmox-tape backup` with all configured options
5. Ejects the tape on success (if configured)

This approach avoids PBS pre-selecting a specific tape at job start – PBS uses whatever tape is currently in the drive.

> ⚠️ Disable the static PBS tape backup job schedule before using this script to avoid conflicts.

---

## ⚙️ Backup Configuration

All backup job settings are stored in `backup-config.yml`:

```yaml
datastore: backup-primary
pool: LTO6-daily
drive: LTO6
latest_only: true
eject_after_backup: true
notify_email: admin@firma.de

groups:
  - vm/500    # GSTVMDBS2
  - vm/301    # DOCKER-SV
  - vm/103    # PWS
  - vm/109    # GSTVMSAGE100APP
  - vm/114    # GSTVMSAGE100DB
  - vm/108    # SFIRM
```

The config can be edited directly or via the web dashboard at `http://<PBS-IP>:8080/config`.

---

## ⏰ Cron Jobs

```bash
crontab -e
```

```cron
# LTO6: daily at 06:00 (reads stats from currently loaded tape)
0 6 * * * /root/tapeCheck/lto6-daily-stats.sh

# LTO6: daily at 18:00 (runs tape backup job)
0 18 * * * /root/tapeCheck/lto6-backup-run.sh

# LTO8: every Sunday at 02:00 (smart check, only used tapes)
0 2 * * 0 /root/tapeCheck/lto8-smart-check.sh
```

---

## 🌐 Web Dashboard

Flask-based dashboard served via Docker. Reads the SQLite database read-only.

### Start

```bash
cd ~/tapeCheck/docker
docker compose up -d
docker logs tape-dashboard
```

Access at: `http://<PBS-IP>:8080`

### Features

- **Overview page:** all tapes with wearout bar, status badge (OK / WARN / BAD), passes, lifetime written, unrecovered errors, last check date
- **Detail page:** full history per tape with all metrics across all check dates
- **Config page** (`/config`): edit backup job settings (VM groups, pool, options) via web form – writes `backup-config.yml`, no direct PBS access
- Color coding: 🟢 `< 80%` / 🟡 `80–99%` / 🔴 `≥ 100%`

> ⚠️ No authentication – only expose on internal network (port 8080).

### docker-compose.yml

```yaml
services:
  tape-dashboard:
    build: .
    container_name: tape-dashboard
    ports:
      - "8080:8080"
    volumes:
      - /root/tapeCheck/tape-library.db:/data/tape-library.db:ro
      - /root/tapeCheck/backup-config.yml:/config/backup-config.yml:rw
    restart: unless-stopped
```

---

## 🔍 Useful Queries

```bash
# Current status of all tapes, sorted by wearout:
sqlite3 -column -header ~/tapeCheck/tape-library.db "
  SELECT label, drive_type, wearout_pct||'%' AS wearout,
         passes_begin, lifetime_written_tib||' TiB' AS written,
         status, check_date
  FROM tape_status
  GROUP BY label HAVING check_date = MAX(check_date)
  ORDER BY wearout_pct DESC;"

# Wearout history for a specific tape:
sqlite3 -column -header ~/tapeCheck/tape-library.db "
  SELECT check_date, wearout_pct||'%', passes_begin,
         recovered_read_errors, unrecovered_read_errors
  FROM tape_status WHERE label = 'LTO6-Montag1'
  ORDER BY check_date;"

# All tapes with unrecovered errors:
sqlite3 -column -header ~/tapeCheck/tape-library.db "
  SELECT label, unrecovered_read_errors, unrecovered_write_errors, check_date
  FROM tape_status
  WHERE unrecovered_read_errors > 0 OR unrecovered_write_errors > 0
  GROUP BY label HAVING check_date = MAX(check_date);"
```

---

## 📊 Wearout Reference

| Wearout | Status | Action |
|---------|--------|--------|
| < 80% | ✅ OK | Continue using |
| 80–99% | ⚠️ WARN | Order replacements |
| ≥ 100% | ❌ BAD | Set to `retired` in PBS, remove from rotation |

Set a tape as retired in PBS:
```bash
proxmox-tape media update --label-text "LABEL" --retired true
```

---

## 🗺️ Infrastructure Context

```
PVE Cluster
├── PVE1  (HP DL380 G10, Xeon Gold 5217, 346GB RAM)
│   └── Storage: 3.3TB HDD OS, 2.9TB SSD RAID5, 1.7TB SSD RAID10
├── PVE2  (HP DL380 G9,  Xeon E5-2620 v4, 346GB RAM)
│   └── Storage: 372GB SSD OS, 2.7TB HDD backup
├── PVEQuorum (Mini-PC, single NIC, VLAN210 for cluster)
└── Shared: HPE MSA 2050 SAS → 9.1TB LUN (multipath)

PBS1 (HP ML350 Gen10, 192.168.150.2)
├── OS:      2x 800GB SSD RAID1
├── D2D:     14x 1.92TB SSD RAID5 (~22TB) → PBS Datastore
├── LTO8:    IBM Ultrium HH8 in Quantum Superloader 3 (16 slots)
├── LTO6:    HP Ultrium 6 standalone (offsite rotation, daily staff swap)
└── NFS:     2x QNAP NAS 15TB (mobile, offsite rotation – swapped every few weeks)
```

---

## 📝 Notes

- LTO6 MAM Attribute warnings (800/801/802) during labeling are **harmless** – LTO6 does not support writing these attributes
- The Quantum Superloader 3 cleaning tape (`CLNU02L1`, slot 16) is automatically excluded from all scripts
- PBS stores label/pool/catalog data; wearout data is **only available by physically loading the tape**
- The `lto8-smart-check.sh` compares `media-set-ctime` from PBS media list against the last DB entry to minimize mechanical wear
- `backup-config.yml` should be committed to git – `tape-library.db` should not (add to `.gitignore`)
- PBS tape allocation policy `Always` is recommended for manual single-drive LTO6 rotation; the `lto6-backup-run.sh` script avoids the issue of PBS pre-selecting a specific tape at job start
- The QNAP NAS offsite rotation works best with NFS (`soft` mount + `x-systemd.automount`) so PBS does not hang when the NAS is physically absent

---

## 🤝 Contributing

Pull requests welcome. Please test scripts against a non-production tape before deploying.

---

## 📄 License

MIT

---

## 🚫 .gitignore

```
tape-library.db
*.log
__pycache__/
*.pyc
```