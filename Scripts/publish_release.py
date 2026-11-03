#!/usr/bin/env python3
"""Publish a prepared, signed PHP Switcher release using existing Git credentials.

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
import subprocess
import sys
from urllib.parse import quote
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "danny3b/php-switcher"
API_ROOT = f"https://api.github.com/repos/{REPOSITORY}"


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
            "User-Agent: PHP-Switcher-Release",
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
    archive = directory / f"PHP-Switcher-{version}-arm64.zip"
    feed = directory / "appcast.xml"
    sums = directory / "SHA256SUMS"
    expected = {}
    for line in sums.read_text().splitlines():
        digest, filename = line.split(None, 1)
        expected[filename.strip()] = digest
    for file in [archive, feed]:
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
        metadata = plistlib.loads(package.read("PHP Switcher.app/Contents/Info.plist"))
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
    return [archive, feed, sums]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notes", type=Path, required=True, help="Markdown release notes file")
    parser.add_argument("--publish", action="store_true", help="Publish after all assets are uploaded; otherwise leave a draft")
    args = parser.parse_args()
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
    if (directory / "SOURCE_REVISION").read_text().strip() != revision:
        raise RuntimeError("Release artifacts are stale. Run Scripts/prepare_release.sh again.")
    assets = validate_artifacts(directory, version, build, metadata["SUPublicEDKey"])
    api = GitHub()
    releases = api.request("GET", "/releases?per_page=100")
    if any(release["tag_name"] == "v" + version for release in releases):
        raise RuntimeError("This release already exists. Do not overwrite published update artifacts.")
    release = api.request("POST", "/releases", {
        "tag_name": "v" + version, "target_commitish": revision, "name": "PHP Switcher " + version,
        "body": args.notes.read_text(), "draft": True, "prerelease": False,
    })
    release_id = release["id"]
    print(f"Created draft release {release_id} for {revision}.", flush=True)
    for asset in assets:
        uploaded = api.request("POST", f"/releases/{release_id}/assets", asset=asset)
        expected_digest = "sha256:" + hashlib.sha256(asset.read_bytes()).hexdigest()
        if uploaded["size"] != asset.stat().st_size or uploaded.get("digest") != expected_digest:
            raise RuntimeError("Uploaded asset verification failed; release remains a draft.")
        print(f"Uploaded and verified {asset.name}.", flush=True)
    if args.publish:
        release = api.request("PATCH", f"/releases/{release_id}", {"draft": False, "make_latest": "true"})
    print(release["html_url"])


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
