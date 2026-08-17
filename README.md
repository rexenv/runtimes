# rexenv/runtimes

Reproducible builds of language runtimes that **nobody else publishes in a form
[rexenv](https://github.com/rexenv/rexenv) can use**, hosted as immutable GitHub
Release assets and pinned by SHA-256 in rexenv's `core/binaries.rs`.

This repo exists for one reason: rexenv downloads every binary on demand and
verifies it against a pinned hash. That works as long as somebody publishes a
portable build. For a few things, nobody does.

**It also publishes the signed PHP update manifest** — the document that lets a
rexenv install move to a newer PHP patch without waiting for an app release. That
half builds nothing: 8.x artifacts are static-php.dev's, and what a new patch needs
is a digest somebody vouched for. One command does it:

```sh
./scripts/publish-manifest.sh --dry-run   # discover + hash + sign, publish nothing
./scripts/publish-manifest.sh             # then publish
```

Read **[docs/MANIFEST.md](docs/MANIFEST.md)** before running it the first time —
particularly the four limits the app enforces on every entry, the monotonic serial,
and where the signing key lives (not in CI, and deliberately so).

| Artifact | Why it is built here |
|---|---|
| **PHP 7.4.33** (cli + fpm, macOS arm64 + x86_64) | static-php.dev publishes 8.0–8.5 only. Every `dl.static-php.dev/.../php-7.4.3*` URL 404s. Homebrew has `php@7.4` bottles, but they bake `/opt/homebrew` paths for both `php.ini` **and** `OPENSSLDIR` — so TLS fails on a Mac without Homebrew, which is exactly rexenv's target machine. |

## The pin contract

rexenv pins a **full release URL** including the tag, not a stable base path.
That is deliberate, and it is the whole point of self-hosting.

Both upstreams rexenv already depends on — static-php.dev and FrankenPHP —
**rebuild their release assets in place**: same URL, new bytes. rexenv's source
carries two long comments explaining that a sudden checksum mismatch usually
means an upstream rebuild rather than tampering. Here, that cannot happen:

- **Releases are immutable** (repo setting, and the workflow asserts it before
  publishing — a setting nobody checks is exactly the promise it was meant to
  replace). The REST API does not currently report `immutable_releases` for this
  repo, so the gate distinguishes *off* from *unknown* rather than calling the
  second the first, and in the unknown case it refuses to publish until a
  maintainer has checked the setting by hand and set the `IMMUTABLE_ACK`
  repository variable to `confirmed`.
- **A tag is never reused.** `php-7.4.33-1`; a rebuild is `php-7.4.33-2`.
- **`gh release upload --clobber` is banned**, and CI fails if the string appears
  in a workflow.
- **The version and build number are in every filename.**

So a rexenv pin can 404 — if someone deletes a release — but it can never
silently resolve to different bytes. A loud failure is a fixable failure.

## Verifying an artifact

Every release carries `SHA256SUMS` and a per-file `.sha256`. **These are
documentation, not a trust root** — the hash pinned in rexenv's source is. What
actually proves origin is the build provenance:

```sh
gh attestation verify php-7.4.33-cli-macos-aarch64.tar.gz --repo rexenv/runtimes
```

or, unauthenticated, over the API:

```sh
curl -s "https://api.github.com/repos/rexenv/runtimes/attestations/sha256:<digest>"
```

The attestation names the workflow, the commit and the `refs/tags/...` it was
built from.

**Builds are not bit-for-bit reproducible.** PHP's build embeds timestamps and
paths, and a Mach-O ad-hoc signature hashes the whole file. Two runs of the same
workflow differ. The attestation is what proves where an artifact came from; we
do not claim more than that.

## What is in a PHP artifact

A single statically-dep-linked Mach-O per SAPI, in a one-member `.tar.gz` whose
member is `php` or `php-fpm` — the same shape static-php.dev's "bulk" builds use,
so rexenv's manifest treats it identically.

Its complete dynamic-library closure is `/usr/lib/libSystem.B.dylib`,
`/usr/lib/libresolv.9.dylib` and `libz`. rexenv's `relink_to_system_libs` accepts
exactly that and hard-errors on anything else, so the check is not cosmetic.

**Source is not php.net's tarball.** Vanilla 7.4.33 does not compile against
OpenSSL 3.6 (`error: use of undeclared identifier 'RSA_SSLV23_PADDING'` — the
constant was removed from OpenSSL's headers). We build
[`shivammathur/php-src-backports`](https://github.com/shivammathur/php-src-backports)
`PHP-7.4-security-backports`, the same source Homebrew's `php@7.4` formula uses.
It guards that constant, carries the Xcode-16 clang inline-asm fix and the
Apple-Silicon `ITIMER_PROF` fix, and is still receiving security backports.

**That branch is rebased, not appended** — the last eight commits all share one
committer timestamp while their author dates span years — so the pinned commit
stops being reachable from any ref at the next update. Therefore the **source
tarball is mirrored as an asset in the same release** and pinned by hash. When
upstream's URL 404s, that mirror is the only copy, and it is the only thing that
makes the build reproducible from URLs alone.

## PHP 7.4 is end-of-life

Upstream security support ended 28 November 2022. It is offered because legacy
projects exist and have to be opened, not because it is a reasonable target for
new work. rexenv says so in its own UI, in every place a version is chosen.

Known divergences from rexenv's 8.x rows, stated rather than discovered:

- **No `opcache`.** static-php-cli cannot build it for 7.4 — its static-opcache
  patch series starts at 8.0 and `patchMicro()` returns early for `74`. A
  performance feature, absent; WordPress runs without it.
- **OpenSSL 3's legacy provider is off**, so `openssl_encrypt` with `bf-cbc`,
  `rc4` or `des-*` fails. This is true of rexenv's 8.x static builds too — it is
  not a 7.4 regression.

## Licensing

rexenv distributes these bytes, so each release ships the licences that travel
with them: the PHP License v3.01 and the licences of every statically linked
dependency. See [`licenses/`](licenses/). Source tarballs for the dependencies
are mirrored in the release alongside the binaries, so the offer stands on
something that cannot rot.

## Building

Builds run on GitHub-hosted runners only (`macos-15`, `macos-15-intel`) — never
on a maintainer's machine — so what produced an artifact is a public log with an
attestation, not somebody's laptop.

```
Actions → "Build PHP 7.4.33" → Run workflow
```
