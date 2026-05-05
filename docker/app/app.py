from flask import Flask, render_template
import sqlite3

app = Flask(__name__)
DB = '/data/tape-library.db'

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
        SELECT
          COUNT(DISTINCT label) as total,
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
        FROM tape_status
        WHERE label = ?
        ORDER BY check_date DESC
    """, (label,))
    return render_template('tape.html', label=label, history=history)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)
