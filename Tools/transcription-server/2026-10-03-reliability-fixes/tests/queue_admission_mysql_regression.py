#!/usr/bin/env python3
"""Run admission tests on a disposable MariaDB database using Webmin admin auth.

Run as the host administrator. Credentials are read internally and never printed.
No production database is selected; only this process's random test DB is dropped.
"""
from __future__ import annotations

import argparse
import sys
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

import pymysql

sys.path.insert(0, str(Path(__file__).resolve().parent))
from queue_admission_regression import AdmissionTests
from app import config
from app.db import connect, init_db


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--lifecycle', action='store_true')
    parser.add_argument('--reliability', action='store_true')
    parser.add_argument('--rates', action='store_true')
    parser.add_argument('--edge-cases', action='store_true')
    parser.add_argument('--systematic', action='store_true')
    parser.add_argument('--audio-admission', action='store_true')
    parser.add_argument('--work-status', action='store_true')
    parser.add_argument('--server-audio-source', action='store_true')
    parser.add_argument('--source-generations', action='store_true')
    parser.add_argument('--source-recovery', action='store_true')
    parser.add_argument('--test', help='Run one isolated test method')
    parser.add_argument('--admin-config', default='/etc/webmin/mysql/config')
    args = parser.parse_args()
    auth = dict(line.split('=', 1) for line in Path(args.admin_config).read_text().splitlines() if '=' in line)
    database = 'instacast_admission_test_' + uuid.uuid4().hex[:12]
    admin = pymysql.connect(unix_socket='/run/mysqld/mysqld.sock', user=auth['login'], password=auth['pass'], autocommit=True)
    created = False
    try:
        with admin.cursor() as cursor:
            cursor.execute(f'CREATE DATABASE `{database}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci')
        created = True

        base = AdmissionTests
        if args.lifecycle:
            from lifecycle_regression import LifecycleTests
            base = LifecycleTests
        if args.reliability:
            from server_reliability_regression import ReliabilityTests
            base = ReliabilityTests
        if args.rates:
            from rate_limit_regression import RateLimitTests
            base = RateLimitTests
        if args.edge_cases:
            from worker_edge_cases_regression import EdgeCasesTests
            base = EdgeCasesTests
        if args.systematic:
            from systematic_state_regression import SystematicTests
            base = SystematicTests
        if args.audio_admission:
            from audio_admission_regression import AudioAdmissionTests
            base = AudioAdmissionTests
        if args.work_status:
            from work_status_regression import WorkStatusTests
            base = WorkStatusTests
        if args.server_audio_source:
            from server_audio_source_regression import ServerAudioSourceTests
            base = ServerAudioSourceTests
        if args.source_generations:
            from source_generation_regression import SourceGenerationTests
            base = SourceGenerationTests
        if args.source_recovery:
            from source_recovery_regression import SourceRecoveryTests
            base = SourceRecoveryTests
        class MySQLAdmissionTests(base):
            def setUp(self):
                super().setUp()
                for key, value in dict(DB_BACKEND='mysql', MYSQL_DATABASE=database,
                    MYSQL_USER=auth['login'], MYSQL_PASSWORD=auth['pass'], MYSQL_HOST='localhost',
                    MYSQL_UNIX_SOCKET='/run/mysqld/mysqld.sock', MYSQL_PORT=3306).items():
                    self.contexts.enter_context(patch.object(config, key, value))
                with connect() as con:
                    # This connection can only address the freshly-created test DB.
                    self.assertEqual(database, con.execute('SELECT DATABASE() AS db').fetchone()['db'])
                    con.execute('SET FOREIGN_KEY_CHECKS=0')
                    for row in con.execute('SELECT table_name FROM information_schema.tables WHERE table_schema=DATABASE()').fetchall():
                        con.execute('DROP TABLE `' + row['table_name'].replace('`', '``') + '`')
                    con.execute('SET FOREIGN_KEY_CHECKS=1')
                init_db()

        suite = unittest.TestSuite([MySQLAdmissionTests(args.test)]) if args.test else unittest.defaultTestLoader.loadTestsFromTestCase(MySQLAdmissionTests)
        result = unittest.TextTestRunner(verbosity=1).run(suite)
        return 0 if result.wasSuccessful() else 1
    finally:
        if created:
            with admin.cursor() as cursor:
                cursor.execute(f'DROP DATABASE `{database}`')
            print('Disposable MariaDB test database removed.')
        admin.close()


if __name__ == '__main__':
    raise SystemExit(main())
