import datetime as dt
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('bully_scheduler', Path(__file__).with_name('scheduler.py'))
scheduler = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scheduler)


class SchedulerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'state.sqlite3'
        self.db = scheduler.connect(self.path)
    def tearDown(self):
        self.db.close(); self.temp.cleanup()
    def test_roster_and_utc_matches(self):
        self.assertEqual({'/api/cron/suppression-sync': '*/15 * * * *', '/api/cron/bell-retention': '17 10 * * *',
                          '/api/cron/subscriber-backup': '0 11 1 * *', '/api/cron/morning-report': '*/15 11,12 * * *'}, scheduler.SCHEDULES)
        self.assertEqual(['/api/cron/bell-retention'], scheduler.due(dt.datetime(2026,11,27,10,17,tzinfo=dt.timezone.utc)))
        self.assertEqual(3, len(scheduler.due(dt.datetime(2026,12,1,11,0,tzinfo=dt.timezone.utc))))
    def test_parallel_never_claims_or_sends(self):
        scheduler.tick(self.db, dt.datetime(2026,12,1,11,0,tzinfo=dt.timezone.utc), 'parallel', '', lambda *_: self.fail('parallel send'))
        self.assertEqual(0, self.db.execute('SELECT count(*) FROM attempts').fetchone()[0])
    def test_two_dispatchers_and_restarts_cannot_duplicate_interval(self):
        now = dt.datetime(2026,12,1,11,0,tzinfo=dt.timezone.utc)
        sent=[]
        scheduler.tick(self.db, now, 'primary', 'fixture', lambda path,_: sent.append(path) or 200)
        other=scheduler.connect(self.path)
        try: scheduler.tick(other, now, 'primary', 'fixture', lambda *_: self.fail('duplicate send'))
        finally: other.close()
        self.assertEqual(3,len(sent)); self.assertTrue(scheduler.healthy(self.db, now.timestamp()))
    def test_ambiguous_failed_delivery_is_not_retried_and_is_unhealthy(self):
        now=dt.datetime(2026,11,27,13,0,tzinfo=dt.timezone.utc)
        scheduler.tick(self.db, now, 'primary', 'fixture', lambda *_: None)
        scheduler.tick(self.db, now, 'primary', 'fixture', lambda *_: self.fail('retry ambiguous send'))
        self.assertFalse(scheduler.healthy(self.db, now.timestamp()))
    def test_crash_after_claim_never_replays(self):
        now=dt.datetime(2026,11,27,13,0,tzinfo=dt.timezone.utc)
        self.assertTrue(scheduler.claim(self.db, '/api/cron/suppression-sync', int(now.timestamp())//60))
        scheduler.tick(self.db, now, 'primary', 'fixture', lambda *_: self.fail('retry interrupted attempt'))
        self.assertFalse(scheduler.healthy(self.db, now.timestamp()+601))
    def test_downtime_is_recorded_without_backfilling_email(self):
        scheduler.tick(self.db, dt.datetime(2026,12,1,10,59,tzinfo=dt.timezone.utc), 'primary','fixture')
        now=dt.datetime(2026,12,1,11,1,tzinfo=dt.timezone.utc)
        scheduler.tick(self.db, now, 'primary', 'fixture', lambda *_: self.fail('old send'))
        self.assertEqual('missed', self.db.execute("SELECT status FROM attempts WHERE path='/api/cron/subscriber-backup'").fetchone()[0])
        self.assertFalse(scheduler.healthy(self.db, now.timestamp()))


if __name__ == '__main__': unittest.main()
