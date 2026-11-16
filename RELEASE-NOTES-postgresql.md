PostgreSQL for macOS, built by rexenv — a relocatable `bin/lib/share` tree per arch, arm64 and x86_64.

Built by `.github/workflows/postgres.yml` from the postgresql.org release and OpenSSL,
both mirrored in this release beside the trees (their published SHA-256 checked at
fetch) so "which source built this" is answerable from this page alone.

**macOS floor: `MACOSX_DEPLOYMENT_TARGET=13.0`, asserted on EVERY Mach-O in the tree**
— each program, library and loadable module, not `bin/postgres` alone.

**Why this build exists.** rexenv pins theseus-rs/postgresql-binaries, and those
declare whatever floor their runner had: `minos 15.0` today, 26.0 in June 2026, and
never below 14.0 on arm64. So rexenv on macOS 14 could offer one 2024 patch of
PostgreSQL 16, and on macOS 13 none. This is the same version at a floor that is a
decision instead of an accident.

**This tag is immutable and will never be re-uploaded.** A rebuild is the next
build number.

Verify origin:

```sh
gh attestation verify postgresql-<version>-macos-aarch64.tar.gz --repo rexenv/runtimes
```

**What is in it:**

- **Upstream's feature set.** The configure flags are theseus-rs's for the same
  version (`--with-openssl --with-libxml --with-libxslt --with-readline
  --with-uuid=e2fs --without-icu --without-ldap`), and the build fails unless the
  programs, loadable modules, extensions and flags match their tree name for name.
- **OpenSSL is linked in static** — the one deliberate difference. Upstream ships
  Homebrew's `libssl`/`libcrypto` dylibs, whose floor is the bottle's. Here there is
  no OpenSSL file in the tree; the closure is `/usr/lib`, `/System` and the tree
  itself (`@loader_path/../lib/`), asserted per Mach-O.
- **No docs** (`world-bin`): no `share/doc`, no man pages.

Gated before publishing, on the PACKAGED tree unpacked at a path with a space and
with the build prefix deleted: the version; `initdb` and a server; `CREATE
EXTENSION` for every extension shipped; libxml (`xpath`), libxslt (`xslt_process`),
OpenSSL (`pgcrypto`), uuid (`uuid-ossp`); a `pg_dump` → `psql` round trip; and a
TLS session between the tree's own server and `psql`.

**Not proven by this build:** a run on macOS 13 or 14. `minos` is metadata; the
runner is macOS 15. rexenv's ledger says which hosts have run it.

Licences: `licenses-postgresql-<version>-macos-<arch>.tar.gz` — the PostgreSQL
Licence and OpenSSL's Apache-2.0.
