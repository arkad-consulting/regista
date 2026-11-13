#!/bin/bash
# Keeps internal names out of the public repository: refuses files that contain a word of a private deny-list, a
# private-organisation reference, a personal home path or a real e-mail address. Used by .githooks/pre-commit (staged
# files, as staged) next to check-voice-data.sh.
#
#   scripts/check-public.sh [--staged]   staged files (added, copied, modified, renamed), their staged content
#   scripts/check-public.sh --all        every tracked file of the working tree
#   scripts/check-public.sh --self-test  checks the checker on made-up files (no repository needed)
#
# The deny-list lives OUTSIDE the public repository — the list itself would leak what it protects: in the private
# companion checkout .arkad/ (git-ignored, its own private repository) when present, else
#   ${REGISTA_PRIVATE_WORDS:-$HOME/.config/regista/private-words}
# one case-insensitive Python regular expression per line (e.g. \bname\b); blank lines and lines starting with # are
# ignored. A missing file skips that part with one line saying so; the generic checks always run:
#   - the private GitHub organisation (its name is assembled below so this file does not match itself);
#   - a personal home folder: /Users/<name>/;
#   - e-mail addresses, except @example.com/.org/.net, reserved test domains (.invalid, .test, .example),
#     @anthropic.com and noreply addresses.
# Internal material is refused by path, whatever it contains: .arkad/ (the private companion), AGENTS.md / CLAUDE.md,
# .agents/ and .claude/ (development agents' rules and skills), specs/ (internal design notes).
# Binary files are skipped.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -n "${REGISTA_PRIVATE_WORDS:-}" ]; then WORDS="$REGISTA_PRIVATE_WORDS"
elif [ -f .arkad/private-words ]; then WORDS=.arkad/private-words
else WORDS="$HOME/.config/regista/private-words"; fi
MODE="${1:---staged}"
case "$MODE" in --staged|--all|--self-test) ;; *) echo "usage: scripts/check-public.sh [--staged|--all|--self-test]" >&2; exit 2 ;; esac
exec python3 -I - "$MODE" "$WORDS" <<'PY'
import os, re, subprocess, sys, tempfile

mode, words_path = sys.argv[1], sys.argv[2]

ORG = "Arkad" + "-" + "Agency"
GENERIC = [
    ("private GitHub organisation", re.compile(re.escape(ORG), re.I)),
    ("personal home path", re.compile(r"/Users/[A-Za-z0-9._-]+/")),
]
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})")
ALLOWED_DOMAIN = re.compile(r"(^|\.)(example\.(com|org|net)|anthropic\.com)$|\.(invalid|test|example)$|^(invalid|test|example)$", re.I)

PRIVATE_PATHS = re.compile(r"^(\.arkad|\.agents|\.claude|specs)(/|$)|(^|/)(AGENTS|CLAUDE)\.md$")

def path_problem(name):
    """Why a file must not be in the public repository because of where it is, or None."""
    return "internal material (development rules, agents, design notes)" if PRIVATE_PATHS.search(name) else None

def load_words(path):
    """The private deny-list: [(pattern text, compiled)], or None when the file is missing."""
    if not os.path.isfile(path):
        return None
    out = []
    for n, line in enumerate(open(path, encoding="utf-8").read().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            out.append((line, re.compile(line, re.I)))
        except re.error as e:
            sys.exit(f"check-public: {path}:{n}: bad regular expression {line!r}: {e}")
    return out

def problems(name, text, words):
    """Every (line number, reason) of one file's text. A deny-list hit names the list's line number, not the word:
    the output may end up in a public CI log."""
    found = []
    for n, line in enumerate(text.split("\n"), 1):
        for reason, rx in GENERIC:
            if rx.search(line):
                found.append((n, reason))
        for m in EMAIL.finditer(line):
            local, domain = m.group(0).split("@", 1)[0], m.group(1)
            if ALLOWED_DOMAIN.search(domain) or local.lower().startswith("noreply") or "noreply" in domain.lower():
                continue
            found.append((n, "e-mail address"))
        for i, (_, rx) in enumerate(words or [], 1):
            if rx.search(line):
                found.append((n, f"private word (deny-list entry {i})"))
    return found

def is_binary(data):
    return b"\0" in data[:8192]

def files_and_contents():
    git = lambda *a: subprocess.check_output(["git", *a])
    if mode == "--all":
        names = [n for n in git("ls-files", "-z").decode().split("\0") if n]
        for n in names:
            if os.path.isfile(n) and not os.path.islink(n):
                yield n, open(n, "rb").read()
    else:
        names = [n for n in git("diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR").decode().split("\0") if n]
        for n in names:
            yield n, git("show", f":{n}")

def run(words):
    if words is None:
        print(f"check-public: no private word list at {words_path}: deny-list check skipped (generic checks still run)")
    bad = 0
    scanned = 0
    for name, data in files_and_contents():
        reason = path_problem(name)
        if reason:
            print(f"{name}: {reason}", file=sys.stderr)
            bad += 1
            continue
        if is_binary(data):
            continue
        scanned += 1
        for n, reason in problems(name, data.decode("utf-8", errors="replace"), words):
            print(f"{name}:{n}: {reason}", file=sys.stderr)
            bad += 1
    if bad:
        print(f"check-public: {bad} problem(s): internal names, personal paths or e-mail addresses must not be in the public repository", file=sys.stderr)
        return 1
    print(f"check-public: {scanned} file(s) clean ({'all tracked' if mode == '--all' else 'staged'})")
    return 0

def self_test():
    with tempfile.TemporaryDirectory() as d:
        lst = os.path.join(d, "words")
        open(lst, "w").write("# comment\n\n\\bzorblax\\b\nsecret-repo\n")
        words = load_words(lst)
        assert len(words) == 2, words
        assert load_words(os.path.join(d, "missing")) is None
    HOME = "/" + "Users/"   # assembled so this file does not match itself
    cases = [
        ("clean text", "Regista by Arkad, see arkad-consulting.com; write to ada@example.com.", 0),
        ("test domains", "user.email=test@example.invalid and noreply@anthropic.com and x@foo.test", 0),
        ("noreply", "Co-Authored-By: Claude <noreply@anthropic.com>, 12345+bot@users.noreply.github.com", 0),
        ("package versions", "npx hyperframes@0.8.150, react@18.3.1, registry.npmjs.org/@scope/pkg", 0),
        ("word boundary", "monotonic zorblaxes are fine", 0),
        ("deny-list word", "made by Zorblax yesterday", 1),
        ("deny-list fragment", "clone the secret-repo first", 1),
        ("private org", "git clone https://github.com/" + ORG + "/regista.git", 1),
        ("private org, lower case", "github.com/" + ORG.lower() + "/x", 1),
        ("home path", "open " + HOME + "someone/Movies/take.mov", 1),
        ("e-mail", "contact: someone@" + "company.fr", 1),
        ("two problems on two lines", HOME + "a/x\nb@" + "c.io", 2),
    ]
    failures = 0
    for label, text, expected in cases:
        got = len(problems("t.txt", text, words))
        if got != expected:
            failures += 1
            print(f"self-test FAILED: {label}: {got} problem(s), expected {expected}", file=sys.stderr)
    assert problems("t", "a@b.example", None) == []
    for name, refused in [(".arkad/project.yml", True), ("AGENTS.md", True), ("Sources/CLAUDE.md", True),
                          (".claude/skills/x/SKILL.md", True), (".agents/skills/y.md", True), ("specs/a.md", True),
                          ("handoff/skill/regista/SKILL.md", False), ("docs/architecture.md", False),
                          ("Sources/RegistaCore/Specs.swift", False), ("README.md", False)]:
        if (path_problem(name) is not None) != refused:
            failures += 1
            print(f"self-test FAILED: path {name}: refused={not refused}", file=sys.stderr)
    if failures:
        return 1
    print(f"check-public self-test: {len(cases)} cases passed")
    return 0

if mode == "--self-test":
    sys.exit(self_test())
sys.exit(run(load_words(words_path)))
PY
