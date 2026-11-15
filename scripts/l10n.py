#!/usr/bin/env python3
"""Checks the app's words (L0 #48) against Resources/Localization/<lang>.lproj/Localizable.strings for each language in
LANGS (it, en, fr, pt).

The scheme is in Sources/Regista/App/Words.swift: keys are the Italian text, or `area.meaning` where one Italian text has
two meanings; interpolated texts are format keys (`loc("%@ clip", n)`); data goes through `Text(verbatim:)`.

Green only when, for Sources/Regista:
  1. every key the code uses is in every table of LANGS: the literals of the lookups (loc, lookup, Text, Button, Label, help,
     tip, …), the texts passed to the custom controls (title:, subtitle:, label:, detail:, placeholder:, …, segment
     tuples), and every other literal that reads as UI text (a space, a capital or an accented letter);
  2. no literal that reads as UI text is interpolated (`"Clip \\(n)"` bypasses the table: use a format key);
  3. no `Text(<expression>)` without `verbatim:` (a String drawn that way is silently verbatim: say `Text(verbatim:)` for
     data, `Text(loc(…))` for a key) and no `Text(verbatim: "<words>")`;
  4. the tables have the same keys, every value is non-empty, each translation of a format key has the key's
     placeholders, a semantic key has a real Italian value, and a translated text is never another key with a different
     translation (so `loc` may run twice on a text: Words.swift);
  5. the engine manifest's user-facing phrases (scripts/engines.manifest.json: names, prose licences,
     unlocks, install steps) are in every
     table too, keyed by their English text (Impostazioni › Motori looks them up, #84);
  6. the editing rules' phrases (every `rulePhrase("…")` in Sources/RegistaCore/Rules: sheet and check titles, check
     messages, fixes, header problems) are in every table too, keyed by their English text (#31).
Not UI, so not checked: lines marked `// l10n-ignore`, blocks between `// l10n-ignore-begin` and `// l10n-ignore-end`
(sample data for renders, engine replies to agents), Debug/, command ids, SF Symbol names, user-defaults keys, and
literals that are only format specifiers, numbers and units.

usage: python3 -I scripts/l10n.py [--todo it|en|fr|pt]   (--todo prints the keys one table lacks as JSON, with the
       English text when there is one, for translating)"""
import glob, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The UI languages that must be complete. A language declared but not translated yet goes in PENDING until its table is
# complete (the app shows English wherever a language has no table).
LANGS = ['it', 'en', 'fr', 'pt']
PENDING = []
SRC = os.path.join(ROOT, 'Sources/Regista')

ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
LIT = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
SEMANTIC = re.compile(r'^[a-z][a-zA-Z]*(\.[a-zA-Z][a-zA-Z0-9]*)+$')
PLACEHOLDER = re.compile(r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXfFeEgGcs%]')
# A lookup, a SwiftUI initialiser that looks its literal up, or a control parameter that takes a key.
CALL = re.compile(r'(?<![A-Za-z_])(Text|Button|Label|Toggle|Picker|Section|Menu|TextField|LabeledContent|help|navigationTitle|'
                  r'DisclosureGroup|Stepper|ProgressView|alert|confirmationDialog|CommandMenu|SecureField|Link|GroupBox|'
                  r'ContentUnavailableView|accessibilityLabel|Tab|CommandGroup|loc|lookup|tip|SectionLabel|LocalizedStringKey)'
                  r'\(\s*"((?:[^"\\]|\\.)*)"')
PARAM = re.compile(r'(?<![A-Za-z_])(title|subtitle|label|detail|help|tip|placeholder|empty|text|caption|low|high|line|hint|'
                   r'reason|note|message|action|summary)\s*:\s*"((?:[^"\\]|\\.)*)"')
TUPLE = re.compile(r'\(\s*\.?[A-Za-z_][A-Za-z0-9_.]*\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)')
# Contexts whose literal is an identifier, not words.
NOT_UI_BEFORE = re.compile(r'(systemName:|forKey:|forKeyPath:|named:|suiteName:|withExtension:|ofType:|subdirectory:|'
                           r'\.run\(|\.perform\(|hasPrefix\(|hasSuffix\(|contains\(|'
                           r'appendingPathComponent\(|URL\(fileURLWithPath:|fatalError\(|precondition\(|assert\(|print\(|NSLog\(|'
                           r'CommandError\([^,]*,|Notification\.Name\(|NSImage\(named:|Image\(|case |== |!= |'
                           r'UTType\(|identifier:|NSUserInterfaceItemIdentifier\(|dateFormat = |\.string\(|split\(separator:|'
                           r'replacingOccurrences\(of:|components\(separatedBy:|\.custom\(|family:|(?<=[A-Za-z0-9_)\]?!])\[)\s*$')
UNITS = re.compile(r'\b(LUFS|dBTP|dB|px|fps|min|ms|s|h|x|pt|GB|MB|kB|KB|TP|M|S|I|LRA|Hz|kHz|kbps|Mbps)\b')


def unescape(s):
    return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), s)


def escape(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')


def read_table(lang):
    out, path = {}, os.path.join(ROOT, f'Resources/Localization/{lang}.lproj/Localizable.strings')
    if os.path.exists(path):
        for line in open(path, encoding='utf-8'):
            m = ENTRY.match(line.strip())
            if m:
                out[unescape(m.group(1))] = unescape(m.group(2))
    return out


def letters(s):
    """What is left of a literal once interpolations, format specifiers and units are gone."""
    t = re.sub(r'\\\((?:[^()]|\([^()]*\))*\)', ' ', s)
    return UNITS.sub(' ', PLACEHOLDER.sub(' ', t))


def reads_as_words(s):
    """A literal a person would read: letters left once format specifiers, interpolations, numbers and units are gone,
    and a space, a capital or an accented letter (identifiers, ids and paths have none of these)."""
    if not re.search(r'[A-Za-zÀ-ÿ]{2,}', letters(s)):
        return False
    if re.fullmatch(r'[a-z0-9_.\-/:#]+', s):
        return False
    return bool(re.search(r'\s|^[A-ZÀ-Ý]|[À-ÿ]|…', s))


def strip_comment(line):
    """(code, comment): the line split at a // that is not inside a string literal."""
    i, q = 0, False
    while i < len(line):
        c = line[i]
        if c == '\\' and q:
            i += 2
            continue
        if c == '"':
            q = not q
        elif not q and line.startswith('//', i):
            return line[:i], line[i:]
        i += 1
    return line, ''


def scan():
    keys, problems = {}, []
    files = sorted(f for f in glob.glob(os.path.join(SRC, '**/*.swift'), recursive=True) if '/Debug/' not in f)
    for f in files:
        rel = os.path.relpath(f, SRC)
        ignoring = False
        for n, raw in enumerate(open(f, encoding='utf-8'), 1):
            code, comment = strip_comment(raw.rstrip('\n'))
            s = code.strip()
            if 'l10n-ignore-begin' in comment:
                ignoring = True
            if 'l10n-ignore-end' in comment:
                ignoring = False
                continue
            if ignoring or 'l10n-ignore' in comment or not s or s.startswith('*'):
                continue
            where = f'{rel}:{n}'
            interp = f'{where}: interpolated text "%s": use a format key, loc("…%%@…", value)'
            # Keys from lookups and control parameters (any literal with a word, even one word in lower case).
            looked = set()
            for rx in (CALL, PARAM, TUPLE):
                for m in rx.finditer(code):
                    g = m.lastindex
                    lit = m.group(g)
                    looked.add(m.start(g))
                    if '\\(' in lit:
                        if reads_as_words(lit) or re.search(r'[A-Za-zÀ-ÿ]{3,}', letters(lit)):
                            problems.append(interp % lit[:70])
                    elif rx is TUPLE and not reads_as_words(lit):
                        continue          # (value, "id") pairs: an identifier, not words
                    elif re.search(r'[A-Za-zÀ-ÿ]{2,}', letters(lit)):
                        keys.setdefault(unescape(lit), where)
            # Every other literal that reads as words.
            for m in LIT.finditer(code):
                if m.start(1) in looked:
                    continue
                lit = m.group(1)
                before = code[:m.start()]
                if NOT_UI_BEFORE.search(before) or code[m.end():m.end() + 1] == ':' or not reads_as_words(lit):
                    continue
                if re.search(r'Text\(verbatim:\s*$', before):
                    problems.append(f'{where}: Text(verbatim: "{lit[:60]}") draws words without the lookup: Text(loc("…"))')
                elif '\\(' in lit:
                    problems.append(interp % lit[:70])
                else:
                    keys.setdefault(unescape(lit), where)
            # Text(<expression>) without verbatim:.
            if re.search(r'(?<![A-Za-z_.])Text\(\s*(?!verbatim:|"|loc\(|LocalizedStringKey\(|\)|[A-Za-z_.]+(?:\([^()]*\))?\s*,\s*(?:format|style):)', code):
                problems.append(f'{where}: Text(<expression>) draws a String verbatim without saying so: '
                                f'Text(verbatim: …) for data, Text(loc(…)) for a key')
    return keys, problems


def manifest_phrases():
    """The engine manifest's user-facing phrases, looked up by Impostazioni › Motori (#84): names, licences written as
    prose, what each engine unlocks and the manual install steps."""
    data = json.load(open(os.path.join(ROOT, 'scripts/engines.manifest.json'), encoding='utf-8'))
    out = {}
    for e in data.get('engines', []):
        out[e['name']] = f'engines.manifest.json {e.get("id")} name'
        if re.search(r'\b(?!AND\b|OR\b|or\b|later\b|only\b)[a-z]{3,}', e.get('licence', '')):   # prose, not an SPDX id
            out[e['licence']] = f'engines.manifest.json {e.get("id")} licence'
        for u in e.get('unlocks') or []:
            out[u] = f'engines.manifest.json {e.get("id")} unlocks'
        for st in (e.get('install') or {}).get('steps') or []:
            out[st] = f'engines.manifest.json {e.get("id")} install.steps'
    return out


def rule_phrases():
    """The editing rules' phrases (#31): the English texts the engine returns as message keys for the interface."""
    out = {}
    for f in sorted(glob.glob(os.path.join(ROOT, 'Sources/RegistaCore/Rules/*.swift'))):
        for n, line in enumerate(open(f, encoding='utf-8'), 1):
            for m in re.finditer(r'rulePhrase\(\s*"((?:[^"\\]|\\.)*)"', line):
                out.setdefault(unescape(m.group(1)), f'{os.path.relpath(f, ROOT)}:{n}')
    return out


def placeholders(s):
    return sorted(re.sub(r'\d+\$', '', p) for p in PLACEHOLDER.findall(s) if p != '%%')


def main():
    tables = {l: read_table(l) for l in LANGS}
    keys, problems = scan()
    for k, w in manifest_phrases().items():
        keys.setdefault(k, w)
    for k, w in rule_phrases().items():
        keys.setdefault(k, w)
    if '--todo' in sys.argv:
        lang = sys.argv[sys.argv.index('--todo') + 1]
        every = set(keys) | set().union(*(set(t) for t in tables.values()))
        print(json.dumps({k: tables['en'].get(k, k) for k in sorted(every) if k not in tables[lang]}, ensure_ascii=False, indent=1))
        return 0
    errors = list(problems)
    every = set().union(*(set(t) for t in tables.values()))
    for lang in LANGS:
        t = tables[lang]
        for k in sorted(k for k in keys if k not in t):
            errors.append(f'{lang}: missing "{escape(k)}"  ({keys[k]})')
        for k in sorted(every - set(t) - set(keys)):
            errors.append(f'{lang}: missing "{escape(k)}" (in another table)')
        for k, v in t.items():
            source = tables['it'].get(k, k) if SEMANTIC.match(k) else k
            if not v.strip():
                errors.append(f'{lang}: empty value for "{escape(k)}"')
            elif placeholders(source) != placeholders(v):
                errors.append(f'{lang}: the placeholders of "{escape(k)}" differ in "{escape(v)}"')
            if SEMANTIC.match(k) and lang == 'it' and v == k and not keys.get(k, '').startswith('engines.manifest'):
                errors.append(f'it: the semantic key "{k}" needs its Italian text')
            if v != k and v in t and t[v] != v:
                errors.append(f'{lang}: "{escape(k)}" translates to "{escape(v)}", another key (= "{escape(t[v])}"): '
                              f'loc would not be idempotent')
    unused = sorted(set(tables['it']) - set(keys))
    print(f'{len(keys)} keys used in the sources and the engine manifest; table entries: ' +
          ', '.join(f'{l} {len(tables[l])}' for l in LANGS) + f'; {len(unused)} entries not seen in the sources (keys built at run time)')
    for l in PENDING:
        print(f'{l}: not yet translated (PENDING in scripts/l10n.py): {len(read_table(l))} entries, not checked')
    for e in errors:
        print('  ' + e)
    print(f'{len(errors)} problems' if errors else 'complete: ' + ', '.join(LANGS))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
