#!/usr/bin/env python3
"""Exercise the real preflight functions with a harmless installer, never Homebrew."""
import hashlib
import os
from pathlib import Path
import pty
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALL = (ROOT / "scripts/install.sh").read_text()
FUNCTIONS = INSTALL[INSTALL.index("find_brew() {"):INSTALL.index("\nresolve_tier() {")]
ASK = INSTALL[INSTALL.index("ask() {"):INSTALL.index("\nwants() {")]


class HomebrewBootstrapTests(unittest.TestCase):
    def run_case(self, *, terminal=True, answer="y", yes=0, existing=False,
                 in_path=False, corrupt=False, download_fail=False, install_fail=False,
                 no_brew_after=False):
        with tempfile.TemporaryDirectory(prefix="regista-brew-test-") as folder:
            tmp = Path(folder)
            bindir = tmp / "bin"
            bindir.mkdir()
            brew = bindir / "brew"
            brew_script = '#!/bin/bash\nprintf "%s\\n" "$TEST_PREFIX"\n'
            payload = tmp / "installer.sh"
            payload.write_text('echo executed > "$TEST_EXECUTED"\n' +
                               ('exit 7\n' if install_fail else
                                ('true\n' if no_brew_after else
                                 'cp "$TEST_BREW_SOURCE" "$TEST_BREW"\nchmod +x "$TEST_BREW"\n')))
            brew_source = tmp / "brew-source"
            brew_source.write_text(brew_script)
            if existing:
                brew.write_text(brew_script)
                brew.chmod(0o755)
            path = (str(bindir) + ":" if in_path else "") + "/usr/bin:/bin:/usr/sbin:/sbin"
            env = dict(os.environ, PATH=path, REGISTA_LANG="en", TEST_PREFIX=str(tmp),
                       TEST_BREW=str(brew), TEST_BREW_SOURCE=str(brew_source),
                       TEST_PAYLOAD=str(payload), TEST_EXECUTED=str(tmp / "executed"))
            # Change only the standard-prefix lookup so the developer's real Homebrew is invisible.
            functions = FUNCTIONS.replace("/opt/homebrew/bin/brew", str(brew))
            shell = '''set -euo pipefail
. "$1/scripts/i18n.sh"
YES="$2"
die() { echo "$*" >&2; exit 1; }
warn() { echo "$*"; }
ok() { echo "$*"; }
sha_ok() { [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$2" ]; }
curl() {
  while [ "$1" != -o ]; do shift; done
  shift
''' + ('return 22\n' if download_fail else 'cp "$TEST_PAYLOAD" "$1"\n') + '''}
BREW_INSTALL_URL=https://example.invalid/never-contacted
BREW_INSTALL_SHA="''' + ("0" * 64 if corrupt else hashlib.sha256(payload.read_bytes()).hexdigest()) + '"\n' + ASK + "\n" + functions + '\npreflight_brew\nprintf "RESULT=%s\\n" "$BREW_BIN"\n'
            driver = tmp / "driver.sh"
            driver.write_text(shell)
            if terminal:
                master, slave = pty.openpty()
                try:
                    process = subprocess.Popen(["/bin/bash", str(driver), str(ROOT), str(yes)],
                                               stdin=slave, stdout=subprocess.PIPE,
                                               stderr=subprocess.STDOUT, env=env)
                    os.close(slave)
                    os.write(master, (answer + "\n").encode())
                    output = process.communicate(timeout=10)[0].decode()
                finally:
                    os.close(master)
            else:
                process = subprocess.Popen(["/bin/bash", str(driver), str(ROOT), str(yes)],
                                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT, env=env)
                output = process.communicate(timeout=10)[0].decode()
            return process.returncode, output, (tmp / "executed").exists()

    def test_existing_homebrew_on_path(self):
        code, output, executed = self.run_case(existing=True, in_path=True, terminal=False)
        self.assertEqual(code, 0, output)
        self.assertFalse(executed)
        self.assertIn("RESULT=", output)

    def test_existing_homebrew_outside_path(self):
        code, output, executed = self.run_case(existing=True, terminal=False)
        self.assertEqual(code, 0, output)
        self.assertFalse(executed)

    def test_interactive_install_resumes_and_finds_prefix(self):
        code, output, executed = self.run_case()
        self.assertEqual(code, 0, output)
        self.assertTrue(executed)
        self.assertIn("RESULT=", output)
        self.assertIn("administrator password", output)

    def test_yes_still_needs_terminal(self):
        code, output, executed = self.run_case(terminal=False, yes=1)
        self.assertNotEqual(code, 0)
        self.assertIn("Open Terminal", output)
        self.assertFalse(executed)

    def test_yes_accepts_regista_question_in_terminal(self):
        code, output, executed = self.run_case(yes=1)
        self.assertEqual(code, 0, output)
        self.assertTrue(executed)

    def test_decline_does_not_execute(self):
        code, output, executed = self.run_case(answer="n")
        self.assertNotEqual(code, 0)
        self.assertIn("https://brew.sh", output)
        self.assertFalse(executed)

    def test_bad_hash_never_executes(self):
        code, output, executed = self.run_case(corrupt=True)
        self.assertNotEqual(code, 0)
        self.assertIn("SHA256 mismatch", output)
        self.assertFalse(executed)

    def test_download_failure_never_executes(self):
        code, output, executed = self.run_case(download_fail=True)
        self.assertNotEqual(code, 0)
        self.assertIn("did not finish", output)
        self.assertFalse(executed)

    def test_install_failure_stops(self):
        code, output, executed = self.run_case(install_fail=True)
        self.assertNotEqual(code, 0)
        self.assertIn("did not finish", output)
        self.assertTrue(executed)
        self.assertNotIn("RESULT=", output)

    def test_success_without_brew_stops(self):
        code, output, executed = self.run_case(no_brew_after=True)
        self.assertNotEqual(code, 0)
        self.assertIn("did not finish", output)
        self.assertTrue(executed)


if __name__ == "__main__":
    unittest.main()
