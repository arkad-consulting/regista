"""Text helpers for wx_align.py (Italian by default, French with lang="fr"; mirrors RegistaCore TextNorm.swift).
- numbers_to_words("9,2 su 10, nel 2025 più di 11.000") -> "nove virgola due su dieci, nel duemilaventicinque più di undicimila"
- numbers_to_words("9,2 sur 10 en 2025", "fr") -> "neuf virgule deux sur dix en deux mille vingt cinq"
  (wav2vec2 aligners have no digits in their vocabulary: WhisperX cannot time "9,2" unless it is spelled out;
  French words are joined with spaces, not hyphens, for the same reason)
- tokens(text) -> lowercase, accent-free word tokens for script matching"""
import re, unicodedata

U = ["zero", "uno", "due", "tre", "quattro", "cinque", "sei", "sette", "otto", "nove", "dieci", "undici", "dodici",
     "tredici", "quattordici", "quindici", "sedici", "diciassette", "diciotto", "diciannove"]
T = ["", "", "venti", "trenta", "quaranta", "cinquanta", "sessanta", "settanta", "ottanta", "novanta"]


def _lt100(n):
    if n < 20:
        return U[n]
    t, u = divmod(n, 10)
    w = T[t]
    if u in (1, 8):
        w = w[:-1]  # ventuno, ventotto
    return w + (U[u] if u else "")


def _lt1000(n):
    h, r = divmod(n, 100)
    w = "" if h == 0 else ("cento" if h == 1 else U[h] + "cento")
    if r:
        rw = _lt100(r)
        w = (w[:-1] if w and rw[0] == "o" else w) + rw  # centotto
    return w or "zero"


def int_words(n):
    if n < 1000:
        return _lt1000(n)
    if n < 1_000_000:
        k, r = divmod(n, 1000)
        return ("mille" if k == 1 else _lt1000(k) + "mila") + (_lt1000(r) if r else "")
    m, r = divmod(n, 1_000_000)
    return ("un milione" if m == 1 else int_words(m) + " milioni") + (" " + int_words(r) if r else "")


FR_U = ["zéro", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix", "onze", "douze", "treize",
        "quatorze", "quinze", "seize", "dix sept", "dix huit", "dix neuf"]
FR_T = ["", "", "vingt", "trente", "quarante", "cinquante", "soixante"]


def fr_words(n):
    if n < 20:
        return FR_U[n]
    if n < 70:
        t, u = divmod(n, 10)
        return FR_T[t] + (" et un" if u == 1 else (" " + FR_U[u] if u else ""))
    if n < 80:
        return "soixante" + (" et onze" if n == 71 else " " + FR_U[n - 60])
    if n < 100:
        return "quatre vingts" if n == 80 else "quatre vingt " + FR_U[n - 80]
    if n < 1000:
        h, r = divmod(n, 100)
        head = "cent" if h == 1 else FR_U[h] + " cent" + ("s" if r == 0 else "")
        return head + (" " + fr_words(r) if r else "")
    if n < 1_000_000:
        k, r = divmod(n, 1000)
        return ("mille" if k == 1 else fr_words(k) + " mille") + (" " + fr_words(r) if r else "")
    m, r = divmod(n, 1_000_000)
    return fr_words(m) + (" million" if m == 1 else " millions") + (" " + fr_words(r) if r else "")


def numbers_to_words(text, lang="it"):
    fr = (lang or "it").lower().startswith("fr")
    words = fr_words if fr else int_words
    units = FR_U if fr else U
    comma = " virgule " if fr else " virgola "

    def thousands(m):
        return words(int(re.sub(r"\D", "", m.group(0))))

    def decimal(m):
        a, b = m.group(1), m.group(2)
        return words(int(a)) + comma + " ".join(units[int(c)] for c in b) if len(b) > 1 and b[0] == "0" \
            else words(int(a)) + comma + words(int(b))

    group = r"\b\d{1,3}(?:[ \u00a0\u202f]\d{3})+\b" if fr else r"\b\d{1,3}(?:\.\d{3})+\b"
    text = re.sub(group, thousands, text)
    text = re.sub(r"\b(\d+),(\d+)\b", decimal, text)
    if fr:
        text = re.sub(r"(\d)\s?%", r"\1 pour cent", text)
    text = re.sub(r"\b\d+\b", lambda m: words(int(m.group(0))), text)
    return text


def strip_accents(s):
    return "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")


def tokens(text, lang="it"):
    t = strip_accents(numbers_to_words(text, lang).lower())
    return re.findall(r"[a-z0-9]+", t.replace("'", " ").replace("’", " "))
