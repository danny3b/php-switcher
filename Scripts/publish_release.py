#!/usr/bin/env python3
"""Publish a prepared, signed DevŻbik release using existing Git credentials.

Authentication is kept in memory and passed to curl over stdin, never in process
arguments, repository files, or logs. No GitHub CLI installation is required.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from urllib.parse import quote
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "danny3b/php-switcher"
API_ROOT = f"https://api.github.com/repos/{REPOSITORY}"


def verify_bundle_matches_archive(app, archive):
    """Reject a DMG containing a different app, even if its version is the same."""
    with zipfile.ZipFile(archive) as package:
        expected_paths = set()
        for entry in package.infolist():
            prefix = app.name + "/"
            if not entry.filename.startswith(prefix) or entry.is_dir():
                continue
            relative = entry.filename[len(prefix):]
            if not relative or Path(relative).is_absolute() or ".." in Path(relative).parts:
                raise RuntimeError("Invalid application path in the ZIP archive.")
            expected_paths.add(relative)
            file = app / relative
            if stat.S_ISLNK(entry.external_attr >> 16):
                if not file.is_symlink() or os.readlink(file) != package.read(entry).decode():
                    raise RuntimeError(f"DMG symbolic link differs from the ZIP: {relative}")
            elif file.is_symlink() or not file.is_file() or file.read_bytes() != package.read(entry):
                raise RuntimeError(f"DMG file differs from the ZIP: {relative}")
        actual_paths = {str(file.relative_to(app)) for file in app.rglob("*") if file.is_symlink() or file.is_file()}
        if not expected_paths or actual_paths != expected_paths:
            raise RuntimeError("The DMG and ZIP application file lists differ.")


def validate_dmg(image, archive):
    subprocess.run(["/usr/bin/hdiutil", "verify", str(image)], check=True)
    with tempfile.TemporaryDirectory(prefix="dmg-validation-", dir=ROOT / "build") as directory:
        mount = Path(directory) / "volume"
        mount.mkdir()
        subprocess.run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                        "-mountpoint", str(mount), str(image)], check=True)
        try:
            applications = mount / "Applications"
            if not applications.is_symlink() or os.readlink(applications) != "/Applications":
                raise RuntimeError("The DMG is missing its Applications folder shortcut.")
            bundle_name = "PHP Switcher.app" if archive.name.startswith("PHP-Switcher-") else "DevZbik.app"
            app = mount / bundle_name
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
            verify_bundle_matches_archive(app, archive)
        finally:
            subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)], check=True)


def upload_asset(api, release_id, asset):
    uploaded = api.request("POST", f"/releases/{release_id}/assets", asset=asset)
    expected_digest = "sha256:" + hashlib.sha256(asset.read_bytes()).hexdigest()
    if uploaded["size"] != asset.stat().st_size or uploaded.get("digest") != expected_digest:
        raise RuntimeError(f"Uploaded asset verification failed: {asset.name}")
    print(f"Uploaded and verified {asset.name}.", flush=True)


class GitHub:
    def __init__(self):
        result = subprocess.run(
            ["git", "credential", "fill"], cwd=ROOT, text=True, capture_output=True,
            input=f"protocol=https\nhost=github.com\npath={REPOSITORY}.git\n\n",
            env={**os.environ, "GIT_TERMINAL_PROMPT": "0"}, check=True,
        )
        values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        self.token = values.get("password")
        if not self.token:
            raise RuntimeError("Sign in to GitHub using your Git credential helper first.")

    def request(self, method, path="", payload=None, asset=None):
        if asset:
            url = f"https://uploads.github.com/repos/{REPOSITORY}{path}?name={quote(asset.name)}"
        else:
            url = API_ROOT + path
        config = "\n".join("header = " + json.dumps(value) for value in [
            "Authorization: Bearer " + self.token,
            "Accept: application/vnd.github+json",
            "X-GitHub-Api-Version: 2022-11-28",
            "User-Agent: DevZbik-Release",
            "Content-Type: " + ("application/octet-stream" if asset else "application/json"),
        ]) + "\n"
        command = ["/usr/bin/curl", "--fail-with-body", "--silent", "--show-error", "--proto", "=https",
                   "--max-time", "300", "--config", "-", "--request", method, url]
        if asset:
            command += ["--data-binary", "@" + str(asset)]
        elif payload is not None:
            # JSON here contains public release metadata only, never credentials.
            command += ["--data-binary", json.dumps(payload)]
        result = subprocess.run(command, input=config, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(f"GitHub {method} {path} failed: {result.stderr.strip()} {result.stdout[:700]}")
        return json.loads(result.stdout) if result.stdout else None


def validate_artifacts(directory, version, build, public_key):
    archive = directory / f"DevZbik-{version}-arm64.zip"
    image = directory / f"DevZbik-{version}-arm64.dmg"
    feed = directory / "appcast.xml"
    sums = directory / "SHA256SUMS"
    expected = {}
    for line in sums.read_text().splitlines():
        digest, filename = line.split(None, 1)
        expected[filename.strip()] = digest
    for file in [archive, image, feed]:
        if hashlib.sha256(file.read_bytes()).hexdigest() != expected.get(file.name):
            raise RuntimeError(f"Checksum mismatch: {file.name}")
    namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    items = ET.fromstring(feed.read_bytes()).findall("./channel/item")
    item = next((item for item in items if item.findtext(namespace + "version") == str(build)), None)
    if item is None or item.findtext(namespace + "shortVersionString") != version:
        raise RuntimeError("The appcast does not match the release version and build number.")
    enclosure = item.find("enclosure")
    url = f"https://github.com/{REPOSITORY}/releases/download/v{version}/{archive.name}"
    if enclosure is None or enclosure.get("url") != url or int(enclosure.get("length", "0")) != archive.stat().st_size:
        raise RuntimeError("The appcast download URL or archive size is incorrect.")
    signature = enclosure.get(namespace + "edSignature")
    if not signature:
        raise RuntimeError("The archive has no EdDSA signature.")
    with zipfile.ZipFile(archive) as package:
        metadata = plistlib.loads(package.read("DevZbik.app/Contents/Info.plist"))
    if (metadata.get("CFBundleIdentifier") != "pl.daniel.php-switcher"
            or metadata.get("CFBundleVersion") != str(build)
            or metadata.get("CFBundleShortVersionString") != version
            or metadata.get("SUPublicEDKey") != public_key):
        raise RuntimeError("The archived app does not match the release metadata or signing key.")
    verifier = ROOT / "build/dependencies/Sparkle-2.10.1/bin/sign_update"
    key_tool = verifier.with_name("generate_keys")
    actual_key = subprocess.check_output([str(key_tool), "--account", "pl.daniel.php-switcher", "-p"], text=True).strip()
    if actual_key != public_key:
        raise RuntimeError("The signing key in Keychain does not match the embedded public key.")
    subprocess.run([str(verifier), "--account", "pl.daniel.php-switcher", "--verify", str(archive), signature], check=True)
    subprocess.run([str(verifier), "--account", "pl.daniel.php-switcher", "--verify", str(feed)], check=True)
    validate_dmg(image, archive)
    return [archive, image, feed, sums]


def add_dmg_to_release(directory, version):
    """Add a manual installer without replacing any published update assets."""
    api = GitHub()
    release = api.request("GET", "/releases/tags/v" + version)
    if release["draft"]:
        raise RuntimeError("Use --add-dmg only for an already published release.")
    existing = {asset["name"]: asset for asset in release["assets"]}
    archive = directory / f"DevZbik-{version}-arm64.zip"
    if archive.name not in existing:
        archive = directory / f"PHP-Switcher-{version}-arm64.zip"
    image = archive.with_suffix(".dmg")
    checksum = image.with_suffix(".dmg.sha256")
    if image.name in existing or checksum.name in existing:
        raise RuntimeError("The DMG or its checksum already exists. Published assets will not be overwritten.")
    published_archive = existing.get(archive.name)
    if not published_archive or published_archive.get("digest") != "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest():
        raise RuntimeError("The local ZIP must match the original published ZIP exactly.")
    validate_dmg(image, archive)
    expected_checksum = hashlib.sha256(image.read_bytes()).hexdigest() + "  " + image.name + "\n"
    if checksum.read_text() != expected_checksum:
        raise RuntimeError("The DMG checksum does not match. Create the DMG again.")
    upload_asset(api, release["id"], image)
    upload_asset(api, release["id"], checksum)
    print(release["html_url"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notes", type=Path, help="Markdown release notes file")
    parser.add_argument("--publish", action="store_true", help="Publish after all assets are uploaded; otherwise leave a draft")
    parser.add_argument("--add-dmg", action="store_true", help="Add a DMG of the original ZIP to the current version's published release")
    args = parser.parse_args()
    if args.add_dmg and (args.notes or args.publish):
        parser.error("--add-dmg cannot be combined with --notes or --publish")
    if not args.add_dmg and not args.notes:
        parser.error("--notes is required when creating a release")
    metadata = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    version, build = metadata["CFBundleShortVersionString"], metadata["CFBundleVersion"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not build.isdecimal():
        raise RuntimeError("Invalid release version or build number.")
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT).strip():
        raise RuntimeError("Commit the release source before publishing.")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    remote = subprocess.check_output(["git", "ls-remote", "origin", "refs/heads/main"], cwd=ROOT, text=True).split()
    if not remote or remote[0] != revision:
        raise RuntimeError("Push the release commit to origin/main before publishing.")
    directory = ROOT / "build/releases" / version
    if args.add_dmg:
        add_dmg_to_release(directory, version)
        return
    if (directory / "SOURCE_REVISION").read_text().strip() != revision:
        raise RuntimeError("Release artifacts are stale. Run Scripts/prepare_release.sh again.")
    assets = validate_artifacts(directory, version, build, metadata["SUPublicEDKey"])
    api = GitHub()
    releases = api.request("GET", "/releases?per_page=100")
    if any(release["tag_name"] == "v" + version for release in releases):
        raise RuntimeError("This release already exists. Do not overwrite published update artifacts.")
    release = api.request("POST", "/releases", {
        "tag_name": "v" + version, "target_commitish": revision, "name": "DevŻbik " + version,
        "body": args.notes.read_text(), "draft": True, "prerelease": False,
    })
    release_id = release["id"]
    print(f"Created draft release {release_id} for {revision}.", flush=True)
    for asset in assets:
        upload_asset(api, release_id, asset)
    if args.publish:
        release = api.request("PATCH", f"/releases/{release_id}", {"draft": False, "make_latest": "true"})
    print(release["html_url"])


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
