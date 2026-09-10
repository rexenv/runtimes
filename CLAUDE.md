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

## The manifest carries OUR builds — so the order is build, then publish

rexenv installs new PHP patches without an app release by reading the signed
manifest this repo publishes. Those entries used to point at `dl.static-php.dev`.
They point at **our own releases** now, for the same reason this repo builds 8.x
at all: upstream's artifacts have no working `pdo_pgsql`, so an update sourced
from them would take PostgreSQL away from every site on that minor — the update
would be a REGRESSION, delivered by the mechanism that exists to keep people
current.

**When upstream publishes a new patch:**

1. Build it here (Actions → *Build PHP 8.x (with pdo_pgsql)*, publish on).
2. Add the version to `RELEASE_TAG_FOR` in `scripts/publish-manifest.sh`.
3. Run the manifest publisher.
4. Bump the pins in rexenv when the app next releases (a pin beats the manifest,
   so this is what a FRESH install gets).

Never 3 before 1. A patch we have not built is **not offered** — the publisher
skips it and prints what to do — because an update a day earlier is not worth a
site that cannot reach its database.

Each version carries **six** artifacts: `php` + `php-fpm` + **`php-licenses`**,
both arches. The licences are not optional bookkeeping: rexenv refuses to resolve
a self-distributed PHP whose licence texts it cannot name, so an entry without
them installs an interpreter and then fails.

## Working rules

- **A release tag is immutable and is never re-uploaded.** A rebuild is the NEXT
  build number. `php-8x-1`, `-2`, `-3` all still exist and all still resolve;
  that is the contract working, not a mess. rexenv pins full URLs including the
  tag, so a stale pin can 404 but can never silently change bytes.
- **Build it on the laptop first. CI is for the second arch and the release.**
  Measured 10 Sep 2026, same script, same extension set: **3–3.6 minutes here
  (11 cores) against 17m26s on a macos-15 runner (3 cores)** — before counting
  the queue, which ran 20 to 60 minutes that day. Every gate except one runs
  locally: modules, functions, flags, the licences, and the real PostgreSQL
  connection (`PG_BIN_DIR=<a postgres tree>/bin` uses one you already have
  instead of `brew install`). What local CANNOT do is the **x86_64** half — spc
  builds native — or the provenance attestation and the immutable release. So:
  prove it here, publish there.

  ```sh
  cd /tmp/lb && GITHUB_TOKEN="$(gh auth token)" \
    PG_BIN_DIR="$HOME/Library/Application Support/dev.rexenv.rexenv/bin/postgres-18.6.0/bin" \
    bash ~/PhpstormProjects/runtimes/scripts/build-php.sh 8.3.32 aarch64 /tmp/lb/out true
  ```

  (`GITHUB_TOKEN` is not optional in practice: `--prefer-pre-built` asks
  api.github.com which dep archives exist, and unauthenticated that is 60/hr per
  IP — it 403s and the build dies before compiling anything.)
- **`set -o pipefail` + `grep` is a trap, three times now.** Each cost a build:
  `nm … | grep -q` reports the OPPOSITE of what it finds (grep exits at the first
  match, `nm` dies of SIGPIPE, the pipeline is 141); `grep -vE "$PAT"` where the
  pattern starts with `--` reads it as an option; and `grep -v` that filters
  everything out exits 1, which under pipefail is a failed command substitution
  and under `set -e` a SILENT exit — so a gate died exactly when it had nothing
  to report. Read a long stream into a variable and match that; pass `--` before
  a pattern; and end a filter whose empty result is success with `|| true`.
- **One version first, then the matrix.** When anything about the build's shape
  changes — an extension, a library, a gate, a flag — run ONE version with
  `publish: false`, read it, fix it, and only then run the five. A shape change
  fails identically on every version, so a full matrix to learn one fact spends
  ten runner slots and forty minutes to tell you what two would have.
  **Measured, on 10 Sep 2026: three full matrices lost in a row** — `mbregex`,
  then `libavif`, then a `grep` that read its own pattern as an option — each
  discovered on all ten jobs at once, each fixed by one line. The matrix is for
  proving five versions, not for finding a bug.
- **`publish: false` first** when a build's shape has changed. A failed build
  never publishes (the publish job `needs:` the matrix), so `publish: true` is
  safe — but the log is easier to read when nobody is waiting on a release, and a
  cancelled run still costs the queue its slot.
- **Measure locally before spending a cycle at all.** The artifacts are on the
  machine: `get_defined_functions()`, `php -i | grep 'Configure Command'`,
  `php -m`. Both capability gaps this repo has shipped were visible in a
  two-minute diff of files already on disk. CI is for confirming, not finding.
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
