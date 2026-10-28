MariaDB 12.3.3 (default) and 11.4.13 (LTS) for Linux, built by rexenv: `mariadbd`, `mariadb`, `mariadb-dump` and the bootstrap files, for x86_64 and aarch64.

Built by `.github/workflows/mariadb-linux.yml` with `scripts/build-mariadb.sh` from
the mariadb.org source tarballs. Mirrored in this release: both tarballs; the PCRE2
10.47 and libfmt 12.2.0 bundles MariaDB's cmake would otherwise fetch at build time;
OpenSSL 3.6.5; and the scripts that built them (`mariadb-<v>-rexenv-build.tar.gz`).
MariaDB is GPL-2.0, so the corresponding source is on this page.

**Why this build exists.** rexenv's macOS MariaDB is a Homebrew bottle. Homebrew's
Linux bottles are x86_64-only, so rexenv's Linux catalog had none
(rexenv/rexenv#7, ask 5). 12.3.3 and 11.4.13 are the current patches of the two
series rexenv offers. macOS pins 12.3.2 and 11.4.12.

**What ships, and only that**, the shape of the macOS bundle and the paths
`core/mariadb.rs` reads:

```
bin/mariadbd  bin/mariadb  bin/mariadb-dump
share/mysql/mariadb_system_tables.sql
share/mysql/mariadb_performance_tables.sql
share/mysql/mariadb_system_tables_data.sql
share/mysql/english/errmsg.sys
share/mysql/charsets/
```

No dynamic plugins, scripts or test suite ship. The server's static plugins
(InnoDB, Aria, MyISAM, CSV, MEMORY, performance_schema, unix_socket auth, …) are
compiled into `mariadbd`. Init is `mariadbd --bootstrap` with the three SQL files
over stdin.

**Floor: Ubuntu 22.04 (glibc 2.35), both arches.** The binaries need glibc and
`libcrypt.so.1`, nothing else. The rest is static:

- **OpenSSL 3.6.5** in the server and both clients. This is the library the macOS
  bundle carries (openssl@3). The source tree's bundled wolfSSL is not used: with
  it, the clients' Connector/C requires GnuTLS on Linux and has no TLS-off mode.
  `OPENSSLDIR` is `/usr/lib/ssl`, Ubuntu's own.
- zlib, PCRE2 and libfmt from MariaDB's bundles. Readline is bundled too, over a
  static libtinfo.
- libstdc++ and libgcc (`-static-libstdc++ -static-libgcc`).
- No libaio or liburing. Neither is in a stock Ubuntu, and 24.04 renamed libaio's
  SONAME. InnoDB uses its own thread-pool I/O.

**Gated before publishing**, for each version, in a clean `ubuntu:22.04` and
`ubuntu:24.04` with nothing installed, no network and an unprivileged user:

1. `mariadbd --bootstrap` runs with rexenv's exact preamble and arguments and makes
   a datadir.
2. The server starts with rexenv's `start()` arguments, on a socket and on `127.0.0.1`.
3. `mariadb` runs CREATE DATABASE, CREATE TABLE (InnoDB), INSERT and SELECT over
   TCP and the socket. The data includes UTF-8.
4. An SQL error returns English text, which proves `errmsg.sys` was read. A latin2
   conversion proves `charsets/` was read.
5. A TLS handshake completes between client and server.
6. `mariadb-dump` dumps the database, and the dump restores.
7. SIGTERM gives a clean shutdown with no `[ERROR]` in the log.

`ldd` shows nothing outside glibc.

**This tag is immutable and will never be re-uploaded.** A rebuild is the next build number.

Verify origin:

```sh
gh attestation verify mariadb-12.3.3-linux-aarch64.tar.gz --repo rexenv/runtimes
```

## Hand-off to rexenv

| | |
|---|---|
| Tag | `mariadb-linux-1` (both versions in one release) |
| Archive layout | exactly the paths above, at the archive root. No layout difference from macOS |
| Linking | glibc + libcrypt.so.1 dynamic, everything else static. No RPATH |
| Versions | **12.3.3 / 11.4.13**, where macOS has 12.3.2 / 11.4.12 |

Sources, each checked against its project's published digest before the build:

| Source | SHA-256 |
|---|---|
| `https://archive.mariadb.org/mariadb-12.3.3/source/mariadb-12.3.3.tar.gz` | `e99d739fd4a55f9a11dea7bd2287a262673e287550af3071c8469dd2bec0c163` |
| `https://archive.mariadb.org/mariadb-11.4.13/source/mariadb-11.4.13.tar.gz` | `1bb254b106d0a7ca871cfa18fa6e18d4b80a7430f9ec9d1571ec4271a13def96` |
| `https://github.com/openssl/openssl/releases/download/openssl-3.6.5/openssl-3.6.5.tar.gz` | `a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98` |
| `https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.gz` | `c08ae2388ef333e8403e670ad70c0a11f1eed021fd88308d7e02f596fcd9dc16` |
| `https://github.com/fmtlib/fmt/releases/download/12.2.0/fmt-12.2.0.zip` | `a2f4a8d51178f954e4c339007f77edd76ba0cb2e36f87a48e5a5403d9be5878f` |

Assets of this release (from the publishing run's `SHA256SUMS`):

| Asset | SHA-256 |
|---|---|
| `mariadb-12.3.3-linux-x86_64.tar.gz` | `80a9db203f7f3b0bc832f2406131d24349c5b306a1494f1dda43c0b07f94a914` |
| `mariadb-12.3.3-linux-aarch64.tar.gz` | `53225bc3194afafcef32e9d7ec49d2a8760a2fcf1962733cd8bba47beb2efe87` |
| `mariadb-11.4.13-linux-x86_64.tar.gz` | `eaf2e201ffb0182f7b795b7b3e483642142c1ccefbecb8b9dfd4233a913505ff` |
| `mariadb-11.4.13-linux-aarch64.tar.gz` | `470f8a7eab033e4977de6419277076217cc1ce3802114b9718c6ceb432e818dd` |
| `licenses-mariadb-12.3.3-linux-x86_64.tar.gz` | `0d0983a948c592abb050b47b079dd093fa07498e59dd7867bec61b0355fd2a08` |
| `licenses-mariadb-12.3.3-linux-aarch64.tar.gz` | `8e51b6eca42f16d7ee64936c744b5eb9fbad098690f2f6936ef3c55303ffc2ee` |
| `licenses-mariadb-11.4.13-linux-x86_64.tar.gz` | `e1333a1b5a529e8a3b5de96639808f6aee7ca980767d112e6503b14ecb22a5bb` |
| `licenses-mariadb-11.4.13-linux-aarch64.tar.gz` | `d2f7bad3a9a0b97019ffc231d04c5773b3fc6258e46815552d1ece3f343da92f` |
