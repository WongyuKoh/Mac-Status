#!/usr/bin/env python3
"""Publishable Sparkle metadata; signing keys remain in the login Keychain."""

import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
from urllib.parse import quote
import xml.etree.ElementTree as ET
import zipfile


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPOSITORY_URL = "https://github.com/WongyuKoh/Mac-Status"
FEED_URL = REPOSITORY_URL + "/releases/latest/download/appcast.xml"
KEYCHAIN_ACCOUNT = "com.kwg.macstatus"
ET.register_namespace("sparkle", SPARKLE_NAMESPACE)


def sparkle(name):
    return "{" + SPARKLE_NAMESPACE + "}" + name


def checked_base64(value, byte_count, label):
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError(label + " is not valid base64.") from error
    if len(decoded) != byte_count:
        raise ValueError(label + " has an invalid length.")
    return value


def validate_info(info):
    if info.get("CFBundleIdentifier") != "com.kwg.macstatus":
        raise ValueError("Refusing to publish an appcast for a different application.")
    version = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", version):
        raise ValueError("CFBundleShortVersionString must be a semantic version.")
    if not re.fullmatch(r"[0-9]+", build) or int(build) < 1:
        raise ValueError("CFBundleVersion must be a positive build number.")
    if info.get("SUFeedURL") != FEED_URL:
        raise ValueError("The application must use the published Mac Status update feed.")
    if not info.get("SURequireSignedFeed") or not info.get("SUVerifyUpdateBeforeExtraction"):
        raise ValueError("Signed feeds and archive verification must be enabled.")
    checked_base64(info.get("SUPublicEDKey", ""), 32, "Sparkle public key")
    return version, build


def build_appcast(info, archive_name, archive_size, signature, notes, published=None):
    version, build = validate_info(info)
    checked_base64(signature, 64, "Archive signature")
    if archive_size < 1:
        raise ValueError("The update archive is empty.")
    release_url = REPOSITORY_URL + "/releases/tag/v" + quote(version, safe="")
    download_url = REPOSITORY_URL + "/releases/download/v" + quote(version, safe="") + "/" + quote(archive_name, safe="")
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Mac Status 업데이트"
    ET.SubElement(channel, "link").text = REPOSITORY_URL + "/releases"
    ET.SubElement(channel, "description").text = "Mac Status의 서명된 업데이트"
    ET.SubElement(channel, "language").text = "ko"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "Mac Status " + version
    ET.SubElement(item, "link").text = release_url
    ET.SubElement(item, sparkle("version")).text = build
    ET.SubElement(item, sparkle("shortVersionString")).text = version
    minimum_os = str(info.get("LSMinimumSystemVersion", "14.0"))
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", minimum_os):
        raise ValueError("LSMinimumSystemVersion is invalid.")
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = minimum_os + (".0" if minimum_os.count(".") == 1 else "")
    ET.SubElement(item, sparkle("hardwareRequirements")).text = "arm64"
    ET.SubElement(item, "pubDate").text = format_datetime(published or datetime.now(timezone.utc), usegmt=True)
    ET.SubElement(item, "description").text = notes
    ET.SubElement(item, "enclosure", {
        "url": download_url,
        "length": str(archive_size),
        "type": "application/octet-stream",
        sparkle("edSignature"): signature,
    })
    ET.indent(root, space="  ")
    return ET.ElementTree(root)


def run_tool(arguments):
    result = subprocess.run([str(argument) for argument in arguments], check=True, text=True, capture_output=True)
    return result.stdout.strip()


def validate_archive(archive_path, info):
    with zipfile.ZipFile(archive_path) as archive:
        archived_info = plistlib.loads(archive.read("Mac Status.app/Contents/Info.plist"))
    for field in ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "SUPublicEDKey", "SUFeedURL"]:
        if archived_info.get(field) != info.get(field):
            raise ValueError("The ZIP archive does not match the application metadata: " + field)


def main():
    project = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=project / "build/Mac Status.app")
    parser.add_argument("--archive", type=Path, default=project / "build/Mac-Status.zip")
    parser.add_argument("--output", type=Path, default=project / "build/appcast.xml")
    parser.add_argument("--signer", type=Path, default=project / ".build/artifacts/sparkle/Sparkle/bin/sign_update")
    parser.add_argument("--account", default=KEYCHAIN_ACCOUNT)
    parser.add_argument("--public-key-file", type=Path, default=project / "config/updater-public-key.txt")
    parser.add_argument("--notes-file", type=Path)
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    validate_info(info)
    validate_archive(args.archive, info)
    # A signature verified with another account's key is insufficient: it must
    # match the public key shipped in the application's Info.plist.
    signing_public_key = run_tool([args.signer.with_name("generate_keys"), "--account", args.account, "-p"])
    tracked_public_key = checked_base64(args.public_key_file.read_text().strip(), 32, "Tracked public key")
    if signing_public_key != info["SUPublicEDKey"] or signing_public_key != tracked_public_key:
        raise ValueError("The Keychain signing key, tracked public key, and application's SUPublicEDKey must match.")
    signature = run_tool([args.signer, "--account", args.account, "-p", args.archive])
    checked_base64(signature, 64, "Archive signature")
    run_tool([args.signer, "--account", args.account, "--verify", args.archive, signature])
    notes = args.notes_file.read_text() if args.notes_file else "Mac Status의 최신 개선 사항과 오류 수정이 포함되어 있습니다."
    tree = build_appcast(info, args.archive.name, args.archive.stat().st_size, signature, notes)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".appcast-", suffix=".xml", dir=args.output.parent, delete=False) as file:
            temporary = Path(file.name)
        tree.write(temporary, encoding="utf-8", xml_declaration=True)
        run_tool([args.signer, "--account", args.account, temporary])
        run_tool([args.signer, "--account", args.account, "--verify", temporary])
        temporary.replace(args.output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print("서명된 업데이트 피드 생성 완료: " + str(args.output))


if __name__ == "__main__":
    main()
