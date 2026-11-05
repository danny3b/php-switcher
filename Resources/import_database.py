#!/usr/bin/env python3
"""Replace one local MySQL database using a validated single-database table dump.

Credentials arrive over stdin and exist on disk only in a private temporary
option file. The original SQL is snapshotted and checked before any DROP.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import mmap
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid


SYSTEM_DATABASES = {"mysql", "information_schema", "performance_schema", "sys", "ndbinfo"}


class DatabaseError(Exception):
    def __init__(self, key, *arguments):
        super().__init__(key)
        self.key = key
        self.arguments = list(map(str, arguments))


class Cancelled(Exception):
    pass


def identifier(name):
    if not isinstance(name, str) or not name or len(name) > 64 or any(c in name for c in "\0/\\\n\r"):
        raise DatabaseError("Nieprawidłowa nazwa bazy danych.")
    if name.casefold() in SYSTEM_DATABASES:
        raise DatabaseError("Nie można zastąpić systemowej bazy danych.")
    return "`" + name.replace("`", "``") + "`"


def option_value(value):
    if "\0" in value:
        raise DatabaseError("Dane połączenia zawierają niedozwolony znak.")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + '"'


# The parser deliberately accepts table/data dumps, not arbitrary SQL programs.
# Strings and comments are tokenized before inspecting database directives; text
# inside INSERT values can never be mistaken for USE, DROP, or a delimiter.
TOKEN = re.compile(rb"""
    (?P<space>\s+)
  | (?P<line>--(?=[\x00-\x20])[^\r\n]*|\#[^\r\n]*)
  | (?P<comment>/\*.*?\*/)
  | (?P<string>'(?:[^'\\]|\\.|'')*'|"(?:[^"\\]|\\.|"")*")
  | (?P<identifier>`(?:[^`]|``)*`)
  | (?P<number>0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)
  | (?P<word>[@a-zA-Z_$\x80-\xff][@a-zA-Z_0-9$\x80-\xff]*)
  | (?P<punct>.)
""", re.VERBOSE | re.DOTALL)


def tokens(data, start=0, end=None):
    for match in TOKEN.finditer(data, start, len(data) if end is None else end):
        kind = match.lastgroup
        if kind in {"space", "line"}:
            continue
        if kind == "comment":
            if data[match.start():match.start() + 3] == b"/*!":
                begin = match.start() + 3
                while begin < match.end() - 2 and 48 <= data[begin] <= 57:
                    begin += 1
                for token in tokens(data, begin, match.end() - 2):
                    if token[0] == "punct" and token[1] == b";":
                        raise DatabaseError("Nieprawidłowy plik SQL.")
                    yield token
            continue
        # Do not copy giant INSERT values into Python objects.
        value = data[match.start():min(match.end(), match.start() + 4096)]
        if kind == "identifier":
            if match.end() - match.start() > 258:
                raise DatabaseError("Nieprawidłowy plik SQL.")
            value = value[1:-1].replace(b"``", b"`")
        if kind == "word":
            value = value.upper()
        if kind == "punct" and value in {b"'", b'"', b"`", b"\\", b"\0"}:
            raise DatabaseError("Nieprawidłowy plik SQL.")
        yield kind, value, match.start(), match.end()


def prepare_dump(source, destination, cancelled=lambda: False, progress=lambda _: None):
    """Validate an immutable snapshot, then omit only database-selection headers."""
    source = Path(source)
    if source.stat().st_size == 0:
        raise DatabaseError("Plik SQL jest pusty.")
    omitted = []
    schema = None
    meaningful = 0
    settings = {b"NAMES", b"CHARACTER_SET_CLIENT", b"CHARACTER_SET_RESULTS", b"COLLATION_CONNECTION",
                b"TIME_ZONE", b"UNIQUE_CHECKS", b"FOREIGN_KEY_CHECKS", b"SQL_MODE", b"SQL_NOTES",
                b"AUTOCOMMIT", b"SQL_LOG_BIN", b"CHARACTER", b"SESSION", b"LOCAL"}
    with source.open("rb") as file, mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as data:
        if data[:2] in {b"\x1f\x8b", b"\xff\xfe", b"\xfe\xff"} or data[:4] == b"PK\x03\x04":
            raise DatabaseError("Wybierz nieskompresowany plik SQL w kodowaniu UTF-8.")
        beginning = 3 if data[:3] == b"\xef\xbb\xbf" else 0
        statement_start = beginning
        header = []
        previous = None
        count = 0

        def finish(end):
            nonlocal schema, meaningful, statement_start, header, previous
            if not header:
                statement_start = end
                return
            words = [token[1] for token in header]
            first = words[0]
            if first == b"USE" or (first in {b"CREATE", b"DROP"} and len(words) > 1 and words[1] in {b"DATABASE", b"SCHEMA"}):
                index = 1 if first == b"USE" else 2
                if words[index:index + 3] == [b"IF", b"NOT", b"EXISTS"]:
                    index += 3
                elif words[index:index + 2] == [b"IF", b"EXISTS"]:
                    index += 2
                if index >= len(header) or header[index][0] not in {"word", "identifier"}:
                    raise DatabaseError("Nieprawidłowy plik SQL.")
                # Compare source schema names without changing identifier casing.
                token = header[index]
                name = data[token[2]:token[3]].decode("utf-8")
                if token[0] == "identifier":
                    name = name[1:-1].replace("``", "`")
                identifier(name)
                if schema is not None and schema != name:
                    raise DatabaseError("Plik zawiera więcej niż jedną bazę danych. Wyeksportuj pojedynczą bazę.")
                schema = name
                if first == b"USE" and len(header) != 2:
                    raise DatabaseError("Nieprawidłowy plik SQL.")
                omitted.append((statement_start, end))
            else:
                allowed = ((first in {b"CREATE", b"DROP", b"ALTER"} and words[1:2] == [b"TABLE"])
                           or first in {b"INSERT", b"REPLACE", b"SET", b"COMMIT"}
                           or words[:2] in [[b"START", b"TRANSACTION"], [b"LOCK", b"TABLES"], [b"UNLOCK", b"TABLES"]])
                if not allowed:
                    raise DatabaseError("Obsługiwane są pliki z tabelami i danymi jednej bazy, bez widoków, procedur i wyzwalaczy.")
                if first == b"SET" and (len(words) < 2 or not (words[1] in settings or (words[1].startswith(b"@") and not words[1].startswith(b"@@")) or words[1] in {b"@@SESSION", b"@@LOCAL"})):
                    raise DatabaseError("Plik zawiera polecenia zmieniające ustawienia serwera. Baza nie została zmieniona.")
                if first in {b"CREATE", b"INSERT", b"REPLACE"}:
                    meaningful += 1
            statement_start = end
            header = []
            previous = None

        for token in tokens(data, beginning):
            kind, value, start, end = token
            count += 1
            if count % 16384 == 0:
                if cancelled():
                    raise Cancelled()
                progress(end / len(data))
            if kind == "punct" and value == b";":
                finish(end)
                continue
            # Reject explicit schema qualification (including inside executable
            # comments). Session variable qualification is not a schema reference.
            if value == b"." and kind == "punct" and (previous is None or previous[1] not in {b"@@SESSION", b"@@LOCAL"}):
                raise DatabaseError("Plik odwołuje się do nazw kwalifikowanych bazą. Wyeksportuj tabele bez prefiksu nazwy bazy.")
            if kind == "word" and value in {b"GLOBAL", b"@@GLOBAL", b"OUTFILE", b"DUMPFILE", b"DIRECTORY", b"TABLESPACE", b"FEDERATED", b"DEFINER", b"SELECT"}:
                raise DatabaseError("Plik zawiera polecenia spoza importu tabel jednej bazy. Baza nie została zmieniona.")
            if header and header[0][1] == b"SET" and kind == "string" and (b"NO_BACKSLASH_ESCAPES" in value.upper() or b"ANSI_QUOTES" in value.upper()):
                raise DatabaseError("Plik używa nieobsługiwanego trybu SQL. Wyeksportuj bazę ze standardowym trybem cytowania.")
            if len(header) < 128:
                header.append(token)
            previous = token
        finish(len(data))
        if not meaningful:
            raise DatabaseError("Plik SQL nie zawiera tabel ani danych do importu.")
        cursor = beginning
        with Path(destination).open("wb") as output:
            for start, end in omitted + [(len(data), len(data))]:
                while cursor < start:
                    if cancelled():
                        raise Cancelled()
                    boundary = min(start, cursor + 1024 * 1024)
                    output.write(data[cursor:boundary])
                    cursor = boundary
                cursor = end


class DatabaseJob:
    def __init__(self, request, state, work):
        self.request = request
        self.state_path = Path(state)
        self.work = Path(work)
        self.cancelled = False
        self.child = None
        self.changed = False
        self.backup = None
        self.last_progress = 0
        self.state = {}
        self.password = request.get("password", "")
        self.client = Path(request.get("client", ""))
        port = request.get("port")
        user = request.get("user", "")
        if type(port) is not int or not 1 <= port <= 65535 or not isinstance(user, str) or not user.strip() or not isinstance(self.password, str):
            raise DatabaseError("Podaj poprawny port i użytkownika MySQL.")
        if not self.client.is_absolute() or not self.client.is_file() or not os.access(self.client, os.X_OK):
            raise DatabaseError("Nie znaleziono klienta mysql. Wskaż program z MAMP lub Homebrew.")
        self.options = self.work / "client.cnf"
        with os.fdopen(os.open(self.options, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as config:
            config.write("[client]\npassword=" + option_value(self.password) + "\n")
        self.connection = ["--defaults-file=" + str(self.options), "--protocol=TCP", "--host=127.0.0.1",
                           "--port=" + str(port), "--user=" + user, "--default-character-set=utf8mb4"]
        self.environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.work),
                            "MYSQL_TEST_LOGIN_FILE": str(self.work / "unused-login.cnf"),
                            "MYSQL_HISTFILE": "/dev/null", "LANG": "en_US.UTF-8"}

    def update(self, key, fraction=0, status="running", arguments=(), **extra):
        self.state.update(messageKey=key, messageArguments=list(map(str, arguments)), fraction=fraction,
                          status=status, changed=self.changed, backupPath=str(self.backup) if self.backup else None, **extra)
        temporary = self.state_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.state, ensure_ascii=False))
        temporary.chmod(0o600)
        temporary.replace(self.state_path)

    def cancel(self, *_):
        self.cancelled = True

    def check_cancelled(self):
        if self.cancelled:
            raise Cancelled()

    def run(self, executable, arguments, sql=None, input_path=None, output_path=None, progress=None, timeout=None):
        self.check_cancelled()
        with tempfile.TemporaryFile() as errors, tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as query:
            if sql is not None:
                query.write(sql.encode("utf-8"))
                query.seek(0)
            source = open(input_path, "rb") if input_path else query
            destination = open(output_path, "wb") if output_path else output
            began = time.monotonic()
            try:
                self.child = subprocess.Popen([str(executable)] + self.connection + arguments, stdin=source,
                                              stdout=destination, stderr=errors, env=self.environment, start_new_session=True)
                while self.child.poll() is None:
                    if self.cancelled or (timeout and time.monotonic() - began > timeout):
                        self.child.terminate()
                        try:
                            self.child.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            self.child.kill()
                            self.child.wait()
                        self.check_cancelled()
                        raise DatabaseError("Przekroczono czas oczekiwania na MySQL.")
                    if progress:
                        progress(source.tell())
                    time.sleep(0.1)
                self.check_cancelled()
                if self.child.returncode:
                    errors.seek(0, os.SEEK_END)
                    errors.seek(max(0, errors.tell() - 6000))
                    details = errors.read().decode("utf-8", errors="replace").strip()
                    if self.password:
                        details = details.replace(self.password, "***")
                    raise DatabaseError("MySQL zgłosił błąd: {0}", details or str(self.child.returncode))
                if output_path:
                    os.fsync(destination.fileno())
                if not output_path:
                    output.seek(0)
                    return output.read(4 * 1024 * 1024).decode("utf-8")
            finally:
                if self.child is not None and self.child.poll() is None:
                    self.child.terminate()
                    try:
                        self.child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        self.child.kill()
                        self.child.wait()
                self.child = None
                if input_path:
                    source.close()
                if output_path:
                    destination.close()

    def mysql(self, sql=None, database=None, **kwargs):
        arguments = ["--batch", "--raw", "--skip-column-names", "--skip-reconnect", "--binary-mode",
                     "--skip-auto-rehash", "--local-infile=0", "--max-allowed-packet=1G", "--connect-timeout=8",
                     "--init-command=SET SESSION sql_mode=''"]
        if database is not None:
            identifier(database)
            arguments.append("--database=" + database)
        return self.run(self.client, arguments, sql=sql, **kwargs)

    def databases(self):
        rows = self.mysql("SELECT @@server_uuid; SELECT HEX(SCHEMA_NAME) FROM information_schema.SCHEMATA ORDER BY SCHEMA_NAME;", timeout=20).splitlines()
        if not rows:
            raise DatabaseError("Nie udało się odczytać baz danych.")
        names = [bytes.fromhex(row).decode("utf-8") for row in rows[1:]]
        names = [name for name in names if name.casefold() not in SYSTEM_DATABASES]
        return rows[0], names

    def metadata(self, name):
        server, names = self.databases()
        if server != self.request.get("serverID") or name not in names:
            raise DatabaseError("Serwer lub lista baz zmieniły się. Połącz się ponownie przed importem.")
        literal = "CONVERT(0x" + name.encode("utf-8").hex() + " USING utf8mb4)"
        result = self.mysql("SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = " + literal + ";", timeout=20).strip().split("\t")
        if len(result) != 2 or not all(re.fullmatch(r"[a-zA-Z0-9_]+", value) for value in result):
            raise DatabaseError("Nie udało się odczytać ustawień bazy danych.")
        return result

    @contextmanager
    def replacement_lock(self):
        name = self.request.get("database")
        identifier(name)
        directory = Path(self.request["lockDirectory"])
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        key = hashlib.sha256((str(self.request["port"]) + ":" + name).encode()).hexdigest()
        with os.fdopen(os.open(directory / (key + ".lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise DatabaseError("Inna operacja zastępuje tę bazę. Poczekaj na jej zakończenie.")
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def replace(self):
        with self.replacement_lock():
            self.replace_locked()

    def replace_locked(self):
        name = self.request.get("database")
        quoted = identifier(name)
        source = Path(self.request.get("sqlFile", ""))
        if not source.is_file() or source.suffix.lower() != ".sql":
            raise DatabaseError("Wybierz istniejący plik .sql.")
        self.update("Sprawdzanie pliku SQL…")
        snapshot = self.work / "source.sql"
        # Open once and copy in bounded chunks so a changed original cannot be
        # substituted between validation and import.
        with source.open("rb") as original, snapshot.open("wb") as copy:
            if not stat.S_ISREG(os.fstat(original.fileno()).st_mode):
                raise DatabaseError("Wybierz istniejący plik .sql.")
            while True:
                self.check_cancelled()
                chunk = original.read(1024 * 1024)
                if not chunk:
                    break
                copy.write(chunk)
        prepared = self.work / "import.sql"
        def validation_progress(fraction):
            if time.monotonic() - self.last_progress > 0.5:
                self.update("Sprawdzanie pliku SQL…", 0.15 * fraction)
                self.last_progress = time.monotonic()
        prepare_dump(snapshot, prepared, lambda: self.cancelled, validation_progress)
        settings = self.metadata(name)
        if self.request.get("backup", True):
            dump = self.client.with_name("mysqldump")
            if not dump.is_file() or not os.access(dump, os.X_OK):
                raise DatabaseError("Brakuje programu mysqldump obok mysql. Nie można utworzyć kopii.")
            directory = Path(self.request["backupDirectory"])
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            safe_name = re.sub(r"[^a-zA-Z0-9_-]", "_", name)[:40]
            backup = directory / (safe_name + "-" + time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8] + ".sql")
            partial = backup.with_suffix(".sql.partial")
            self.update("Tworzenie kopii zapasowej…", 0.2)
            try:
                with os.fdopen(os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb"):
                    pass
                self.run(dump, ["--single-transaction", "--routines", "--events", "--triggers", "--hex-blob",
                                "--no-tablespaces", "--loose-column-statistics=0", "--set-gtid-purged=OFF",
                                "--add-drop-database", "--databases", name], output_path=partial)
                if not partial.stat().st_size:
                    raise DatabaseError("Kopia zapasowa jest pusta. Baza nie została zmieniona.")
                partial.replace(backup)
                self.backup = backup
            finally:
                partial.unlink(missing_ok=True)
        # Revalidate after a potentially long backup, immediately before DROP.
        if self.metadata(name) != settings:
            raise DatabaseError("Serwer lub lista baz zmieniły się. Połącz się ponownie przed importem.")
        self.check_cancelled()
        self.changed = True  # From this point a failed/cancelled job may be partial.
        self.update("Czyszczenie wybranej bazy…", 0.35)
        self.mysql("DROP DATABASE " + quoted + ";\nCREATE DATABASE " + quoted + " CHARACTER SET " + settings[0] + " COLLATE " + settings[1] + ";", timeout=30)
        self.update("Importowanie pliku SQL…", 0.4)
        size = prepared.stat().st_size
        def import_progress(offset):
            if time.monotonic() - self.last_progress > 0.5:
                self.update("Importowanie pliku SQL…", min(0.99, 0.4 + 0.59 * offset / max(1, size)))
                self.last_progress = time.monotonic()
        self.mysql(database=name, input_path=prepared, progress=import_progress)
        self.update("Baza {0} została zastąpiona.", 1, "complete", [name])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, required=True)
    args = parser.parse_args()
    job = None
    try:
        request = json.load(sys.stdin)
        with tempfile.TemporaryDirectory(prefix="database-", dir=args.state.parent) as work:
            job = DatabaseJob(request, args.state, work)
            signal.signal(signal.SIGTERM, job.cancel)
            signal.signal(signal.SIGINT, job.cancel)
            try:
                if request.get("operation") == "list":
                    job.update("Łączenie z lokalnym MySQL…")
                    server, names = job.databases()
                    job.update("Połączono z lokalnym MySQL.", 1, "complete", databases=names, serverID=server)
                elif request.get("operation") == "replace":
                    job.replace()
                else:
                    raise DatabaseError("Nieprawidłowe żądanie operacji bazy danych.")
            except Cancelled:
                job.update("Operacja została anulowana.", status="cancelled")
                return 1
            except Exception as error:
                if not isinstance(error, DatabaseError):
                    error = DatabaseError("Nie udało się wykonać operacji bazy danych: {0}", str(error))
                job.update(error.key, status="failed", arguments=error.arguments)
                return 1
    except Exception as error:
        key = error.key if isinstance(error, DatabaseError) else "Nie udało się uruchomić obsługi MySQL."
        arguments = error.arguments if isinstance(error, DatabaseError) else []
        args.state.write_text(json.dumps({"status": "failed", "messageKey": key, "messageArguments": arguments, "fraction": 0}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
