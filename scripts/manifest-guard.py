#!/usr/bin/env python3
"""The last check before a manifest is signed: the document carries only what its
FILE says it carries.

    scripts/manifest-guard.py --document macos   manifest.json
    scripts/manifest-guard.py --document macos   app-manifest.json
    scripts/manifest-guard.py --document windows app-manifest-windows.json
    scripts/manifest-guard.py --document linux   app-manifest-linux-deb-aarch64.json
    scripts/manifest-guard.py --self-test

Why this exists (rexenv docs/TODO.md, "Update catalogs across OSes", ruled 13 Sep 2026):
each OS reads its OWN signed document (`manifest-<os>.json`, `app-manifest-<os>.json`; the
unsuffixed files are macOS's and FROZEN), and every shipped macOS build keeps rows it
does not understand — measured against 0.3.0–0.7.0: an `os` field on an `x86_64` row is
KEPT by every Intel Mac. So a Windows or Linux entry published into the macOS documents
would be resolved by Macs that cannot run it. rexenv's readers lock this from their side
since 30 Sep 2026 (ledger #755: a row marked for another OS is dropped, a release marked
for another OS is refused as malformed). This is the publisher's lock — the other half the
ruling asked for before the first non-macOS entry is published.

The rules, per document kind:
  macos    no row and no release may carry an `os` key at all (the frozen contract has
           none; "macos" spelled out would still be a field old readers never saw), and
           every row's `arch` is what rexenv's `Family::arch_ok` resolves on a Mac:
           `arm64` or `x86_64` for php / php-fpm / php-licenses, `any` for adminer (the
           app release carries no arch — the macOS bundle is universal).
  windows  a row or release that carries `os` must say "windows".
  linux    a row or release that carries `os` must say "linux".
           No per-OS PHP document exists yet, so their arch spelling is not asserted here —
           the row that publishes the first one adds it (rexenv docs/TODO.md).
The names are `std::env::consts::OS`'s, which is what rexenv compares against.

Exit 0 = the document may be signed. Exit 1 = REFUSE, with every violation named.
Both publishers call this after writing the document and before `openssl pkeyutl -sign`.
"""
import json
import sys

# rexenv `core/updates.rs`, `Family::arch_ok`: the spellings a Mac resolves, per family.
MACOS_ARCH_BY_FAMILY = {"php": {"arm64", "x86_64"}, "php-fpm": {"arm64", "x86_64"}, "php-licenses": {"arm64", "x86_64"}, "adminer": {"any"}}


def rows(doc):
    """Every object that can carry `os`/`arch`: the artifact rows (PHP/Adminer manifest) or
    the single release (app manifest)."""
    out = []
    for i, a in enumerate(doc.get("artifacts") or []):
        out.append((f"artifacts[{i}] ({a.get('name', '?')} {a.get('version', '?')})", a))
    if isinstance(doc.get("release"), dict):
        out.append((f"release ({doc['release'].get('version', '?')})", doc["release"]))
    return out


def violations(doc, kind):
    bad = []
    if kind not in ("macos", "windows", "linux"):
        return [f"unknown document kind `{kind}` — macos, windows or linux"]
    found = rows(doc)
    if not found:
        bad.append("the document has neither `artifacts` nor `release` — nothing to publish")
    for where, row in found:
        os_ = row.get("os")
        arch = row.get("arch")
        if kind == "macos":
            if "os" in row:
                bad.append(f"{where}: carries `os` = {os_!r} — the macOS documents are frozen and carry no `os` field; a per-OS entry goes in its own `*-{os_}*.json`")
            allowed = MACOS_ARCH_BY_FAMILY.get(row.get("name"))
            if arch is not None and allowed is not None and arch not in allowed:
                bad.append(f"{where}: `arch` = {arch!r} is not one a Mac resolves for {row.get('name')} ({', '.join(sorted(allowed))}) — rexenv drops the row")
            if arch is not None and allowed is None and "name" in row:
                bad.append(f"{where}: `name` = {row.get('name')!r} is no family rexenv resolves")
        elif "os" in row and os_ != kind:
            bad.append(f"{where}: carries `os` = {os_!r} inside the {kind} document")
    return bad


def check_file(path, kind):
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    return violations(doc, kind)


def self_test():
    """The guard proven against the shapes it must refuse and the ones it must pass."""
    ok = lambda d, k: violations(d, k) == []
    cases = [
        # the shipped shapes pass
        (ok({"serial": 1, "artifacts": [{"name": "php", "version": "8.3.1", "arch": "arm64"}, {"name": "php-fpm", "version": "8.3.1", "arch": "x86_64"}, {"name": "php-licenses", "version": "8.3.1", "arch": "arm64"}, {"name": "adminer", "version": "5.4.2", "arch": "any"}]}, "macos"), "macOS manifest without os, the shipped arch spellings"),
        (ok({"serial": 1, "release": {"version": "0.8.11", "url": "u"}}, "macos"), "macOS app manifest without os"),
        (ok({"serial": 1, "release": {"version": "0.8.11", "os": "windows"}}, "windows"), "windows release marked windows"),
        (ok({"serial": 1, "release": {"version": "0.8.11"}}, "linux"), "linux release unmarked"),
        (ok({"serial": 1, "release": {"version": "0.8.11", "os": "linux", "arch": "aarch64"}}, "linux"), "linux release marked linux aarch64"),
        (ok({"serial": 1, "artifacts": [{"name": "php", "version": "8.3.1", "arch": "x86_64", "os": "windows"}]}, "windows"), "a Windows php row in the Windows document"),
        # the shapes the ruling forbids are refused
        (not ok({"serial": 1, "artifacts": [{"name": "php", "version": "8.3.1", "arch": "x86_64", "os": "windows"}]}, "macos"), "a Windows row in the macOS manifest"),
        (not ok({"serial": 1, "artifacts": [{"name": "php", "version": "8.3.1", "arch": "x86_64", "os": "macos"}]}, "macos"), "even `os: macos` in the frozen macOS manifest"),
        (not ok({"serial": 1, "artifacts": [{"name": "php", "version": "8.3.1", "arch": "x64"}]}, "macos"), "a foreign arch spelling (x64) in the macOS manifest"),
        (not ok({"serial": 1, "artifacts": [{"name": "php", "version": "8.3.1", "arch": "aarch64"}]}, "macos"), "aarch64 — the URL's spelling, not the row's (rexenv wants arm64)"),
        (not ok({"serial": 1, "artifacts": [{"name": "adminer", "version": "5.4.2", "arch": "arm64"}]}, "macos"), "a per-arch adminer row (rexenv wants any)"),
        (not ok({"serial": 1, "artifacts": [{"name": "caddy", "version": "2.11.4", "arch": "arm64"}]}, "macos"), "a family rexenv does not resolve"),
        (not ok({"serial": 1, "release": {"version": "0.8.11", "os": "linux"}}, "macos"), "a Linux release in the macOS app manifest"),
        (not ok({"serial": 1, "release": {"version": "0.8.11", "os": "macos"}}, "windows"), "a macOS release in the Windows document"),
        (not ok({"serial": 1, "release": {"version": "0.8.11", "os": "windows"}}, "linux"), "a Windows release in a Linux document"),
        (not ok({"serial": 1}, "macos"), "an empty document"),
        (not ok({"serial": 1, "release": {"version": "1"}}, "bsd"), "an unknown document kind"),
    ]
    failed = [name for passed, name in cases if not passed]
    for passed, name in cases:
        print(f"  {'ok ' if passed else 'FAIL'} {name}")
    if failed:
        print(f"manifest-guard: SELF-TEST FAILED — {len(failed)} case(s): {', '.join(failed)}", file=sys.stderr)
        return 1
    print(f"manifest-guard: self-test passed ({len(cases)} cases)")
    return 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    if len(argv) != 4 or argv[1] != "--document":
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    kind, path = argv[2], argv[3]
    bad = check_file(path, kind)
    if bad:
        print(f"manifest-guard: REFUSING to sign {path} as the {kind} document:", file=sys.stderr)
        for b in bad:
            print(f"  - {b}", file=sys.stderr)
        return 1
    print(f"manifest-guard: {path} carries only what a {kind} document may ({len(rows(json.load(open(path))))} row(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
