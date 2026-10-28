Redis 8.8.4 for Linux, built by rexenv: `bin/redis-server` and `bin/redis-cli` for x86_64 and aarch64.

Built by `.github/workflows/redis-linux.yml` with `scripts/build-redis.sh` from the
redis.io release tarball, which is mirrored in this release with the scripts that
built it (`redis-8.8.4-rexenv-build.tar.gz`). Redis 8 is tri-licensed
RSALv2 / SSPLv1 / AGPLv3. rexenv redistributes it under the **AGPLv3**, so the
corresponding source is on this page.

**Why this build exists.** rexenv's macOS Redis is a Homebrew bottle. Homebrew's
Linux bottles are x86_64-only, so rexenv's Linux catalog had no Redis
(rexenv/rexenv#7, ask 5).

**Floor: Ubuntu 22.04 (glibc 2.35), both arches.** Built in an `ubuntu:22.04`
container. The binaries need only `libc.so.6`, `libm.so.6` and the loader. Every
other dependency is vendored by Redis and linked static: jemalloc, lua, hiredis,
linenoise, hdr_histogram, fpconv, tre and xxhash. Gated in a clean `ubuntu:22.04`
and `ubuntu:24.04` with nothing installed and no network.

**What differs from the macOS bundle, by decision:**

- **No TLS** (`BUILD_TLS=no`). rexenv binds Redis to `127.0.0.1` and never passes a
  `--tls-*` option. Shipping OpenSSL for a loopback socket would mean re-releasing
  for every OpenSSL CVE with no code path that reaches it. `redis-server --tls-port …`
  fails here, while the macOS bundle accepts it.
- **jemalloc** (`mem_allocator:jemalloc`), Redis's Linux default. The macOS bottle
  uses `malloc=libc`.
- Only `redis-server` and `redis-cli` ship. `redis-check-*` and `redis-sentinel` are
  the same executable under other names, and rexenv runs neither.
- Like the macOS bottle, no Redis 8 modules (JSON, Search, Bloom, TimeSeries) are built.

**Gated before publishing**, as a real process: `redis-server` with rexenv's own
arguments (`--port --bind 127.0.0.1 --dir --daemonize no`, `LC_ALL=C`) plus
`--save ''`. Then `PING` → `PONG`, a SET/GET round trip, TTL, INCR, `INFO`
version and allocator, and `SHUTDOWN`. `ldd` shows nothing outside glibc on either image.

**This tag is immutable and will never be re-uploaded.** A rebuild is the next build number.

Verify origin:

```sh
gh attestation verify redis-8.8.4-linux-aarch64.tar.gz --repo rexenv/runtimes
```

## Hand-off to rexenv

| | |
|---|---|
| Tag | `redis-linux-<n>`, filled in at publish |
| Archive layout | `bin/redis-server`, `bin/redis-cli` at the archive root (`core/redis.rs` paths, no Layout change) |
| Linking | glibc-dynamic (floor 2.35), everything else static. No RPATH |
| TLS | off, by decision (above) |

Sources, each checked against its project's published digest before the build:

| Source | SHA-256 |
|---|---|
| `https://download.redis.io/releases/redis-8.8.4.tar.gz` (digest: github.com/redis/redis-hashes) | `ac03312b88534905e35c1791266ae48c0664cea10aa4111a6d05627aad0dc9d2` |

Assets of this release (filled in from the publishing run's `SHA256SUMS`):

| Asset | SHA-256 |
|---|---|
| `redis-8.8.4-linux-x86_64.tar.gz` | _publish run_ |
| `redis-8.8.4-linux-aarch64.tar.gz` | _publish run_ |
| `licenses-redis-8.8.4-linux-x86_64.tar.gz` | _publish run_ |
| `licenses-redis-8.8.4-linux-aarch64.tar.gz` | _publish run_ |
