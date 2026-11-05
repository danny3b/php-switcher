#!/usr/bin/env python3
"""Install an isolated PHP CLI from verified php.net sources on this Mac.

Uses existing Homebrew build libraries, never runs brew upgrade, never changes
the active PHP link, and publishes an installation only after smoke checks.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time


class InstallError(Exception):
    pass


class Message(str):
    """Keep interpolation arguments separate so the app can change language live."""
    def __new__(cls, key, *arguments):
        text = re.sub(r"\{(\d+)\}", lambda match: str(arguments[int(match[1])]), key)
        result = super().__new__(cls, text)
        result.key = key
        result.arguments = list(map(str, arguments))
        return result


def valid_version(value):
    if not re.fullmatch(r"8\.(3|4|5)\.\d{1,3}", value):
        raise InstallError("Podaj pełną wersję PHP 8.3, 8.4 lub 8.5, np. 8.4.27.")
    return value


def safe_extract(archive, destination):
    destination = Path(destination).resolve()
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            path = (destination / member.name).resolve()
            if destination not in path.parents or not (member.isfile() or member.isdir()):
                raise InstallError("Archiwum zawiera niedozwoloną ścieżkę lub dowiązanie.")
        tar.extractall(destination)


def configure_options(raw, prefix, sdk, help_text):
    supported = set(re.findall(r"--(?:enable|disable|with|without)-[\w-]+", help_text))
    for option in list(supported):
        for left, right in [("--without-", "--with-"), ("--disable-", "--enable-"),
                            ("--with-", "--without-"), ("--enable-", "--disable-")]:
            if option.startswith(left):
                supported.add(option.replace(left, right, 1))
    args, extra_env = [], {}
    omitted = ("--prefix=", "--sysconfdir=", "--with-config-file-", "--with-pear",
               "--without-pear", "--with-apxs", "--enable-fpm", "--disable-fpm",
               "--with-fpm-", "--enable-phpdbg", "--disable-phpdbg", "--enable-dtrace",
               "--disable-dtrace", "--build=", "--host=", "--disable-cgi")
    for item in shlex.split(raw):
        item = re.sub(r"/Library/Developer/CommandLineTools/SDKs/MacOSX[\d.]*\.sdk", sdk, item)
        if not item.startswith("--"):
            if "=" in item:
                key, value = item.split("=", 1)
                if key in {"PKG_CONFIG_PATH", "PKG_CONFIG_LIBDIR", "KERBEROS_CFLAGS", "SASL_CFLAGS", "SASL_LIBS"}:
                    extra_env[key] = value
            continue
        if item.startswith(omitted):
            continue
        if item.split("=", 1)[0] in supported:
            args.append(item)
    args += ["--prefix=" + str(prefix), "--sysconfdir=" + str(prefix / "etc"),
             "--with-config-file-path=" + str(prefix / "etc"),
             "--with-config-file-scan-dir=" + str(prefix / "etc/conf.d"),
             "--disable-fpm", "--disable-phpdbg", "--disable-cgi", "--disable-dtrace", "--without-pear"]
    return args, extra_env


def patch_sdk(src):
    m4 = src / "build/php.m4"
    text = m4.read_text()
    text = text.replace('"$1" != "/usr/$PHP_LIBDIR"', '"$1" != "$PHP_OS_SDKPATH/usr/$PHP_LIBDIR"')
    text = text.replace('"$1" != "/usr/include"', '"$1" != "$PHP_OS_SDKPATH/usr/include"')
    m4.write_text(text)
    ac = src / "configure.ac"
    text = ac.read_text()
    if "PHP_ARG_WITH([os-sdkpath]" not in text:
        marker = "PHP_ARG_ENABLE([rpath],"
        if marker not in text:
            raise InstallError("Nieznany format konfiguracji źródeł PHP.")
        text = text.replace(marker, '''PHP_ARG_WITH([os-sdkpath],
  [for system SDK directory],
  [AS_HELP_STRING([--with-os-sdkpath=NAME], [System SDK directory])],
  [], [no])

''' + marker, 1)
        ac.write_text(text)


class Installer:
    def __init__(self, version, state=None):
        self.version = valid_version(version)
        self.home = Path.home()
        self.root = self.home / ".local/php"
        self.prefix = self.root / version
        self.state = Path(state) if state else None
        self.cancelled = False
        self.child = None
        self.created_prefix = False
        self.work = None
        self.fraction = 0
        self.env = os.environ.copy()
        self.env.pop("PHPRC", None)
        self.env.pop("PHP_INI_SCAN_DIR", None)
        self.env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        log_dir = self.home / "Library/Logs/PHP Switcher"
        log_dir.mkdir(parents=True, exist_ok=True)
        self.log_path = log_dir / ("php-" + version + "-" + time.strftime("%Y%m%d-%H%M%S") + ".log")
        self.log = self.log_path.open("w", buffering=1)
        self.lock = None

    def progress(self, fraction, message, status="running"):
        self.fraction = fraction
        record = {"fraction": fraction, "message": message, "status": status, "log": str(self.log_path),
                  "messageKey": getattr(message, "key", str(message)),
                  "messageArguments": getattr(message, "arguments", [])}
        print(json.dumps(record, ensure_ascii=False), flush=True)
        if self.state:
            self.state.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.state.with_suffix(".tmp")
            temporary.write_text(json.dumps(record, ensure_ascii=False))
            temporary.replace(self.state)

    def cancel(self, *_):
        self.cancelled = True
        if self.child and self.child.poll() is None:
            try:
                os.killpg(self.child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    def run(self, args, cwd=None, capture=False, env=None, timeout=1800):
        if self.cancelled:
            raise InstallError("Instalacja anulowana.")
        args = list(map(str, args))
        self.log.write("\n$ " + shlex.join(args) + "\n")
        output = tempfile.TemporaryFile() if capture else self.log
        self.child = subprocess.Popen(args, cwd=cwd, env=env or self.env,
                                      stdout=output, stderr=self.log, start_new_session=True)
        deadline = time.monotonic() + timeout
        while self.child.poll() is None:
            if self.cancelled or time.monotonic() > deadline:
                self.cancel()
                try:
                    self.child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(self.child.pid, signal.SIGKILL)
                    self.child.wait()
                raise InstallError("Instalacja anulowana." if self.cancelled else "Przekroczono czas operacji.")
            time.sleep(0.15)
        code = self.child.returncode
        self.child = None
        if self.cancelled:
            raise InstallError("Instalacja anulowana.")
        if code:
            raise InstallError(Message("Polecenie zakończyło się błędem: {0}. Szczegóły w dzienniku.", Path(args[0]).name))
        if capture:
            output.seek(0)
            result = output.read().decode("utf-8", errors="replace")
            output.close()
            self.log.write(result[:262144] + "\n")
            return result.strip()
        return ""

    def download(self, url, destination):
        self.run(["/usr/bin/curl", "--fail", "--silent", "--show-error", "--location",
                  "--proto", "=https", "--max-time", "180", "--retry", "2", url, "-o", destination], timeout=600)

    def install(self):
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock = (self.root / ".installer.lock").open("a")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise InstallError("Inna instalacja PHP jest w toku. Poczekaj na jej zakończenie.")
        if self.prefix.exists():
            raise InstallError("Ten katalog wersji już istnieje. Użyj Odśwież, aby ją wybrać.")
        self.progress(0.02, "Sprawdzanie narzędzi i bibliotek…")
        # A MAMP version may be active; its SDK options are not a Homebrew build template.
        bases = [self.root / "8.3.36", Path("/usr/local/opt/php@8.3"),
                 Path("/opt/homebrew/opt/php@8.3"), self.root / "current"]
        base = next((p.resolve() for p in bases if (p / "bin/php-config").is_file()), None)
        if not base:
            raise InstallError("Brak bazowego PHP i bibliotek do kompilacji. Wymagane jest PHP z Homebrew lub wcześniejsza instalacja DevŻbik.")
        raw = self.run([base / "bin/php-config", "--configure-options"], capture=True)
        binary_info = self.run(["/usr/bin/file", base / "bin/php"], capture=True)
        arch = "x86_64" if "x86_64" in binary_info and "arm64" not in binary_info else "arm64"
        brew = Path("/usr/local" if arch == "x86_64" else "/opt/homebrew")
        for required in [brew / "bin/autoconf", brew / "bin/pkg-config", Path("/usr/bin/make")]:
            if not required.exists():
                raise InstallError(Message("Brakuje narzędzia: {0}", required))
        sdk = self.run(["/usr/bin/xcrun", "--show-sdk-path"], capture=True)
        self.env.update({"CC": "/usr/bin/clang -arch " + arch, "CXX": "/usr/bin/clang++ -arch " + arch,
                         "CFLAGS": "-O2", "CXXFLAGS": "-O2", "LDFLAGS": "-arch " + arch,
                         "MACOSX_DEPLOYMENT_TARGET": "14.0", "lt_cv_sys_max_cmd_len": "131072",
                         "PATH": str(brew / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin"})
        cache = self.home / "Library/Caches/PHP Switcher"
        cache.mkdir(parents=True, exist_ok=True)
        # PHP's generated configure/makefiles do not support spaces in source paths.
        self.work = Path(tempfile.mkdtemp(prefix="php-switcher-" + self.version + "-"))
        self.progress(0.06, "Pobieranie informacji z php.net…")
        metadata = self.work / "release.json"
        self.download("https://www.php.net/releases/?json&version=" + self.version, metadata)
        release = json.loads(metadata.read_text())
        filename = "php-" + self.version + ".tar.xz"
        source = next((s for s in release.get("source", []) if s.get("filename") == filename), None)
        if release.get("version") != self.version or not source or not re.fullmatch(r"[a-f0-9]{64}", source.get("sha256", "")):
            raise InstallError("PHP.net nie potwierdziło tej wersji lub sumy kontrolnej.")
        self.progress(0.10, Message("Pobieranie PHP {0}…", self.version))
        archive = cache / filename
        if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != source["sha256"]:
            partial = self.work / filename
            self.download("https://www.php.net/distributions/" + filename, partial)
            if hashlib.sha256(partial.read_bytes()).hexdigest() != source["sha256"]:
                raise InstallError("Suma SHA-256 pobranego PHP jest niezgodna.")
            partial.replace(archive)
        safe_extract(archive, self.work)
        src = self.work / ("php-" + self.version)
        patch_sdk(src)
        self.progress(0.16, "Przygotowanie kompilacji…")
        self.run(["./buildconf", "--force"], cwd=src)
        help_text = self.run(["./configure", "--help"], cwd=src, capture=True)
        args, extra = configure_options(raw, self.prefix, sdk, help_text)
        # config.guess sees the ARM host even when clang produces x86_64 for
        # Rosetta. PHP's JIT backend must match the executable, not that host.
        triple = arch + "-apple-darwin" + platform.release().split(".")[0]
        args += ["--build=" + triple, "--host=" + triple]
        self.env.update(extra)
        # The SDK metadata paths are versioned by Homebrew; prefer the current SDK.
        os_major = platform.mac_ver()[0].split(".")[0]
        if "PKG_CONFIG_LIBDIR" in self.env:
            self.env["PKG_CONFIG_LIBDIR"] = re.sub(r"/os/mac/pkgconfig/\d+", "/os/mac/pkgconfig/" + os_major, self.env["PKG_CONFIG_LIBDIR"])
        self.progress(0.22, "Konfigurowanie PHP i rozszerzeń…")
        self.run(["./configure"] + args, cwd=src)
        self.progress(0.35, "Kompilowanie PHP — to może potrwać kilka minut…")
        jobs = str(min(os.cpu_count() or 4, 6))
        self.run(["/usr/bin/make", "-j" + jobs], cwd=src)
        self.progress(0.68, "Przygotowanie instalacji…")
        stage = self.work / "stage"
        self.run(["/usr/bin/make", "install", "INSTALL_ROOT=" + str(stage)], cwd=src)
        staged_prefix = stage / str(self.prefix).lstrip("/")
        (staged_prefix / ".installing").write_text(self.version)
        staged_prefix.rename(self.prefix)
        self.created_prefix = True
        php = self.prefix / "bin/php"
        extension_dir = Path(self.run([self.prefix / "bin/php-config", "--extension-dir"], capture=True))
        etc = self.prefix / "etc"
        (etc / "conf.d").mkdir(parents=True, exist_ok=True)
        config = self.run([base / "bin/php", "-r", "echo php_ini_loaded_file();"], capture=True)
        template = Path(config) if config and Path(config).is_file() else src / "php.ini-development"
        ini = template.read_text()
        extra_ini = ""
        if (template.parent / "conf.d").is_dir():
            extra_ini = "\n".join(p.read_text() for p in sorted((template.parent / "conf.d").glob("*.ini")))
        wanted_imagick = bool(re.search(r"^\s*extension\s*=.*imagick", ini + "\n" + extra_ini, re.M))
        # Preserve regular settings, but never load modules compiled for a different PHP ABI.
        ini = re.sub(r"^\s*(?:zend_extension|extension|extension_dir)\s*=.*$", "", ini, flags=re.M)
        extra_ini = re.sub(r"^\s*(?:zend_extension|extension|extension_dir)\s*=.*$", "", extra_ini, flags=re.M)
        if tuple(map(int, self.version.split(".")[:2])) >= (8, 4):
            obsolete = r"^\s*session\.(?:sid_length|sid_bits_per_character)\s*=.*$"
            ini = re.sub(obsolete, "", ini, flags=re.M)
            extra_ini = re.sub(obsolete, "", extra_ini, flags=re.M)
        if tuple(map(int, self.version.split(".")[:2])) >= (8, 5):
            obsolete = r"^\s*(?:report_memleaks|intl\.error_level)\s*=.*$"
            ini = re.sub(obsolete, "", ini, flags=re.M)
            extra_ini = re.sub(obsolete, "", extra_ini, flags=re.M)
        ini += '\n\n; DevŻbik\nextension_dir = "' + str(extension_dir) + '"\n'
        opcache = extension_dir / "opcache.so"
        if opcache.exists():
            ini += 'zend_extension="' + str(opcache) + '"\n'
        if wanted_imagick:
            self.progress(0.76, "Budowanie rozszerzenia Imagick…")
            im_archive = self.work / "imagick-3.8.1.tgz"
            self.download("https://pecl.php.net/get/imagick-3.8.1.tgz", im_archive)
            im_extract = self.work / "imagick-source"
            im_extract.mkdir()
            safe_extract(im_archive, im_extract)
            im_src = im_extract / "imagick-3.8.1"
            self.run([self.prefix / "bin/phpize"], cwd=im_src)
            self.run(["./configure", "--with-php-config=" + str(self.prefix / "bin/php-config"),
                      "--with-imagick=" + str(brew / "opt/imagemagick"),
                      "--build=" + triple, "--host=" + triple], cwd=im_src)
            self.run(["/usr/bin/make", "-j" + jobs], cwd=im_src)
            self.run(["/usr/bin/make", "install"], cwd=im_src)
            ini += 'extension="imagick.so"\n'
        (etc / "php.ini").write_text(ini)
        (etc / "conf.d/settings.ini").write_text(extra_ini)
        self.progress(0.94, "Sprawdzanie wersji i rozszerzeń…")
        smoke = '''$v = json_decode($argv[1], true); if (PHP_VERSION !== $v) exit(2);
foreach (['intl','mbstring','dom','pdo_mysql','gd','zip','openssl'] as $e) if (!extension_loaded($e)) {fwrite(STDERR,$e); exit(3);}
$db=new PDO('sqlite::memory:'); if ($db->query('SELECT 7')->fetchColumn()!=7) exit(4);
$gd=imagecreatetruecolor(2,2); ob_start(); imagepng($gd); $png=ob_get_clean(); if (!str_starts_with($png,"\\x89PNG")) exit(5);
if (extension_loaded('imagick')) {$im=new Imagick();$im->newImage(2,2,'red');$im->setImageFormat('png');if (!$im->getImageBlob()) exit(6);}
echo PHP_VERSION;'''
        actual = self.run([php, "-d", "opcache.enable_cli=1", "-r", smoke, json.dumps(self.version)], capture=True)
        if actual != self.version:
            raise InstallError("Nowe PHP nie przeszło kontroli uruchomienia.")
        jit_test = self.work / "jit-check.php"
        jit_test.write_text('''<?php
function phpSwitcherSum(int $n): int { $sum=0; for ($i=0;$i<$n;$i++) $sum+=$i; return $sum; }
for ($i=0;$i<100;$i++) if (phpSwitcherSum(10000)!==49995000) exit(1);
$jit=opcache_get_status(false)['jit'];
if (!$jit['enabled'] || !$jit['on']) exit(2);
echo 'JIT OK';
''')
        self.run([php, "-d", "opcache.enable_cli=1", "-d", "opcache.file_update_protection=0",
                  "-d", "opcache.jit=tracing", "-d", "opcache.jit_hot_func=1", "-d",
                  "opcache.jit_hot_loop=1", "-d", "opcache.jit_buffer_size=16M", jit_test])
        (self.prefix / "BUILD-INFO.txt").write_text("DevŻbik\nVersion: " + self.version + "\nSource: https://www.php.net/distributions/" + filename + "\nSHA256: " + source["sha256"] + "\nArchitecture: " + arch + "\nLog: " + str(self.log_path) + "\nStandalone CLI; web services and current symlink are unchanged.\n")
        (self.prefix / ".installing").unlink()
        self.created_prefix = False
        self.progress(1, Message("PHP {0} jest gotowe. Kliknij Użyj, aby je włączyć.", self.version), "complete")

    def cleanup(self):
        if self.created_prefix and (self.prefix / ".installing").is_file():
            shutil.rmtree(self.prefix)
        if self.work and self.work.exists():
            shutil.rmtree(self.work)
        self.log.close()
        if self.lock:
            self.lock.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--state")
    args = parser.parse_args()
    installer = None
    try:
        installer = Installer(args.version, args.state)
        signal.signal(signal.SIGTERM, installer.cancel)
        signal.signal(signal.SIGINT, installer.cancel)
        installer.install()
        return 0
    except Exception as error:
        if installer:
            installer.log.write("\nERROR: " + str(error) + "\n")
            message = error.args[0] if isinstance(error, InstallError) and error.args else str(error)
            installer.progress(installer.fraction, message, "cancelled" if installer.cancelled else "failed")
        else:
            print(str(error), file=sys.stderr)
        return 1
    finally:
        if installer:
            installer.cleanup()


if __name__ == "__main__":
    sys.exit(main())
