#!/usr/bin/env python3
"""Opt-in MySQL integration check using an entirely disposable server instance."""
import argparse
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Resources/import_database.py"
SPEC = importlib.util.spec_from_file_location("import_database", SCRIPT)
database = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(database)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mysql-bin", type=Path, required=True)
    parser.add_argument("--run", action="store_true", required=True)
    args = parser.parse_args()
    binary = args.mysql_bin.resolve()
    with tempfile.TemporaryDirectory(prefix="devzbik-mysql-test-", dir="/tmp") as temporary:
        root = Path(temporary)
        data = root / "data"
        subprocess.run([str(binary / "mysqld"), "--no-defaults", "--initialize-insecure", "--basedir=" + str(binary.parent),
                        "--datadir=" + str(data), "--log-error=" + str(root / "init.log")], check=True)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        server = subprocess.Popen([str(binary / "mysqld"), "--no-defaults", "--basedir=" + str(binary.parent), "--datadir=" + str(data),
                                   "--bind-address=127.0.0.1", "--port=" + str(port), "--mysqlx=0", "--skip-log-bin",
                                   "--socket=" + str(root / "mysql.sock"), "--pid-file=" + str(root / "mysql.pid"),
                                   "--log-error=" + str(root / "server.log")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(200):
                if server.poll() is not None:
                    raise RuntimeError((root / "server.log").read_text())
                if (root / "mysql.sock").exists():
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("Disposable server did not start")
            work = root / "work"
            work.mkdir(mode=0o700)
            request = dict(client=str(binary / "mysql"), port=port, user="root", password="")
            client = database.DatabaseJob(request, root / "client-state.json", work)
            # Exercise actual option-file escaping without any real credentials.
            password = 'test\\with"quotes\nand-newline'
            literal = "'" + password.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n") + "'"
            client.mysql("ALTER USER 'root'@'localhost' IDENTIFIED BY " + literal + ";", timeout=20)
            request["password"] = password
            second_work = root / "authenticated"
            second_work.mkdir(mode=0o700)
            client = database.DatabaseJob(request, root / "client-state.json", second_work)
            client.mysql("CREATE DATABASE target CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE TABLE target.old_data(n INT); INSERT INTO target.old_data VALUES (77); CREATE VIEW target.old_view AS SELECT n FROM target.old_data; CREATE DATABASE untouched; CREATE TABLE untouched.sentinel(n INT); INSERT INTO untouched.sentinel VALUES (99); CREATE DATABASE remote_copy; CREATE TABLE remote_copy.items(n INT, note TEXT); INSERT INTO remote_copy.items VALUES (1,'Żbik'),(2,'USE untouched; DROP DATABASE mysql;');", timeout=20)
            sql_file = root / "remote.sql"
            client.run(binary / "mysqldump", ["--no-tablespaces", "--loose-column-statistics=0", "--set-gtid-purged=OFF", "--databases", "remote_copy"], output_path=sql_file)

            def operation(operation_request):
                state = root / "operation.json"
                state.unlink(missing_ok=True)
                result = subprocess.run(["/usr/bin/python3", str(SCRIPT), "--state", str(state)], input=json.dumps(operation_request),
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
                outcome = json.loads(state.read_text())
                assert not list(root.glob("database-*")), "Credentials and SQL snapshots must be removed"
                assert password not in state.read_text()
                return result.returncode, outcome

            status, listing = operation(dict(request, operation="list"))
            assert status == 0, listing
            assert set(listing["databases"]) == {"target", "untouched", "remote_copy"}, listing
            replacement = dict(request, operation="replace", database="target", serverID=listing["serverID"], sqlFile=str(sql_file),
                               backup=True, backupDirectory=str(root / "backups"), lockDirectory=str(root / "locks"))
            status, result = operation(replacement)
            assert status == 0 and result["status"] == "complete", result
            assert client.mysql("SELECT n, note FROM target.items ORDER BY n;", timeout=20).splitlines() == ["1\tŻbik", "2\tUSE untouched; DROP DATABASE mysql;"]
            assert client.mysql("SHOW FULL TABLES FROM target;", timeout=20).strip() == "items\tBASE TABLE"
            assert client.mysql("SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='target';", timeout=20).strip() == "utf8mb4_bin"
            assert client.mysql("SELECT n FROM untouched.sentinel;", timeout=20).strip() == "99"
            original_backup = Path(result["backupPath"])
            assert original_backup.is_file()
            print("PASS: Actual mysqldump imported into the selected database; old objects cleared, charset and other database preserved.")

            sql_file.write_text("CREATE TABLE other.bad(n INT);")
            status, result = operation(replacement)
            assert status != 0 and not result["changed"], result
            assert client.mysql("SELECT COUNT(*) FROM target.items;", timeout=20).strip() == "2"
            print("PASS: Rejected dump leaves the database untouched.")

            sql_file.write_text("CREATE TABLE broken(n INT); INSERT INTO broken VALUES (missing_column);")
            status, result = operation(replacement)
            assert status != 0 and result["changed"] and result["status"] == "failed", result
            assert Path(result["backupPath"]).is_file()
            client.mysql(input_path=original_backup, timeout=20)
            assert client.mysql("SELECT n FROM target.old_data;", timeout=20).strip() == "77"
            assert client.mysql("SELECT n FROM target.old_view;", timeout=20).strip() == "77"
            assert client.mysql("SELECT n FROM untouched.sentinel;", timeout=20).strip() == "99"
            print("PASS: Import failure retains a restorable backup, including original views.")
        finally:
            server.terminate()
            try:
                server.wait(timeout=15)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
    print("All disposable MySQL integration checks passed; temporary server removed.")


if __name__ == "__main__":
    try:
        main()
    except database.DatabaseError as error:
        raise RuntimeError((error.key, error.arguments)) from error
