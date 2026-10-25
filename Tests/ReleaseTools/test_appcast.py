"""Metadata tests do not access the Keychain, activate apps, or publish files."""

import base64
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile


PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("make_appcast", PROJECT / "scripts/make-appcast.py")
APPCAST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APPCAST)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.info = {
            "CFBundleIdentifier": "com.kwg.macstatus",
            "CFBundleShortVersionString": "0.7.0",
            "CFBundleVersion": "34",
            "LSMinimumSystemVersion": "14.0",
            "SUFeedURL": APPCAST.FEED_URL,
            "SUPublicEDKey": base64.b64encode(bytes(32)).decode(),
            "SURequireSignedFeed": True,
            "SUVerifyUpdateBeforeExtraction": True,
        }
        self.signature = base64.b64encode(bytes(64)).decode()

    def testVersionedArchiveAndSecurityMetadata(self):
        tree = APPCAST.build_appcast(self.info, "Mac-Status.zip", 1234, self.signature, "업데이트 안내")
        item = tree.getroot().find("channel/item")
        self.assertEqual(item.find(APPCAST.sparkle("version")).text, "34")
        self.assertEqual(item.find(APPCAST.sparkle("shortVersionString")).text, "0.7.0")
        self.assertEqual(item.find(APPCAST.sparkle("minimumSystemVersion")).text, "14.0.0")
        self.assertEqual(item.find(APPCAST.sparkle("hardwareRequirements")).text, "arm64")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.attrib["url"], "https://github.com/WongyuKoh/Mac-Status/releases/download/v0.7.0/Mac-Status.zip")
        self.assertEqual(enclosure.attrib["length"], "1234")
        self.assertEqual(enclosure.attrib[APPCAST.sparkle("edSignature")], self.signature)

    def testWrongApplicationFeedAndDisabledValidationAreRejected(self):
        for field, invalid in [
            ("CFBundleIdentifier", "other.application"),
            ("SUFeedURL", "http://example.com/appcast.xml"),
            ("SUPublicEDKey", "not-a-public-key"),
            ("SURequireSignedFeed", False),
            ("SUVerifyUpdateBeforeExtraction", False),
            ("CFBundleVersion", "0"),
            ("CFBundleVersion", "latest"),
            ("CFBundleShortVersionString", "latest"),
        ]:
            with self.subTest(field=field, invalid=invalid):
                info = dict(self.info)
                info[field] = invalid
                with self.assertRaises(ValueError):
                    APPCAST.build_appcast(info, "Mac-Status.zip", 1234, self.signature, "")

    def testEmptyArchiveAndMalformedSignatureAreRejected(self):
        with self.assertRaises(ValueError):
            APPCAST.build_appcast(self.info, "Mac-Status.zip", 0, self.signature, "")
        for invalid in ["invalid", base64.b64encode(bytes(32)).decode()]:
            with self.assertRaises(ValueError):
                APPCAST.build_appcast(self.info, "Mac-Status.zip", 1234, invalid, "")

    def testNotesAndFilenameCannotInjectXmlOrUrlStructure(self):
        notes = "설명 <태그> & 따옴표 \" 유지"
        timestamp = datetime(2026, 10, 26, tzinfo=timezone.utc)
        tree = APPCAST.build_appcast(self.info, "Mac Status.zip?other=1", 1234, self.signature, notes, timestamp)
        parsed = ET.fromstring(ET.tostring(tree.getroot(), encoding="utf-8"))
        item = parsed.find("channel/item")
        self.assertEqual(item.find("description").text, notes)
        self.assertEqual(item.find("pubDate").text, "Mon, 26 Oct 2026 00:00:00 GMT")
        self.assertTrue(item.find("enclosure").attrib["url"].endswith("Mac%20Status.zip%3Fother%3D1"))

    def testArchiveMustContainTheSameBuildAndPublicKey(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Mac-Status.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Mac Status.app/Contents/Info.plist", plistlib.dumps(self.info))
            APPCAST.validate_archive(path, self.info)
            for field in ["CFBundleVersion", "SUPublicEDKey"]:
                stale = dict(self.info)
                stale[field] = "stale"
                with self.assertRaises(ValueError):
                    APPCAST.validate_archive(path, stale)


if __name__ == "__main__":
    unittest.main()
