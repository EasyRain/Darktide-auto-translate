"""Ask bing's ttranslatev3 the same masked text with and without a tone.

The web UI exposes 语气 (standard / informal / formal) and the user reports the result differs, so the
question is whether a tone also changes how well the placeholders survive. This drives the keyless flow
the way the mod does - fetch /translator, read params_AbusePreventionHelper and IG, POST the form - so the
only variable is the extra query parameter.

Run:  python tools/bing_tone_probe.py <text-file>
"""
import io
import json
import re
import sys
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0")
HOST = "https://www4.bing.com"
OPEN, CLOSE = "\u27e6", "\u27e7"


def fetch(url, data=None, headers=None):
    request = urllib.request.Request(url, data=data, headers=headers or {})
    with urllib.request.urlopen(request, timeout=20) as reply:
        return reply.read()


def session():
    page = fetch(HOST + "/translator", headers={"User-Agent": UA}).decode("utf-8", "replace")
    helper = re.search(r"params_AbusePreventionHelper\s*=\s*\[([^\]]+)\]", page)
    ig = re.search(r'IG:"([^"]+)"', page)
    if not helper or not ig:
        raise SystemExit("  could not read the session (helper=%s ig=%s)" % (bool(helper), bool(ig)))
    parts = [p.strip().strip('"') for p in helper.group(1).split(",")]
    return parts[0], parts[1], ig.group(1)


def ask(key, token, ig, text, lang, tone=None, iid="translator.5024.1"):
    query = {"isVertical": "1", "": "", "IG": ig, "IID": iid}
    if tone:
        query["tone"] = tone
    url = HOST + "/ttranslatev3?" + urllib.parse.urlencode(query)
    form = urllib.parse.urlencode({"text": text, "fromLang": "en", "to": lang,
                                  "token": token, "key": key}).encode()
    body = fetch(url, data=form, headers={
        "User-Agent": UA,
        "Content-Type": "application/x-www-form-urlencoded",
        "Referer": HOST + "/translator",
    }).decode("utf-8", "replace")
    try:
        parsed = json.loads(body)
    except ValueError:
        return body[:120], None
    if isinstance(parsed, list) and parsed and isinstance(parsed[0], dict):
        return parsed[0].get("translations", [{}])[0].get("text", ""), parsed[0].get("detectedLanguage")
    return json.dumps(parsed)[:160], None


def counts(text):
    sent = {}
    for index in re.findall(re.escape(OPEN) + r"\s*(\d+)\s*" + re.escape(CLOSE), text):
        sent[index] = sent.get(index, 0) + 1
    return sent


def main():
    path = sys.argv[1]
    text = io.open(path, "rb").read().decode("utf-8")
    want = counts(text)
    key, token, ig = session()
    print("  session ready; %d placeholder(s) in the request" % sum(want.values()))
    for label, tone, iid in (
        ("no tone/5024", None, "translator.5024.1"),
        ("Formal/5024", "Formal", "translator.5024.1"),
        ("no tone/5023", None, "translator.5023"),
        ("no tone/5025", None, "translator.5025"),
        ("no tone/5028", None, "translator.5028"),
        ("no tone/5021", None, "translator.5021"),
        ("no tone/none", None, ""),
    ):
        answer, detected = ask(key, token, ig, text, "ja", tone, iid)
        got = counts(answer or "")
        missing = [i for i, n in want.items() if got.get(i, 0) < n]
        print("  tone=%-10s len=%-4d missing=%s" % (label, len(answer or ""), missing or "none"))
        if answer:
            print("      %s" % answer[:150].replace("\n", " / "))
        # the session token is consumed per request, so refresh it for the next tone
        key, token, ig = session()


main()
