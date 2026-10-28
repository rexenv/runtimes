#!/bin/bash
# Build MariaDB for Linux (x86_64, aarch64) — inside the ubuntu:22.04 build
# container that scripts/linux-build.sh starts. Not meant to run anywhere else.
#
#   VERSION=<12.3.3|11.4.13> scripts/build-mariadb.sh <aarch64|x86_64> <out-dir>
#
# ─── Why this exists ─────────────────────────────────────────────────────────
#
# rexenv's macOS MariaDB is a Homebrew bottle bundle; Homebrew's Linux bottles
# are x86_64-only, so rexenv's Linux catalog had none and `ships_on` refused it
# (D-L8). MariaDB's own Linux tarballs are systemd-era glibc builds that carry the
# whole server — plugins, test suite, scripts — and link the host's ncurses,
# libaio and libssl. Built here from the mariadb.org source tarball instead.
#
# ─── What ships, and only that (rexenv's core/mariadb.rs reads these) ────────
#
#   bin/mariadbd  bin/mariadb  bin/mariadb-dump
#   share/mysql/mariadb_system_tables.sql
#   share/mysql/mariadb_performance_tables.sql
#   share/mysql/mariadb_system_tables_data.sql
#   share/mysql/english/errmsg.sys
#   share/mysql/charsets/
#
# Init is `mariadbd --bootstrap` with those three files over stdin — no install
# script, so none ships. No dynamic plugins, no test suite: only the three
# targets are built, and the server's STATIC plugins (InnoDB, Aria, MyISAM, CSV,
# MEMORY, perfschema, unix_socket auth, …) are inside mariadbd as in any build.
# That is the macOS bundle's shape too: it carries no lib/plugin.
#
# ─── Linking: glibc + libcrypt, everything else static ───────────────────────
#
#   TLS      OpenSSL 3.6, built here from source and linked STATIC into the
#            server and both clients — the library the macOS bundle carries
#            (openssl@3), so TLS behaves alike on both. NOT the source tree's
#            bundled wolfSSL: with a wolfSSL server, Connector/C (the clients)
#            insists on GnuTLS on Linux ("that's what debian wants",
#            cmake/mariadb_connector_c.cmake) and has no TLS-off mode at all
#            (anything else is "Invalid TLS/SSL option" — measured), and a static
#            GnuTLS is nettle + gmp + libtasn1 + libunistring. OPENSSLDIR is
#            /usr/lib/ssl, Ubuntu's own, so a client that ever verifies a
#            certificate finds the system's CA store; the install prefix is a
#            placeholder (/opt/rexenv/openssl) no user has.
#   zlib     WITH_ZLIB=bundled  — from the source tree, static.
#   PCRE2    WITH_PCRE=bundled  — 10.47 (the version the source pins), static.
#   libfmt   WITH_LIBFMT=bundled — header-only, compiled in.
#   readline WITH_READLINE=ON   — the bundled readline, over a STATIC libtinfo.
#   C++      -static-libstdc++ -static-libgcc (the OpenLiteSpeed build does the same).
#   AIO      neither libaio nor liburing: neither is in a stock Ubuntu (24.04 even
#            renamed libaio's SONAME), and InnoDB falls back to its own thread-pool
#            I/O — right for a dev database, and measured by the gate.
#
# The bundled PCRE2 and libfmt are FETCHED by MariaDB's cmake at build time
# (ExternalProject, MD5-checked). Both URLs are rewritten below to files this
# script fetched and checked against their projects' SHA-256 — a build step that
# downloads its own dependency is a source this repo would otherwise not have
# verified, and could not mirror.
set -euo pipefail

ARCH="${1:?arch required: aarch64|x86_64}"
OUT="${2:?output dir required}"
HERE=/src
# shellcheck source=linux-common.sh
. "$HERE/scripts/linux-common.sh"

MARIADB_VERSION="${VERSION:-12.3.3}"
# Digests: archive.mariadb.org/mariadb-<v>/source/sha256sums.txt
case "$MARIADB_VERSION" in
  12.3.3)  MARIADB_SHA256=e99d739fd4a55f9a11dea7bd2287a262673e287550af3071c8469dd2bec0c163 ;;
  11.4.13) MARIADB_SHA256=1bb254b106d0a7ca871cfa18fa6e18d4b80a7430f9ec9d1571ec4271a13def96 ;;
  *) fail "no pinned sha256 for mariadb $MARIADB_VERSION — add it from archive.mariadb.org/mariadb-$MARIADB_VERSION/source/sha256sums.txt" ;;
esac
# What both versions' cmake/pcre.cmake and cmake/libfmt.cmake ask for (asserted
# below — a version that asks for another one stops the build, not the gate).
PCRE2_VERSION=10.47
PCRE2_SHA256=c08ae2388ef333e8403e670ad70c0a11f1eed021fd88308d7e02f596fcd9dc16  # GitHub release asset digest
FMT_VERSION=12.2.0
FMT_SHA256=a2f4a8d51178f954e4c339007f77edd76ba0cb2e36f87a48e5a5403d9be5878f    # GitHub release asset digest
OPENSSL_VERSION=3.6.5
OPENSSL_SHA256=a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98 # GitHub release asset digest (openssl/openssl)
OSSL=/opt/rexenv/openssl
P=/opt/rexenv/mariadb

assert_build_host "$ARCH"
say "toolchain"
# Deliberately NOT installed: libssl-dev (OpenSSL is built below), zlib1g-dev, libpcre2-dev, libaio-dev,
# liburing-dev, libsystemd-dev, libpam-dev, libkrb5-dev, liblz4/zstd/snappy/lzma
# -dev — each would be found by cmake and linked dynamically.
apt_install build-essential cmake bison pkg-config libncurses-dev ca-certificates curl file binutils perl

WORK="$(mktemp -d)"
cd "$WORK"
say "fetch (verified against the published digests)"
SRC="mariadb-$MARIADB_VERSION.tar.gz"
fetch_verified "https://archive.mariadb.org/mariadb-$MARIADB_VERSION/source/$SRC" "$SRC" "$MARIADB_SHA256"
fetch_verified "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz" \
  "pcre2-$PCRE2_VERSION.tar.gz" "$PCRE2_SHA256"
fetch_verified "https://github.com/fmtlib/fmt/releases/download/$FMT_VERSION/fmt-$FMT_VERSION.zip" \
  "fmt-$FMT_VERSION.zip" "$FMT_SHA256"
fetch_verified "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
  "openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA256"
tar xzf "/cache/$SRC"
S="$WORK/mariadb-$MARIADB_VERSION"

say "pin the two build-time downloads to verified local files"
perl -0pi -e "s{URL \"https://github\.com/PCRE2Project/pcre2/releases/download/pcre2-\Q$PCRE2_VERSION\E/pcre2-\Q$PCRE2_VERSION\E\.zip\"\s*URL_MD5 [0-9a-f]+}{URL \"file:///cache/pcre2-$PCRE2_VERSION.tar.gz\"\n    URL_HASH SHA256=$PCRE2_SHA256}" "$S/cmake/pcre.cmake"
perl -0pi -e "s{URL \"https://github\.com/fmtlib/fmt/releases/download/\Q$FMT_VERSION\E/fmt-\Q$FMT_VERSION\E\.zip\"\s*URL_MD5 [0-9a-f]+}{URL \"file:///cache/fmt-$FMT_VERSION.zip\"\n               URL_HASH SHA256=$FMT_SHA256}" "$S/cmake/libfmt.cmake"
has "file:///cache/pcre2-$PCRE2_VERSION.tar.gz" "$(cat "$S/cmake/pcre.cmake")" \
  || fail "cmake/pcre.cmake no longer asks for pcre2 $PCRE2_VERSION — update PCRE2_VERSION and its digest"
has "file:///cache/fmt-$FMT_VERSION.zip" "$(cat "$S/cmake/libfmt.cmake")" \
  || fail "cmake/libfmt.cmake no longer asks for fmt $FMT_VERSION — update FMT_VERSION and its digest"
# The RHEL-7 branch of libfmt.cmake (gcc < 4.9) still names a URL; GCC 11 never
# takes it. Anything ELSE still pointing at the network would be a surprise:
LEFT="$(grep -nE 'URL +"https?://' "$S/cmake/pcre.cmake" "$S/cmake/libfmt.cmake" | grep -v 'fmt-11\.0\.2' || true)"
[ -z "$LEFT" ] || fail "a build-time download is still unpinned: $LEFT"

TRIPLE="$(gcc -dumpmachine)"
TINFO="/usr/lib/$TRIPLE/libtinfo.a"
[ -f "$TINFO" ] || fail "$TINFO missing (libncurses-dev)"

say "openssl $OPENSSL_VERSION (static)"
case "$ARCH" in x86_64) OSSL_TARGET=linux-x86_64 ;; aarch64) OSSL_TARGET=linux-aarch64 ;; esac
tar xzf "/cache/openssl-$OPENSSL_VERSION.tar.gz" -C "$WORK"
( cd "$WORK/openssl-$OPENSSL_VERSION" \
  && ./Configure "$OSSL_TARGET" no-shared no-tests no-docs -fPIC --prefix="$OSSL" --libdir=lib --openssldir=/usr/lib/ssl \
       > "$WORK/openssl-configure.log" 2>&1 \
  && make -j"$JOBS" > "$WORK/openssl-make.log" 2>&1 && make install_sw > "$WORK/openssl-install.log" 2>&1 ) \
  || { tail -40 "$WORK"/openssl-*.log; fail "openssl did not build"; }
[ -f "$OSSL/lib/libssl.a" ] && [ ! -e "$OSSL/lib/libssl.so" ] || fail "openssl did not produce a static-only libssl"

say "configure"
NO_PLUGINS=()
for p in ROCKSDB COLUMNSTORE DUCKDB MROONGA SPIDER CONNECT OQGRAPH SPHINX S3 TOKUDB VIDEX \
         AUTH_PAM AUTH_PAM_V1 AUTH_GSSAPI HASHICORP_KEY_MANAGEMENT AWS_KEY_MANAGEMENT CRACKLIB_PASSWORD_CHECK \
         PROVIDER_BZIP2 PROVIDER_LZ4 PROVIDER_LZMA PROVIDER_LZO PROVIDER_SNAPPY; do
  NO_PLUGINS+=("-DPLUGIN_$p=NO")
done
mkdir -p "$WORK/build"
cd "$WORK/build"
cmake "$S" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_INSTALL_PREFIX="$P" -DINSTALL_MYSQLSHAREDIR=share/mysql -DINSTALL_PLUGINDIR=lib/plugin \
  -DWITH_SSL=system -DOPENSSL_ROOT_DIR="$OSSL" -DOPENSSL_USE_STATIC_LIBS=TRUE -DWITH_ZLIB=bundled -DWITH_PCRE=bundled -DWITH_LIBFMT=bundled \
  -DWITH_READLINE=ON -DCURSES_LIBRARY="$TINFO" -DCURSES_INCLUDE_PATH=/usr/include \
  -DWITH_SYSTEMD=no -DWITH_WSREP=OFF -DWITH_UNIT_TESTS=OFF -DWITH_EMBEDDED_SERVER=OFF \
  -DWITH_MARIABACKUP=OFF -DWITH_NUMA=NO -DWITH_URING=OFF -DWITH_LIBAIO=OFF -DCONC_WITH_UNIT_TESTS=OFF \
  -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++ -static-libgcc" \
  "${NO_PLUGINS[@]}" > "$WORK/cmake.log" 2>&1 \
  || { tail -60 "$WORK/cmake.log"; fail "cmake failed"; }
# What cmake decided, read back rather than assumed: a dependency it found on the
# system instead of the bundle is the failure mode this whole header is about.
CACHE_TXT="$(cat CMakeCache.txt)"
# By value, not type: 11.4 keeps WITH_SSL as `:UNINITIALIZED=system`, 12.3 as `:STRING=system`.
for want in 'WITH_SSL:[A-Z]+=system' 'WITH_ZLIB:[A-Z]+=bundled' 'WITH_PCRE:[A-Z]+=bundled'; do
  has "^$want$" "$CACHE_TXT" || { grep -E '^(WITH_SSL|WITH_ZLIB|WITH_PCRE|OPENSSL_[A-Z_]+)[:=]' CMakeCache.txt; grep -iE 'ssl' "$WORK/cmake.log" | tail -15; fail "CMakeCache does not say $want"; }
done
has "^OPENSSL_SSL_LIBRARY:FILEPATH=$OSSL/lib/libssl\.a$" "$CACHE_TXT" \
  || fail "cmake did not pick our static libssl: $(grep '^OPENSSL_SSL_LIBRARY' CMakeCache.txt)"

say "build (mariadbd, mariadb, mariadb-dump — nothing else)"
time cmake --build . -j"$JOBS" --target mariadbd mariadb mariadb-dump GenError > "$WORK/make.log" 2>&1 \
  || { grep -E 'error|Error' "$WORK/make.log" | head -40; tail -30 "$WORK/make.log"; fail "build failed"; }

say "package"
PKG="$WORK/pkg"
mkdir -p "$PKG/bin" "$PKG/share/mysql/english"
cp sql/mariadbd client/mariadb client/mariadb-dump "$PKG/bin/"
strip --strip-debug "$PKG"/bin/*
for f in mariadb_system_tables.sql mariadb_performance_tables.sql mariadb_system_tables_data.sql; do
  cp "$S/scripts/$f" "$PKG/share/mysql/$f"
done
ERRMSG="$(find "$WORK/build" -path '*/english/errmsg.sys' | head -1)"
[ -s "$ERRMSG" ] || fail "errmsg.sys was not generated (GenError)"
cp "$ERRMSG" "$PKG/share/mysql/english/errmsg.sys"
cp -R "$S/sql/share/charsets" "$PKG/share/mysql/charsets"
[ -s "$PKG/share/mysql/charsets/Index.xml" ] || fail "charsets/Index.xml missing"

say "static gates (the clean-container gates run after, from linux-build.sh)"
elf_gate '' "$PKG"/bin/*
V="$("$PKG/bin/mariadbd" --version)"
echo "$V"
has "Ver $MARIADB_VERSION-MariaDB" "$V" || fail "wrong version: $V"
has "$MARIADB_VERSION-MariaDB" "$("$PKG/bin/mariadb" --version)" || fail "client version"
# The TLS library is OUR static OpenSSL, by the binaries' own account.
for b in mariadbd mariadb; do
  has "OpenSSL $OPENSSL_VERSION " "$(strings "$PKG/bin/$b" | grep -m3 '^OpenSSL [0-9]' || true)" \
    || fail "$b does not carry OpenSSL $OPENSSL_VERSION"
done
if grep -aF -- "$WORK" "$PKG"/bin/* >/dev/null; then
  # __FILE__ strings from asserts are the only legitimate source; they are paths,
  # never opened. Recorded, not fatal — the clean-container gate runs from
  # elsewhere and is what proves no build path is READ.
  echo "  note: binaries carry build-tree __FILE__ strings ($(grep -caF -- "$WORK" "$PKG/bin/mariadbd") in mariadbd)"
fi

say "licences"
LIC="$WORK/lic/licenses"
mkdir -p "$LIC"
cp "$S/COPYING"                          "$LIC/mariadb.COPYING"            # GPL-2.0
cp "$S/THIRDPARTY"                       "$LIC/mariadb.THIRDPARTY"         # every bundled third-party notice
cp "$S/libmariadb/COPYING.LIB"           "$LIC/libmariadb.COPYING.LIB"     # LGPL-2.1 (client library, static)
cp "$WORK/openssl-$OPENSSL_VERSION/LICENSE.txt" "$LIC/openssl.LICENSE.txt" # Apache-2.0
cp "$S/zlib/LICENSE"                     "$LIC/zlib.LICENSE"
cp "$S/extra/readline/COPYING"           "$LIC/readline.COPYING"           # GPL-2.0 (bundled readline 5.x)
tar xzf "/cache/pcre2-$PCRE2_VERSION.tar.gz" -C "$WORK" "pcre2-$PCRE2_VERSION/LICENCE.md"
cp "$WORK/pcre2-$PCRE2_VERSION/LICENCE.md" "$LIC/pcre2.LICENCE.md"         # BSD-3
FMT_LIC="$(find "$WORK/build" -path '*libfmt/LICENSE*' | head -1)"
[ -n "$FMT_LIC" ] || fail "libfmt's LICENSE not found in the extracted bundle"
cp "$FMT_LIC"                            "$LIC/fmt.LICENSE"                # MIT
# Linked in static from the build host, so their terms travel too.
cp /usr/share/doc/libtinfo6/copyright    "$LIC/ncurses-libtinfo.copyright" # X11/MIT
cp "/usr/share/doc/gcc-$(gcc -dumpversion)-base/copyright" "$LIC/gcc-runtime.copyright"  # libstdc++/libgcc: GPL-3 + runtime exception
pack_licences "$OUT/licenses-mariadb-$MARIADB_VERSION-linux-$ARCH.tar.gz" "$WORK/lic"

NAME="mariadb-$MARIADB_VERSION-linux-$ARCH.tar.gz"
pack "$OUT/$NAME" "$PKG" bin share
# GPL-2.0: the corresponding source rides the binaries — the MariaDB tarball, the
# two bundles its build fetched, OpenSSL, and the scripts that drove it.
cp "/cache/$SRC" "/cache/pcre2-$PCRE2_VERSION.tar.gz" "/cache/fmt-$FMT_VERSION.zip" "/cache/openssl-$OPENSSL_VERSION.tar.gz" "$OUT/"
pack_build_scripts "$OUT/mariadb-$MARIADB_VERSION-rexenv-build.tar.gz" mariadb
checksum_out "$OUT" "$NAME" "licenses-mariadb-$MARIADB_VERSION-linux-$ARCH.tar.gz"
echo "$NAME" > "$OUT/.artifact"
chown -R "${HOST_UID:-0}:${HOST_GID:-0}" "$OUT"
ls -l "$OUT"
say "record"
echo "mariadb $MARIADB_VERSION / openssl $OPENSSL_VERSION / pcre2 $PCRE2_VERSION / fmt $FMT_VERSION / linux / $ARCH / gcc $(gcc -dumpfullversion)"
