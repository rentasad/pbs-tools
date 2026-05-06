from flask import Flask, render_template, redirect, url_for, request
import sqlite3
import yaml

app = Flask(__name__)
DB = '/data/tape-library.db'
CONFIG_FILE = '/config/backup-config.yml'

def query(sql, params=()):
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    rows = con.execute(sql, params).fetchall()
    con.close()
    return rows

@app.route('/')
def index():
    tapes = query("""
        SELECT label, drive_type, pool, wearout_pct, passes_begin,
               lifetime_written_tib, status, check_date,
               unrecovered_read_errors, unrecovered_write_errors
        FROM tape_status
        GROUP BY label
        HAVING check_date = MAX(check_date)
        ORDER BY wearout_pct DESC
    """)
    counts = query("""
        SELECT COUNT(DISTINCT label) as total,
          SUM(CASE WHEN status='OK'   THEN 1 ELSE 0 END) as ok,
          SUM(CASE WHEN status='WARN' THEN 1 ELSE 0 END) as warn,
          SUM(CASE WHEN status='BAD'  THEN 1 ELSE 0 END) as bad
        FROM (
          SELECT label, status FROM tape_status
          GROUP BY label HAVING check_date = MAX(check_date)
        )
    """)
    return render_template('index.html', tapes=tapes, stats=counts[0] if counts else None)

@app.route('/tape/<label>')
def tape_detail(label):
    history = query("""
        SELECT check_date, wearout_pct, passes_begin, passes_middle,
               lifetime_written_tib, lifetime_read_tib,
               last_mount_written_gib, last_mount_read_gib,
               volume_mounts, load_count,
               recovered_read_errors, recovered_write_errors,
               unrecovered_read_errors, unrecovered_write_errors,
               write_servo_errors, status
        FROM tape_status WHERE label = ?
        ORDER BY check_date DESC
    """, (label,))
    return render_template('tape.html', label=label, history=history)

@app.route('/config')
def config_view():
    try:
        with open(CONFIG_FILE) as f:
            config = yaml.safe_load(f)
    except FileNotFoundError:
        config = {
            'datastore': 'backup-primary',
            'pool': 'LTO6-daily',
            'drive': 'LTO6',
            'latest_only': True,
            'eject_after_backup': True,
            'notify_email': '',
            'groups': []
        }
    return render_template('config.html', config=config)

@app.route('/config/save', methods=['POST'])
def config_save():
    try:
        with open(CONFIG_FILE) as f:
            config = yaml.safe_load(f)
    except FileNotFoundError:
        config = {}
    groups_raw = request.form.get('groups', '')
    config['groups']             = [g.strip() for g in groups_raw.splitlines() if g.strip()]
    config['latest_only']        = 'latest_only' in request.form
    config['eject_after_backup'] = 'eject' in request.form
    config['notify_email']       = request.form.get('notify_email', '')
    with open(CONFIG_FILE, 'w') as f:
        yaml.dump(config, f, allow_unicode=True)
    return redirect(url_for('config_view'))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)
    