#!/usr/bin/env python3
"""UTC cron dispatcher with durable, at-most-once attempts per scheduled minute."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import signal
import sqlite3
import sys
import time
import urllib.error
import urllib.request

STATE = Path('/state/scheduler.sqlite3')
SCHEDULES = {
    '/api/cron/suppression-sync': '*/15 * * * *',
    '/api/cron/bell-retention': '17 10 * * *',
    '/api/cron/subscriber-backup': '0 11 1 * *',
    '/api/cron/morning-report': '*/15 11,12 * * *',
    '/api/cron/analytics-report': '*/15 11,12 * * *',
}


def due(now):
    paths = []
    if now.minute % 15 == 0:
        paths.append('/api/cron/suppression-sync')
        if now.hour in (11, 12):
            paths.extend(('/api/cron/morning-report', '/api/cron/analytics-report'))
    if (now.hour, now.minute) == (10, 17): paths.append('/api/cron/bell-retention')
    if (now.day, now.hour, now.minute) == (1, 11, 0): paths.append('/api/cron/subscriber-backup')
    return paths


def connect(path=STATE):
    db = sqlite3.connect(path, timeout=10)
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('PRAGMA synchronous=FULL')
    db.execute('CREATE TABLE IF NOT EXISTS attempts(path TEXT, minute INTEGER, status TEXT NOT NULL, http_status INTEGER, PRIMARY KEY(path, minute))')
    db.execute('CREATE TABLE IF NOT EXISTS heartbeat(id INTEGER PRIMARY KEY CHECK(id=1), seen INTEGER NOT NULL, role TEXT NOT NULL)')
    db.commit()
    return db


def claim(db, path, minute):
    # Commit before HTTP: an uncertain result is never retried automatically.
    with db:
        result = db.execute('INSERT OR IGNORE INTO attempts(path,minute,status) VALUES(?,?,?)', (path, minute, 'running'))
    return result.rowcount == 1


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs): return None


def deliver(path, secret):
    request = urllib.request.Request('http://app:3000' + path, headers={
        'Authorization': 'Bearer ' + secret, 'Host': 'www.philipithomas.com',
        'X-Forwarded-Proto': 'https',
    })
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=120) as response:
            response.read(65537)
            return response.status
    except urllib.error.HTTPError as error:
        return error.code
    except (OSError, ValueError):
        return None


def tick(db, now, role, secret, send=deliver):
    minute = int(now.timestamp()) // 60
    previous = db.execute('SELECT seen,role FROM heartbeat WHERE id=1').fetchone()
    # Record missed work after downtime, without replaying old sends. The route
    # owns each daily report's catch-up during its current New York morning window.
    if role == 'primary' and previous and previous[1] == 'primary':
        for missed in range(max(previous[0] // 60 + 1, minute - 2 * 24 * 60), minute):
            for path in due(dt.datetime.fromtimestamp(missed * 60, dt.timezone.utc)):
                with db:
                    db.execute('INSERT OR IGNORE INTO attempts(path,minute,status) VALUES(?,?,?)', (path, missed, 'missed'))
    with db:
        db.execute('INSERT INTO heartbeat VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET seen=excluded.seen,role=excluded.role', (int(now.timestamp()), role))
    if role != 'primary': return
    if not secret: raise RuntimeError('Primary scheduler requires CRON_SECRET')
    for path in due(now):
        if not claim(db, path, minute): continue
        status = send(path, secret)
        outcome = 'success' if status is not None and 200 <= status < 300 else 'failed'
        with db:
            db.execute('UPDATE attempts SET status=?,http_status=? WHERE path=? AND minute=?', (outcome, status, path, minute))
        print(json.dumps({'job': path, 'minute': minute, 'status': outcome, 'http_status': status}), flush=True)


def healthy(db, timestamp):
    heartbeat = db.execute('SELECT seen,role FROM heartbeat WHERE id=1').fetchone()
    if not heartbeat or timestamp - heartbeat[0] > 600: return False
    if heartbeat[1] != 'primary': return True
    latest = db.execute('SELECT a.status,a.minute FROM attempts a JOIN (SELECT path,max(minute) minute FROM attempts GROUP BY path) b USING(path,minute)').fetchall()
    return all(status == 'success' or (status == 'running' and timestamp - minute * 60 < 600) for status, minute in latest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--health', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    if args.health:
        if not STATE.is_file(): return 1
        with connect() as db: return 0 if healthy(db, time.time()) else 1
    role = os.environ.get('DEPLOYMENT_ROLE', 'parallel')
    if role not in ('parallel', 'primary'): raise RuntimeError('Invalid scheduler role')
    stopping = False
    def stop(*_args):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    with connect() as db:
        while not stopping:
            tick(db, dt.datetime.now(dt.timezone.utc), role, os.environ.get('CRON_SECRET', ''))
            for _ in range(10):
                if stopping: break
                time.sleep(1)
    return 0


if __name__ == '__main__':
    try: sys.exit(main())
    except Exception:
        print('Scheduler failed; inspect its private attempt ledger', file=sys.stderr)
        sys.exit(1)
