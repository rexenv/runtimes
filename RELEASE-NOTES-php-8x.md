Static PHP **8.1 – 8.5** for macOS — `php` (cli) and `php-fpm`, arm64 and x86_64,
**with a working `pdo_pgsql`**.

**PHP 8.0 is NOT in this release, and that is a measurement rather than a
decision to make later.** It builds and passes every gate on arm64; on x86_64 the
binary links and then aborts in static-php-cli's own sanity check —
`php -n -r 'echo "hello";'` exits 6 with no output — reproducibly, four runs,
with swoole+protobuf, with intl, and with imagick+imap+event each excluded in
turn (runs 34375990759, 34384428498, 34388106503, 34391268989, 34391282101). The
cause is still unknown; 8.0 has been end-of-life since Nov 2023, and half an
architecture is not something to ship. So 8.0 keeps coming from static-php.dev's
bulk build — which means **a PostgreSQL-backed site needs PHP 8.1 or newer**, the
consuming app enforcing that per minor rather than globally.

Built by `.github/workflows/php.yml` via static-php-cli 2.8.5, from php.net sources
spc downloads and pins. Extension parity with the static-php.dev "bulk" builds these
replace is a BUILD GATE, not a claim: `docs/bulk-modules-<minor>.txt` is generated from
the shipped bulk artifact FOR THAT MINOR, the build derives its extension set from it,
and fails if anything in it is missing from the result. Per minor because the upstream
sets are not the same — 8.0's has no `opentelemetry`, 8.5's has two modules the others
lack — and one shared list would demand the impossible of the old minors while letting
real losses through on the new ones.

## Why this exists

static-php.dev's bulk builds carry `pgsql` and **no `pdo_pgsql`** — while their PDO
advertises `pgsql` anyway. Measured 9 Sep 2026 against real clusters (PostgreSQL
16.14, 17.10 and 18.6) with the artifacts rexenv shipped:

| | bulk build | this build |
|---|---|---|
| `php -m` has `pdo_pgsql` | no | yes |
| `extension_loaded('pdo_pgsql')` | **false**, on all seven versions | true |
| `PDO::getAvailableDrivers()` | `mysql, pgsql, sqlite` — says otherwise | `mysql, pgsql, sqlite` |
| `pg_connect(…)` | connects and queries | connects and queries |
| `new PDO('pgsql:…')` | **socket accepted, startup packet never sent** — the server closes it on `authentication_timeout`, reported as `SQLSTATE[08006] server closed the connection unexpectedly` | connects, DDL, write, read back |

The same PDO call from a Homebrew PHP 8.2 connects instantly to the same server, so
this was the build and not PostgreSQL. A driver that announces itself and then stalls
for a minute is worse than a missing one: a missing driver fails immediately and names
itself.

Laravel's `pgsql` connection is that PDO call, and so is any PDO-based app. rexenv
refuses to create a PostgreSQL-backed site while the runtime cannot make it
(`core::php::PDO_PGSQL_IN_BUNDLED_PHP`); these builds are what lifts that refusal.

## The gate that would have caught it

`scripts/build-php.sh` gate 6 installs PostgreSQL, initdbs its own cluster on a spare
port, and makes the built `php` **connect through PDO, create a table, write a row and
read it back**. Not `php -m | grep`, and not `PDO::getAvailableDrivers()` — both of
those reported PostgreSQL support in the artifact that had none. The only check that
could see the difference is the one that opens a socket.

## What is in them

macOS floor `MACOSX_DEPLOYMENT_TARGET=12.0`, asserted per artifact (gate 5), matching
every PHP rexenv already ships. No non-system dylib in the closure (gate 4) — rexenv's
`relink_to_system_libs` hard-errors otherwise, on the user's machine, long after the
build. WP-CLI and Composer are RUN on the built binary (gate 7), because rexenv
executes both as phars through the site's PHP and a module list is only a proxy for
that.

**This tag is immutable and will never be re-uploaded.** A rebuild is the next build
number; see the README for why that matters to anything pinning these hashes.

Verify origin:

```sh
gh attestation verify php-8.3.33-cli-macos-aarch64.tar.gz --repo rexenv/runtimes
```

## Known gaps, stated rather than discovered

- **OpenSSL 3's legacy provider is off**, so `openssl_encrypt` with `bf-cbc`, `rc4` or
  `des-*` fails. True of the static builds these replace as well — not a regression.
- **PHP 8.0 is built from a patched source.** Its `ext/intl` asks for C++11
  (`PHP_CXX_COMPILE_STDCXX(11, mandatory, …)`) and the ICU this links (78) needs
  C++17 in its own headers, so the build raises that request to 17 — which is
  exactly what PHP 8.1 does when ICU requires it, applied to a version that never
  got the change. The substitution runs on php.net's release tarball INCLUDING its
  pre-generated `configure` (patching `config.m4` alone would be a no-op), the
  tarball is pinned by SHA-256, and the number of substitutions is asserted.
- **PHP 8.0 carries protobuf 3.25.3**, not the 5.34.1 the newer minors get: the
  newer sources use Zend API 8.0 does not have. Upstream's bulk 8.0 ships an older
  protobuf too, so this is parity.
- **PHP 8.0 and 8.1 carry swoole 5.1.7**, not the 6.x the newer minors get: swoole 6
  refuses to compile below PHP 8.2. Upstream's bulk builds for those minors ship an
  older swoole too, so this is parity rather than a divergence.
- **`pdo_sqlite` does not appear in `php -m`** (it is a builtin PDO driver). It is in
  the extension set and `PDO::getAvailableDrivers()` lists `sqlite`; after this repo's
  own experience with that list, the honest statement is that it is asked for at build
  time and reported by PDO, and only the PostgreSQL driver is proven by connecting.
