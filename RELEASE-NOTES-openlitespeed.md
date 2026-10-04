OpenLiteSpeed for macOS and Linux, built by rexenv — `bin/openlitespeed` plus
`conf/mime.properties` per target: macOS arm64 and x86_64, Linux x86_64 and aarch64.

Built by `.github/workflows/openlitespeed.yml` with `scripts/build-openlitespeed.sh`,
from the litespeedtech/openlitespeed release tag and pinned sources of lsquic,
ls-qpack, ls-hpack, BoringSSL, brotli, libbcrypt, udns, PCRE2, zlib and expat — all
mirrored in this release, with the patch set (`*-rexenv-patches.tar.gz`), so the
corresponding source of this GPL-3.0 program is on this page.

**What differs from upstream** (each patch file explains itself):

- `0001` the community tap's macOS portability fixes, rebased to this version;
- `0002` no `statDir` and no `/dev/shm` no longer crashes the server at start;
- `0003` `LSWS_TMP_DIR` replaces the compiled-in `/tmp/lshttpd` (pid files, swap,
  status, sockets) — one server per site, each under its own directory;
- `0004` `noRemoteFetch 1` turns off the release check (which reports version, OS
  and platform to openlitespeed.org) and the QUIC.cloud IP download.
- `0005` the server no longer runs `dseditgroup`/`usermod` at every start unless
  it is root and the `lsadm` user exists.

No admin console is used or needed (`disableWebAdmin 1`); no lsphp is shipped —
rexenv sends PHP to its own php-fpm pools over FastCGI.

**Floors:** macOS `minos 12.0`, asserted per artifact. Linux built on Ubuntu 22.04,
so glibc 2.35; libstdc++ and libgcc are static; the gate allows only glibc and
libcrypt as shared libraries.

**Every artifact served before it was published**: static, a subdirectory, PHP over
FastCGI, the cache module (miss, then hit), an `.htaccess` rewrite — with no remote
fetch in the log and no runtime file outside `LSWS_TMP_DIR`.

**This tag is immutable and will never be re-uploaded.** A rebuild is the next
build number.
