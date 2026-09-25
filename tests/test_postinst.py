"""Run the actual package postinst body in modern, legacy and offline flows."""
import os
import io
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tarfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHELL = os.environ.get('TEST_SHELL') or shutil.which('bash')

def shell_path(path):
    value = str(path).replace('\\', '/')
    if len(value) > 1 and value[1] == ':':
        value = '/' + value[0].lower() + value[2:]
    return value

class PostinstTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='.captcha-test-', dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.defaults = self.root / 'luci-xlnetacc'
        self.marker = self.root / 'calls'
        if os.environ.get('TEST_IPK'):
            with tarfile.open(os.environ['TEST_IPK']) as package:
                blobs = {m.name.removeprefix('./'): package.extractfile(m).read() for m in package if m.isfile()}
            with tarfile.open(fileobj=io.BytesIO(blobs['control.tar.gz'])) as control:
                scripts = {m.name.removeprefix('./'): control.extractfile(m).read() for m in control if m.isfile()}
            with tarfile.open(fileobj=io.BytesIO(blobs['data.tar.gz'])) as data:
                names = [m.name.removeprefix('./') for m in data if m.isfile()]
            self.assertIn('etc/uci-defaults/luci-xlnetacc', names)
            self.assertIn(b'default_postinst', scripts['postinst'])
            body = scripts['postinst-pkg'].decode('utf-8')
        else:
            makefile = (ROOT / 'Makefile').read_text(encoding='utf-8')
            body = re.search(r'define Package/\$\(PKG_NAME\)/postinst\n(.*?)\nendef', makefile, re.S)[1]
        self.body = body.replace('$$', '$').replace('/etc/uci-defaults/luci-xlnetacc', '"' + shell_path(self.defaults) + '"')

    def write_defaults(self):
        self.defaults.write_text('printf "initialized\\n" >> "$TEST_MARKER"\n', encoding='utf-8')

    def run_postinst(self, offline=False):
        env = os.environ.copy()
        env['TEST_MARKER'] = shell_path(self.marker)
        env['IPKG_INSTROOT'] = shell_path(self.root / 'image-root') if offline else ''
        result = subprocess.run([SHELL, '-c', self.body], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')

    def test_modern_installer_already_consumed_defaults(self):
        # default_postinst executes and removes uci-defaults before postinst-pkg.
        self.marker.write_text('initialized\n', encoding='utf-8')
        self.run_postinst()
        self.assertEqual(self.marker.read_text(), 'initialized\n')

    def test_legacy_installer_executes_defaults_once(self):
        self.write_defaults()
        self.run_postinst()
        self.assertFalse(self.defaults.exists())
        self.run_postinst()
        self.assertEqual(self.marker.read_text(), 'initialized\n')

    def test_image_build_defers_initialization(self):
        self.write_defaults()
        self.run_postinst(offline=True)
        self.assertTrue(self.defaults.exists())
        self.assertFalse(self.marker.exists())

if __name__ == '__main__':
    unittest.main()
