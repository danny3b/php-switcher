"""Database replacement tests use private files and simulated MySQL clients."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import threading
import time
import unittest

SPEC = importlib.util.spec_from_file_location("import_database", Path(__file__).parents[1] / "Resources/import_database.py")
database = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(database)


class DumpTests(unittest.TestCase):
    def prepare(self, sql):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.sql"
            destination = Path(temporary) / "import.sql"
            source.write_bytes(sql if isinstance(sql, bytes) else sql.encode())
            database.prepare_dump(source, destination)
            return destination.read_bytes().decode()

    def test_standard_mysqldump_preserves_data_comments_and_session_settings(self):
        sql = """-- MySQL dump
/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET NAMES utf8mb4 */;
/*!40014 SET FOREIGN_KEY_CHECKS=0 */;
DROP TABLE IF EXISTS `items`;
CREATE TABLE `items` (`id` int, `value` text, `price` decimal(10,2));
LOCK TABLES `items` WRITE;
/*!40000 ALTER TABLE `items` DISABLE KEYS */;
INSERT INTO `items` VALUES (1,'USE other; DROP DATABASE mysql; -- not SQL',12.25),(2,'quote\\\'s; text',1.0e-2);
/*!40000 ALTER TABLE `items` ENABLE KEYS */;
UNLOCK TABLES;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
"""
        self.assertEqual(self.prepare(sql), sql)

    def test_single_database_headers_are_omitted_without_rewriting_insert_values(self):
        result = self.prepare("\ufeffCREATE DATABASE /*!32312 IF NOT EXISTS*/ `production` DEFAULT CHARACTER SET utf8mb4;\nUSE `production`;\nCREATE TABLE `data` (`text` text); INSERT INTO `data` VALUES ('USE `production`;');")
        self.assertNotIn("CREATE DATABASE", result)
        self.assertEqual(result.count("USE `production`"), 1)
        self.assertIn("CREATE TABLE", result)

    def test_phpmyadmin_transactions_and_escaped_identifiers(self):
        sql = "SET SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO'; START TRANSACTION; SET time_zone = '+00:00'; CREATE TABLE `my``table` (`data` text); INSERT INTO `my``table` VALUES ('quote''quote'); ALTER TABLE `my``table` ADD PRIMARY KEY (`data`(10)); COMMIT;"
        self.assertEqual(self.prepare(sql), sql)

    def test_large_insert_is_preserved(self):
        sql = "CREATE TABLE t (v text); INSERT INTO t VALUES ('" + "a" * 1024 * 1024 + "');"
        self.assertEqual(self.prepare(sql), sql)

    def test_rejects_unsafe_or_unsupported_dumps_before_output(self):
        inputs = ["", "-- only a comment", "SET NAMES utf8mb4;", "USE first; CREATE TABLE t (n int); USE second;",
                  "CREATE TABLE t(n int); DROP DATABASE mysql;", "CREATE TABLE other.t (n int);",
                  "CREATE TABLE t(n int); INSERT INTO other.t VALUES (1);", "CREATE TABLE t(n int); /*!50000 DROP TABLE other.t */;",
                  "CREATE TABLE t(n int); source /tmp/sql;", "CREATE TABLE t(n int); \\! touch /tmp/file;",
                  "CREATE TABLE t(n int); SET GLOBAL sql_mode='';", "CREATE TABLE t(n int); SET @@GLOBAL.GTID_PURGED='x';",
                  "CREATE TABLE t(n int); SET SQL_MODE='NO_BACKSLASH_ESCAPES';", "SET sql_mode='ANSI_QUOTES'; CREATE TABLE t(n int);",
                  "CREATE TABLE t(n int); SELECT 1 INTO OUTFILE '/tmp/x';", "CREATE TABLE t(n int) ENGINE=FEDERATED;",
                  "CREATE TABLE t(n int); CREATE VIEW v AS SELECT * FROM t;", "DELIMITER ;;\nCREATE PROCEDURE p() BEGIN SELECT 1; END;;",
                  "CREATE TABLE t(n int); INSERT INTO t VALUES ('unterminated);", b"\x1f\x8bcompressed", b"\xff\xfeutf16"]
        for sql in inputs:
            with self.subTest(sql=str(sql)[:70]):
                with self.assertRaises(database.DatabaseError):
                    self.prepare(sql)

    def test_cancellation_stops_preparation(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.sql"
            source.write_text("CREATE TABLE t(n int);")
            with self.assertRaises(database.Cancelled):
                database.prepare_dump(source, Path(temporary) / "out.sql", cancelled=lambda: True)


class SimulatedJob(database.DatabaseJob):
    def __init__(self, request, state, work):
        super().__init__(request, state, work)
        self.commands = []
        self.backup_failure = False
        self.import_failure = False
        self.metadata_changes = False
        self.metadata_reads = 0

    def metadata(self, name):
        self.metadata_reads += 1
        if self.metadata_changes and self.metadata_reads > 1:
            raise database.DatabaseError("Serwer lub lista baz zmieniły się. Połącz się ponownie przed importem.")
        return ["utf8mb4", "utf8mb4_unicode_ci"]

    def run(self, executable, arguments, **kwargs):
        if Path(executable).name == "mysqldump":
            self.commands.append(("backup", arguments))
            Path(kwargs["output_path"]).write_text("original backup")
            if self.backup_failure:
                raise database.DatabaseError("backup failed")
            return
        return super().run(executable, arguments, **kwargs)

    def mysql(self, sql=None, database=None, **kwargs):
        self.commands.append(("mysql", sql, database))
        if kwargs.get("input_path"):
            self.imported = Path(kwargs["input_path"]).read_text()
            if self.import_failure:
                raise globals()["database"].DatabaseError("import failed")


class ReplacementTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.client = self.root / "mysql"
        self.client.write_text("#!/bin/sh\nexit 0\n")
        self.client.chmod(0o700)
        dump = self.root / "mysqldump"
        dump.write_text("#!/bin/sh\nexit 0\n")
        dump.chmod(0o700)
        self.sql = self.root / "input.sql"
        self.sql.write_text("CREATE TABLE t(n int); INSERT INTO t VALUES (1);")
        self.request = dict(client=str(self.client), port=8889, user="root", password='secret\\"\n[mysql]\ninit-command=DROP DATABASE other',
                            database="local`copy", sqlFile=str(self.sql), serverID="server", backup=True,
                            backupDirectory=str(self.root / "backups"), lockDirectory=str(self.root / "locks"))

    def job(self, kind=SimulatedJob):
        work = self.root / ("work-" + str(time.monotonic_ns()))
        work.mkdir(mode=0o700)
        return kind(self.request, self.root / "state.json", work)

    def test_backup_precedes_reset_and_import_uses_exact_selected_database(self):
        job = self.job()
        job.replace()
        self.assertEqual(job.commands[0][0], "backup")
        self.assertEqual(job.commands[1][1], "DROP DATABASE `local``copy`;\nCREATE DATABASE `local``copy` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")
        self.assertEqual(job.commands[2][2], "local`copy")
        self.assertEqual(job.imported, self.sql.read_text())
        self.assertEqual(job.backup.read_text(), "original backup")
        self.assertEqual(stat.S_IMODE(job.backup.stat().st_mode), 0o600)
        self.assertEqual(job.state["status"], "complete")

    def test_backup_failure_leaves_database_untouched(self):
        job = self.job()
        job.backup_failure = True
        with self.assertRaises(database.DatabaseError):
            job.replace()
        self.assertFalse(job.changed)
        self.assertFalse(any(command[0] == "mysql" for command in job.commands))
        self.assertEqual(list((self.root / "backups").iterdir()), [])

    def test_bad_dump_never_backs_up_or_drops(self):
        self.sql.write_text("USE x; CREATE TABLE t(n int); USE y;")
        job = self.job()
        with self.assertRaises(database.DatabaseError):
            job.replace()
        self.assertEqual(job.commands, [])

    def test_server_change_after_backup_prevents_drop(self):
        job = self.job()
        job.metadata_changes = True
        with self.assertRaises(database.DatabaseError):
            job.replace()
        self.assertFalse(job.changed)
        self.assertIsNotNone(job.backup)
        self.assertEqual(len(job.commands), 1)

    def test_import_failure_retains_backup_and_marks_partial_database(self):
        job = self.job()
        job.import_failure = True
        with self.assertRaises(database.DatabaseError):
            job.replace()
        self.assertTrue(job.changed)
        self.assertEqual(job.backup.read_text(), "original backup")
        self.assertNotEqual(job.state["status"], "complete")

    def test_disabled_backup_does_not_require_dump_executable(self):
        self.request["backup"] = False
        (self.root / "mysqldump").unlink()
        job = self.job()
        job.replace()
        self.assertIsNone(job.backup)
        self.assertEqual(job.commands[0][0], "mysql")

    def test_concurrent_replacement_is_rejected_before_database_changes(self):
        first, second = self.job(), self.job()
        with first.replacement_lock():
            with self.assertRaises(database.DatabaseError):
                second.replace()
            self.assertEqual(second.commands, [])
        second.replace()
        self.assertEqual(second.state["status"], "complete")

    def test_credentials_are_escaped_private_and_absent_from_arguments_and_environment(self):
        job = self.job()
        self.assertEqual(stat.S_IMODE(job.options.stat().st_mode), 0o600)
        self.assertEqual(len(job.options.read_text().splitlines()), 2)
        self.assertNotIn(self.request["password"], " ".join(job.connection))
        self.assertNotIn("MYSQL_PWD", job.environment)
        self.assertIn("--host=127.0.0.1", job.connection)
        self.assertIn("--protocol=TCP", job.connection)
        self.assertEqual(job.environment["MYSQL_TEST_LOGIN_FILE"], str(job.work / "unused-login.cnf"))

    def test_system_databases_and_invalid_ports_are_rejected(self):
        for name in ["mysql", "MYSQL", "sys", "information_schema", "performance_schema", "ndbinfo", "", "../test", "x\0y"]:
            with self.subTest(name=name), self.assertRaises(database.DatabaseError):
                database.identifier(name)
        for port in [0, 65536, "8889", True]:
            self.request["port"] = port
            with self.assertRaises(database.DatabaseError):
                self.job()

    def test_real_subprocess_failure_is_reported_and_never_continues(self):
        self.client.write_text("#!/bin/sh\necho 'access denied' >&2\nexit 1\n")
        job = self.job(database.DatabaseJob)
        with self.assertRaises(database.DatabaseError) as error:
            job.mysql("SELECT 1;", timeout=2)
        self.assertIn("access denied", error.exception.arguments[0])

    def test_cancel_terminates_running_client(self):
        self.client.write_text("#!/bin/sh\nexec /bin/sleep 20\n")
        job = self.job(database.DatabaseJob)
        timer = threading.Timer(0.2, job.cancel)
        timer.start()
        self.addCleanup(timer.cancel)
        started = time.monotonic()
        with self.assertRaises(database.Cancelled):
            job.mysql("SELECT 1;")
        self.assertLess(time.monotonic() - started, 3)
        self.assertIsNone(job.child)

    def test_metadata_requires_same_server_and_existing_database(self):
        job = self.job(database.DatabaseJob)
        job.databases = lambda: ("another-server", ["local`copy"])
        with self.assertRaises(database.DatabaseError):
            job.metadata("local`copy")
        job.databases = lambda: ("server", [])
        with self.assertRaises(database.DatabaseError):
            job.metadata("local`copy")


if __name__ == "__main__":
    unittest.main()
