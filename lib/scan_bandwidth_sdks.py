#!/usr/bin/env python3
"""Task 40p: scan an uploaded .apk or .aab for an already-present bandwidth-sharing / residential-proxy SDK,
BEFORE CI does anything to the file (no injection, no signing). Zealot's rule: only the organisation's own CI
may put this kind of SDK into an app; one that already has it (whoever's) is rejected, flagged to the uploader,
the way Play rejects apps for an undisclosed SDK policy violation.

Usage:
    python3 scan_bandwidth_sdks.py <file.apk|file.aab> <fingerprints.yml>

Prints one line of JSON to stdout:
    {"found": true,  "names": ["Honeygain", "Proxies.sx (the organisation's own SDK)"]}
    {"found": false, "names": []}

Detection method: dex files store every class name as a plain UTF-8 string in the string pool
("Lcom/example/Thing;"), so a substring search for "Lcom/example/" against the raw dex bytes finds the class
without parsing the dex format -- the same kind of read Task 40n-a/40n used androguard for, done here with
no extra Python dependency (this script only needs PyYAML and the standard library, both already available
to a plain `python3` on a GitHub-hosted runner, or installed with one `pip install pyyaml` line). A
substring match is a cheap, high-recall / lower-precision signal: it can over-match on an unlucky prefix
collision and under-match an SDK that was repackaged or obfuscated. It is meant to flag for a held release
and a human-readable reason, not to be a forensic/legal determination -- see the fingerprints file's own
header.

What counts as "the app": for an .apk, every top-level classes*.dex. For an .aab, every module's
classes*.dex -- a bundle's dex files live under "<module>/dex/classesN.dex" (the base module is
"base/dex/classes.dex"), one directory per module, not just "base". A proxy SDK dropped into a dynamic
feature module would be invisible if only the base module were scanned, so every "*/dex/classes*.dex" entry
in the zip is read.

Not run against a real SDK sample in this sandbox (no network access to fetch one, none was supplied).
Run this session against three hand-built fixtures (plain zips shaped like a dex, not real dex bytecode):
a multi-module .aab with a marker string in base/dex/classes.dex (found), a second .aab with the marker only
in a non-base feature module's dex to confirm module scanning isn't base-only (found), a flat .apk with the
organisation's own sx/proxies/peer marker (found), and a clean .apk with neither (not found) -- all four
matched expectations. That confirms the zip/dex-entry walking and substring match work; it does NOT confirm
any "unverified" vendor's real SDK actually contains the guessed prefix -- see the fingerprints file.
"""
import json
import sys
import zipfile

try:
    import yaml
except ImportError:
    print("::error::PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)


def load_fingerprints(path):
    with open(path, "r", encoding="utf-8") as f:
        entries = yaml.safe_load(f) or []
    out = []
    for entry in entries:
        name = entry.get("name")
        prefixes = entry.get("prefixes") or []
        patterns = [p.encode("utf-8") for p in prefixes if p]
        if name and patterns:
            out.append((name, patterns))
    return out


def dex_entries(zf):
    """Every dex file's zip-entry name: top-level classes*.dex (an APK) plus every module's
    <module>/dex/classes*.dex (a bundle). Both shapes can appear in the same zip; harmless if one shape
    is absent for this file kind."""
    names = []
    for info in zf.infolist():
        n = info.filename
        base = n.rsplit("/", 1)[-1]
        if not (base.startswith("classes") and base.endswith(".dex")):
            continue
        if "/" not in n or n.split("/")[-2] == "dex":
            names.append(n)
    return names


def scan(file_path, fingerprints_path):
    fingerprints = load_fingerprints(fingerprints_path)
    matched = []
    with zipfile.ZipFile(file_path) as zf:
        entries = dex_entries(zf)
        if not entries:
            # Not necessarily a problem (a malformed file fails a later step for its own reasons), but
            # worth a visible note rather than a silent "nothing found".
            print(f"::warning::no classes*.dex entries found in {file_path}; nothing was scanned", file=sys.stderr)
        for entry_name in entries:
            data = zf.read(entry_name)
            for name, patterns in fingerprints:
                if name in matched:
                    continue
                if any(p in data for p in patterns):
                    matched.append(name)
    return matched


def main():
    if len(sys.argv) != 3:
        print("usage: scan_bandwidth_sdks.py <file.apk|file.aab> <fingerprints.yml>", file=sys.stderr)
        sys.exit(2)
    file_path, fingerprints_path = sys.argv[1], sys.argv[2]
    matched = scan(file_path, fingerprints_path)
    print(json.dumps({"found": bool(matched), "names": matched}))


if __name__ == "__main__":
    main()
