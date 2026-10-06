import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

spec = importlib.util.spec_from_file_location('validator', Path(__file__).with_name('validate-appcast.py'))
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class FeedValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        directory = Path(self.temp.name)
        self.archive = directory/'PetCompanion.dmg'
        self.archive.write_bytes(b'original signed archive')
        key = Ed25519PrivateKey.generate()
        signature = base64.b64encode(key.sign(self.archive.read_bytes())).decode()
        public = base64.b64encode(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()
        self.plist = directory/'Info.plist'
        self.plist.write_bytes(plistlib.dumps({'CFBundleVersion':'42', 'CFBundleShortVersionString':'1.2.3',
            'LSMinimumSystemVersion':'14.0', 'SUPublicEDKey':public,
            'SUFeedURL':'https://update.pet.rxlab.app/appcast.xml'}))
        self.prefix = 'https://github.com/sirily11/pet-companion/releases/download/v1.2.3/'
        self.feed = directory/'appcast.xml'
        self.feed.write_text(f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:version>42</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<sparkle:releaseNotesLink>https://update.pet.rxlab.app/PetCompanion.html</sparkle:releaseNotesLink>
<enclosure url="{self.prefix}PetCompanion.dmg" length="{self.archive.stat().st_size}" sparkle:edSignature="{signature}"/>
</item></channel></rss>''')
        self.env = patch.dict(os.environ, VERSION='v1.2.3', BUILD_NUMBER='42')
        self.env.start()
        self.addCleanup(self.env.stop)

    def validate(self):
        validator.validate(self.feed, self.archive, self.plist, self.prefix)

    def test_valid_feed(self):
        self.validate()

    def test_tampered_same_length_archive(self):
        self.archive.write_bytes(b'X'*self.archive.stat().st_size)
        with self.assertRaises(InvalidSignature): self.validate()

    def test_wrong_public_key(self):
        app = plistlib.loads(self.plist.read_bytes())
        app['SUPublicEDKey'] = base64.b64encode(Ed25519PrivateKey.generate().public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()
        self.plist.write_bytes(plistlib.dumps(app))
        with self.assertRaises(InvalidSignature): self.validate()

    def test_wrong_metadata(self):
        for old,new in [('>42<','>43<'), ('>1.2.3<','>1.2.4<'), ('>14.0<','>15.0<'),
                        ('PetCompanion.html','Other.html'), ('PetCompanion.dmg','Other.dmg')]:
            with self.subTest(old=old):
                original = self.feed.read_text()
                self.feed.write_text(original.replace(old,new))
                with self.assertRaises(AssertionError): self.validate()
                self.feed.write_text(original)

    def test_wrong_archive_length(self):
        self.archive.write_bytes(self.archive.read_bytes()+b'X')
        with self.assertRaises(AssertionError): self.validate()

    def test_empty_feed(self):
        self.feed.write_text('<rss><channel/></rss>')
        with self.assertRaises(AssertionError): self.validate()


if __name__ == '__main__': unittest.main()
