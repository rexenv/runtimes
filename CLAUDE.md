# CLAUDE.md — rexenv/runtimes

Reproducible builds of runtimes **nobody else publishes in a form rexenv can
use**, hosted as immutable GitHub Release assets and pinned by SHA-256 in
rexenv's `core/binaries.rs`. It also publishes the two signed update manifests
(PHP/Adminer, and the app itself) — see `docs/MANIFEST.md`, `docs/APP-MANIFEST.md`.

Nothing here runs on a user's machine. What it produces does.

## The rule this repo exists to keep (non-negotiable)

> **Our PHP 8.x is static-php.dev's build PLUS `pdo_pgsql`. Never a subset of it.**

We build 8.x for exactly one reason: the upstream "bulk" builds ship `pgsql` and
no `pdo_pgsql`, while their PDO advertises `pgsql` anyway — so a PDO connection
is accepted and then hangs. Laravel's `pgsql` driver IS that call. **Adding that
driver is the whole mandate. Removing anything is not part of it**, and a
divergence is only legitimate when it is a DECISION with a reason written down
(see `DELIBERATE` in `scripts/build-php.sh`), never a gap.

### Why the rule is written this hard

It was broken twice in two days, both times silently, because the build's
extension list was derived from `php -m` on the upstream artifact — **a list of
NAMES**. Everything whose name PHP does not print fell out without a word:

| Escape | What `php -m` said | What was actually missing |
|---|---|---|
| `mbregex` (10 Sep 2026) | `mbstring`, identical to upstream | 16 functions — `mb_split`, `mb_ereg*`, `mb_regex_*`. **Every Laravel `artisan` command died**: `Call to undefined function Illuminate\Support\mb_split()`. Reported by a user, one day after the parity gate was written to prevent exactly this |
| `libavif` (10 Sep 2026) | `gd`, identical to upstream | `imageavif`, `imagecreatefromavif` |

`pdo_pgsql` and `pdo_sqlite` are the same shape from the other side: PDO drivers
never appear in `php -m` either, which is why they live in `ALWAYS_EXTS`.

**The lesson, stated so the next person does not have to earn it again: a gate is
only as good as the thing it compares. When a check compares a list the subject
also publishes, ask what the subject would still say if the thing were broken.**

## The three gates, and what each one cannot see

`scripts/build-php.sh` asks the same question from three directions. All three,
because each is blind where another sees:

| Gate | Compares | Blind to |
|---|---|---|
| **flags** | upstream's own `Configure Command`, read out of their binary, against ours | a flag that is set and does not work |
| **functions** | `get_defined_functions()['internal']`, ours vs theirs, same version | classes, constants, ini defaults, behaviour |
| **modules** | `php -m` against `docs/bulk-modules-<minor>.txt` | anything folded into another module's name — the two escapes above |

The flags and functions gates download upstream's artifact for the **same
version**. A 404 there is a WARNING that says so — it means upstream does not
publish that version (7.4 never was) — and never a silent pass.

The fourth gate is not a comparison: **a real PostgreSQL connection through PDO**
(initdb, connect, CREATE TABLE, INSERT, SELECT). `php -m` and
`getAvailableDrivers()` both claimed PostgreSQL support in the artifact that had
none, so only a socket can answer that one.

## Working rules

- **Measure before building.** A 40-minute matrix is a slow way to learn
  something a laptop can answer in two minutes: diff the artifacts you already
  have (`get_defined_functions()`, `Configure Command`) before spending a cycle.
  Every fix in this file was measured first and CI only confirmed it.
- **A release tag is immutable and is never re-uploaded.** A rebuild is the NEXT
  build number. `php-8x-1`, `-2`, `-3` all still exist and all still resolve;
  that is the contract working, not a mess. rexenv pins full URLs including the
  tag, so a stale pin can 404 but can never silently change bytes.
- **`publish: false` first** when a build's shape has changed. A failed build
  never publishes (the publish job `needs:` the matrix), so `publish: true` is
  safe — but the log is easier to read when nobody is waiting on a release.
- **`skip_exts` is triage only** and the publish job refuses a run that used it.
- **We are the DISTRIBUTOR.** Static linking puts every dependency's licence
  inside the binary, so the licence texts are collected from the sources spc
  actually downloaded and published beside the artifact
  (`licenses-php-<version>-<arch>.tar.gz`). A dependency with no findable licence
  FAILS the build — a warning in a green build is one nobody reads. rexenv pins
  those digests too and refuses to resolve an artifact of ours without them.
- **7.4 is a different build with different rules** (`scripts/build-php74.sh`):
  patched source, C23 flags, no opcache, no Xdebug, no PCRE JIT, and no avif —
  PHP 7.4's gd cannot use it at all. Do not copy 8.x's list into it.

## Adding a version, or fixing one

1. Diff locally against upstream's artifact first (see Working rules).
2. `scripts/build-php.sh` — extensions come from `BASE_EXTS` ∩ the minor's
   `docs/bulk-modules-<minor>.txt`, plus `ALWAYS_EXTS` (what `php -m` never
   prints). Per-minor quirks live in the `case "$PHP_VERSION"` blocks with the
   measurement that motivated them.
3. Run the workflow (Actions → **Build PHP 8.x (with pdo_pgsql)**), one version
   first if the shape changed.
4. Publish → then **re-pin in rexenv**: `php_self_hosted_tag`, the four artifact
   digests and the two licence digests per version, and `PHP_VERSIONS` /
   `PHP_VERSION` if the patch moved. A pin beats the update manifest
   (`php_spec` asks the compiled-in table first), which is what makes an updated
   machine get our build rather than upstream's.
5. rexenv's own guards will fail loudly if you miss a step — the notices file,
   the ledger tally, and the tests that read the pin rather than a literal.

## Layout

| Path | What |
|---|---|
| `scripts/build-php.sh` | 8.x builds — the gates above live here |
| `scripts/build-php74.sh` | 7.4, patched source, its own rules |
| `scripts/build-nginx.sh` | nginx (upstream's darwin builds moved to a macOS 26 floor) |
| `scripts/publish-manifest.sh` | the signed PHP/Adminer update manifest |
| `scripts/publish-app-manifest.sh` | the signed app update descriptor |
| `docs/bulk-modules-<minor>.txt` | per-minor module reference, GENERATED from a shipped upstream artifact — never typed |
| `docs/MANIFEST.md` | the manifest's limits, serial, and the signing key |
| `RELEASE-NOTES-php-8x.md` | what a consumer of these artifacts needs to know |
