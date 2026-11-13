"""Source delivery must never silently omit local work (#87)."""
import shutil
import os
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        # Hooks export repository-local GIT_* variables. Never let fixture git commands touch the caller's repo.
        self.env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        (self.repo / 'scripts').mkdir()
        (self.repo / 'handoff').mkdir()
        for name in ('package.sh', 'check-voice-data.sh'):
            shutil.copy2(ROOT / 'scripts' / name, self.repo / 'scripts' / name)
        for name in ('INSTALLA.command', 'LISEZMOI.md', 'LEIAME.md', 'START-PROMPT.md'):
            (self.repo / 'handoff' / name).write_text('handoff fixture\n')
        (self.repo / '.gitignore').write_text('dist/\n')
        (self.repo / 'source.swift').write_text('// committed source\n')
        self.git('init', '-q')
        self.git('add', '.')
        self.git('-c', 'user.name=Package Test', '-c', 'user.email=test@example.invalid',
                 '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'fixture')

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repo, env=self.env, check=True, capture_output=True, text=True)

    def package(self):
        return subprocess.run(['bash', 'scripts/package.sh'], cwd=self.repo, env=self.env, capture_output=True, text=True)

    def test_clean_commit_packages_source_and_launcher(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(result.stdout.strip()) as archive:
            names = archive.namelist()
            self.assertTrue(any(n.endswith('/INSTALLA.command') for n in names))
            self.assertTrue(any(n.endswith('/regista/source.swift') for n in names))
            snapshot = next(n for n in names if n.endswith('/regista/SNAPSHOT'))
            self.assertIn(self.git('rev-parse', 'HEAD').stdout.strip(), archive.read(snapshot).decode())
        self.assertEqual(self.package().returncode, 0, 'ignored dist output must not block packaging')

    def test_modified_source_refuses_package(self):
        (self.repo / 'source.swift').write_text('// local change\n')
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('package refused', result.stderr)
        self.assertFalse((self.repo / 'dist').exists())

    def test_untracked_source_refuses_package(self):
        self.git('config', 'status.showUntrackedFiles', 'no')
        (self.repo / 'new.swift').write_text('// new file\n')
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('package refused', result.stderr)


if __name__ == '__main__':
    unittest.main()
