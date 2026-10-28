Apache httpd 2.4.69 for Linux, built by rexenv: `bin/httpd` plus the ten modules rexenv's generated conf loads, for x86_64 and aarch64.

Built by `.github/workflows/httpd-linux.yml` with `scripts/build-httpd.sh` from the
ASF tarballs of httpd 2.4.69, apr 1.7.6 and apr-util 1.6.5, plus PCRE2 10.47 and
expat 2.9.0. All of them are mirrored in this release with the scripts that built
them (`httpd-2.4.69-rexenv-build.tar.gz`).

**Why this build exists.** rexenv runs httpd per site as a loopback backend behind
the Caddy edge, for `.htaccess`. On macOS it is a Homebrew bottle. Homebrew's Linux
bottles are x86_64-only, so rexenv's Linux catalog had none (rexenv/rexenv#7, ask 5).
2.4.69, not macOS's 2.4.68: 2.4.69 fixes about twenty CVEs, including a
`mod_rewrite` use-after-free (CVE-2026-56154). rexenv's Windows build already
ships 2.4.69. apr-util 1.6.5 is used instead of 1.6.3 for the same reason.

**What is in it, and deliberately not:**

- Exactly ten modules: `mod_mpm_event`, `mod_unixd`, `mod_authz_core`, `mod_dir`,
  `mod_mime`, `mod_env`, `mod_log_config`, `mod_rewrite`, `mod_proxy`,
  `mod_proxy_fcgi`. The build fails on an eleventh. This matters: `--enable-proxy`
  alone brings 13 proxy submodules, including `mod_proxy_ftp` and `mod_proxy_uwsgi`,
  both with CVEs in 2.4.69's own CHANGES.
- **No mod_ssl, mod_http2 or mod_brotli**, so no OpenSSL, nghttp2 or brotli. The
  edge terminates TLS, and `.php` goes to php-fpm over FastCGI.
- **The macOS bottle's layout**, `.bottle/` included: `bin/httpd`,
  `lib/httpd/modules/`, `.bottle/etc/httpd/mime.types`. rexenv's
  `apache::Layout::for_os("linux")` already reads this, so no Layout change is needed.

**Floor: Ubuntu 22.04 (glibc 2.35), both arches.** `libapr-1.so.0` and
`libaprutil-1.so.0` ship in `lib/` and are found via `RUNPATH $ORIGIN/../lib`. This is
the macOS bundle's `@loader_path` shape. PCRE2 and expat are linked static. The
remaining closure is glibc and `libcrypt.so.1`. Every RUNPATH is `$ORIGIN`-relative.
Compiled-in defaults sit under the placeholder prefix `/opt/rexenv/httpd`, which no
user has. rexenv's conf overrides every one of them that this module set reads, and
the gate checks that no log line names that prefix.

**Gated before publishing**, in a clean `ubuntu:22.04` and `ubuntu:24.04` with
nothing installed and no network. The tree is unpacked under a path with a space.
The gate writes a conf shaped like rexenv's `generate_config`, then runs `httpd -t`,
`httpd -M` (the ten modules) and `httpd -V` (MPM event). On a running server it
checks: a static file 200, an `.htaccess` RewriteRule applied, `/.env` 404, and
`.php` through `mod_proxy_fcgi` to a **real php-fpm** (our static 8.4.27,
`php-8x-linux-1`). Through PHP it also checks `SCRIPT_FILENAME`, `SetEnv`,
`X-Forwarded-Proto: https` → `HTTPS=on`, `FallbackResource` and `DirectoryIndex`.
A stray `.htaccess` above the docroot is ignored.

**This tag is immutable and will never be re-uploaded.** A rebuild is the next build number.

Verify origin:

```sh
gh attestation verify httpd-2.4.69-linux-aarch64.tar.gz --repo rexenv/runtimes
```

## Hand-off to rexenv

| | |
|---|---|
| Tag | `httpd-linux-<n>`, filled in at publish |
| Archive layout | `bin/httpd`, `lib/httpd/modules/mod_*.so` (10), `lib/libapr-1.so.0`, `lib/libaprutil-1.so.0`, `.bottle/etc/httpd/mime.types`. Bottle layout, **no Layout change** |
| Linking | glibc + libcrypt.so.1 dynamic; apr/apr-util bundled via `$ORIGIN` RUNPATH; PCRE2 + expat static |
| Version | **2.4.69** (macOS pins 2.4.68), so `httpd_version_on("linux")` must answer 2.4.69 as Windows does |

Sources, each checked against its project's published digest before the build:

| Source | SHA-256 |
|---|---|
| `https://archive.apache.org/dist/httpd/httpd-2.4.69.tar.bz2` | `c5e6ebc66e349b87d7fc6916ae7cc2a808ed348003de134cf9e9d89d3e2cc73d` |
| `https://archive.apache.org/dist/apr/apr-1.7.6.tar.bz2` | `49030d92d2575da735791b496dc322f3ce5cff9494779ba8cc28c7f46c5deb32` |
| `https://archive.apache.org/dist/apr/apr-util-1.6.5.tar.bz2` | `96de1dd6f6a0476d2d2e7964926d8c1ddc3bb0e210e1b1812d3ba5a454a392e2` |
| `https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.gz` | `c08ae2388ef333e8403e670ad70c0a11f1eed021fd88308d7e02f596fcd9dc16` |
| `https://github.com/libexpat/libexpat/releases/download/R_2_9_0/expat-2.9.0.tar.gz` | `16afbb9cefead2aa278105cf27d9f597bde7fbf3dbb85015857ca7ca6a4e89ba` |

Assets of this release (filled in from the publishing run's `SHA256SUMS`):

| Asset | SHA-256 |
|---|---|
| `httpd-2.4.69-linux-x86_64.tar.gz` | _publish run_ |
| `httpd-2.4.69-linux-aarch64.tar.gz` | _publish run_ |
| `licenses-httpd-2.4.69-linux-x86_64.tar.gz` | _publish run_ |
| `licenses-httpd-2.4.69-linux-aarch64.tar.gz` | _publish run_ |
