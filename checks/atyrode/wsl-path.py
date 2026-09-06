"""Exercise service-style Windows PATH discovery without borrowing a login PATH."""

import importlib.machinery
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("wsl_path", sys.argv.pop(1))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


class WindowsPath(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.mounts = self.root / "windows mounts"
        self.cmd = self.mounts / "d/Windows/System32/cmd.exe"
        self.cmd.parent.mkdir(parents=True)
        self.cmd.write_text(f"#!{sys.executable}\n" + '''import sys
assert sys.argv[1:] == ['/d','/u','/c','path']
sys.stdout.buffer.write('PATH=D:\\\\Windows\\\\System32;D:\\\\Users\\\\René Example\\\\Apps;D:\\\\Windows\\\\System32\\r\\n'.encode('utf-16-le'))
''')
        self.cmd.chmod(0o755)
        converter = self.bin / "wslpath"
        converter.write_text(f"#!{sys.executable}\n" + '''import sys
assert sys.argv[1] == '-u'
value=sys.argv[2]
print('/windows/'+value[0].lower()+value[2:].replace('\\\\','/'))
''')
        converter.chmod(0o755)
        environment = dict(os.environ, PATH=str(self.bin))
        environment.pop("WSL_INTEROP", None)
        environment.pop("WSLPATH", None)
        self.environment = patch.dict(os.environ, environment, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_nondefault_mount_and_unicode_paths_without_login_context(self):
        actual = module.windows_path(str(self.mounts))
        self.assertEqual(actual.split(":"), ["/windows/d/Windows/System32", "/windows/d/Users/René Example/Apps"])
        self.assertNotIn("WSL_INTEROP", os.environ)

    def test_failed_windows_execution_does_not_claim_a_recovered_path(self):
        self.cmd.write_text(f"#!{sys.executable}\nraise SystemExit(1)\n")
        with self.assertRaises(module.subprocess.CalledProcessError):
            module.windows_path(str(self.mounts))


unittest.main()
