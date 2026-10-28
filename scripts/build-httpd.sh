#!/bin/bash
# Build Apache httpd for Linux (x86_64, aarch64) — inside the ubuntu:22.04 build
# container that scripts/linux-build.sh starts. Not meant to run anywhere else.
#
#   scripts/build-httpd.sh <aarch64|x86_64> <out-dir>
#
# ─── Why this exists ─────────────────────────────────────────────────────────
#
# rexenv runs httpd per site as a loopback OVERRIDE backend behind the Caddy
# edge, for one reason: `.htaccess` (core/apache.rs). On macOS that is a Homebrew
# bottle bundle; Homebrew's Linux bottles are x86_64-only, so Linux had none and
# `ships_on` refused it (D-L8). Built here from the ASF tarballs.
#
# ─── What rexenv needs, which is very little ─────────────────────────────────
#
# The generated conf loads TEN modules and nothing else: mpm_event, unixd,
# authz_core, dir, mime, env, log_config, rewrite, proxy, proxy_fcgi. The edge
# terminates TLS and speaks HTTP/2, and `.php` goes to php-fpm over FastCGI — so
# no mod_ssl, mod_http2 or mod_brotli, and therefore no OpenSSL, nghttp2 or brotli
# anywhere in this artifact. `--enable-modules=none` builds exactly the ten and
# the gate below refuses an eleventh.
#
# ─── The layout, kept identical to the macOS bottle's ────────────────────────
#
#   bin/httpd
#   lib/httpd/modules/mod_*.so          (the ten)
#   lib/libapr-1.so.0, lib/libaprutil-1.so.0
#   .bottle/etc/httpd/mime.types        (the bottle's odd path, kept on purpose)
#
# rexenv's `apache::Layout::for_os` gives every non-Windows OS the bottle layout,
# so matching it means Linux needs NO Layout arm in rexenv — the same conf text,
# the same holes, as macOS. The `.bottle/` path is ugly and costs nothing.
#
# ─── Linking: glibc + two bundled libraries via $ORIGIN ──────────────────────
#
# apr and apr-util ship as shared libraries beside the binary, found through
# RUNPATH $ORIGIN/../lib — the shape the macOS bundle has with @loader_path. Not
# static: the modules are dlopen()ed and resolve apr symbols from the process, and
# a static libapr inside httpd would carry only the objects httpd itself
# references, so a module needing one more would fail to load at a user's first
# request. PCRE2 and expat (apr-util's XML parser) are linked in static, so the
# closure is glibc + libcrypt.so.1 + those two. libtool writes an absolute RUNPATH
# into everything it links; patchelf replaces it with $ORIGIN — on our OWN fresh
# build, the gates read the result — so no path of this container survives.
#
# Compiled-in paths: the prefix is /opt/rexenv/httpd, a directory no user has.
# rexenv's conf sets ServerRoot, PidFile, DefaultRuntimeDir, ErrorLog and
# TypesConfig and passes -f, which covers every default `httpd -V` reports that
# this module set reads; the gate runs from an unrelated directory to prove it.
set -euo pipefail

ARCH="${1:?arch required: aarch64|x86_64}"
OUT="${2:?output dir required}"
HERE=/src
# shellcheck source=linux-common.sh
. "$HERE/scripts/linux-common.sh"

HTTPD_VERSION="${VERSION:-2.4.69}"
APR_VERSION=1.7.6
APR_UTIL_VERSION=1.6.5
PCRE2_VERSION=10.47
EXPAT_VERSION=2.9.0
# Digests: the ASF's own .sha256 beside each tarball (downloads.apache.org);
# PCRE2 and expat from the GitHub release assets' published digests.
case "$HTTPD_VERSION" in
  2.4.69) HTTPD_SHA256=c5e6ebc66e349b87d7fc6916ae7cc2a808ed348003de134cf9e9d89d3e2cc73d ;;
  *) fail "no pinned sha256 for httpd $HTTPD_VERSION — add the ASF's published .sha256" ;;
esac
APR_SHA256=49030d92d2575da735791b496dc322f3ce5cff9494779ba8cc28c7f46c5deb32
APR_UTIL_SHA256=96de1dd6f6a0476d2d2e7964926d8c1ddc3bb0e210e1b1812d3ba5a454a392e2
PCRE2_SHA256=c08ae2388ef333e8403e670ad70c0a11f1eed021fd88308d7e02f596fcd9dc16
EXPAT_SHA256=16afbb9cefead2aa278105cf27d9f597bde7fbf3dbb85015857ca7ca6a4e89ba

# The ten, in rexenv's names (core/apache.rs MPM_MODULES + MODULES).
MODS=(mpm_event unixd authz_core dir mime env log_config rewrite proxy proxy_fcgi)
P=/opt/rexenv/httpd

assert_build_host "$ARCH"
say "toolchain"
# Deliberately NOT installed: libpcre2-dev, libexpat1-dev, uuid-dev, libssl-dev.
# Each would be found by a configure script and linked dynamically.
apt_install build-essential ca-certificates curl file binutils patchelf

WORK="$(mktemp -d)"
cd "$WORK"
say "fetch (verified against the published digests)"
ASF=https://archive.apache.org/dist
fetch_verified "$ASF/httpd/httpd-$HTTPD_VERSION.tar.bz2"        "httpd-$HTTPD_VERSION.tar.bz2"   "$HTTPD_SHA256"
fetch_verified "$ASF/apr/apr-$APR_VERSION.tar.bz2"              "apr-$APR_VERSION.tar.bz2"       "$APR_SHA256"
fetch_verified "$ASF/apr/apr-util-$APR_UTIL_VERSION.tar.bz2"    "apr-util-$APR_UTIL_VERSION.tar.bz2" "$APR_UTIL_SHA256"
fetch_verified "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz" \
  "pcre2-$PCRE2_VERSION.tar.gz" "$PCRE2_SHA256"
fetch_verified "https://github.com/libexpat/libexpat/releases/download/R_${EXPAT_VERSION//./_}/expat-$EXPAT_VERSION.tar.gz" \
  "expat-$EXPAT_VERSION.tar.gz" "$EXPAT_SHA256"
for f in httpd-$HTTPD_VERSION.tar.bz2 apr-$APR_VERSION.tar.bz2 apr-util-$APR_UTIL_VERSION.tar.bz2; do tar xjf "/cache/$f"; done
for f in pcre2-$PCRE2_VERSION.tar.gz expat-$EXPAT_VERSION.tar.gz; do tar xzf "/cache/$f"; done

run() {   # <log> <cmd…> — quiet on success, the tail on failure
  local log="$WORK/$1.log"; shift
  "$@" > "$log" 2>&1 || { tail -40 "$log"; fail "$(basename "$log" .log) failed"; }
}
DEPS="$WORK/deps"
say "expat $EXPAT_VERSION (static, PIC: it lands inside libaprutil.so)"
( cd "expat-$EXPAT_VERSION" && run expat-configure ./configure --prefix="$DEPS" --disable-shared --enable-static --with-pic \
    --without-docbook --without-examples --without-tests --without-xmlwf && run expat-make make -j"$JOBS" install )
say "pcre2 $PCRE2_VERSION (static)"
( cd "pcre2-$PCRE2_VERSION" && run pcre2-configure ./configure --prefix="$DEPS" --disable-shared --enable-static --with-pic \
    && run pcre2-make make -j"$JOBS" install )
say "apr $APR_VERSION"
( cd "apr-$APR_VERSION" && run apr-configure ./configure --prefix="$P" --disable-static \
    && run apr-make make -j"$JOBS" && run apr-install make install )
say "apr-util $APR_UTIL_VERSION"
# Every optional backend off: no database drivers, no LDAP, no crypto, no DBM but
# the built-in SDBM. Nothing in the ten modules uses any of them.
( cd "apr-util-$APR_UTIL_VERSION" && run apu-configure ./configure --prefix="$P" --disable-static \
    --with-apr="$P/bin/apr-1-config" --with-expat="$DEPS" --without-crypto --without-ldap \
    --without-pgsql --without-mysql --without-sqlite2 --without-sqlite3 --without-oracle --without-freetds \
    --without-odbc --without-berkeley-db --without-gdbm --without-ndbm \
    && run apu-make make -j"$JOBS" && run apu-install make install )

say "httpd $HTTPD_VERSION"
cd "httpd-$HTTPD_VERSION"
SHARED="$(printf '%s ' "${MODS[@]}" | sed 's/mpm_event //')"
# --enable-modules=none is not enough on its own: enabling `proxy` turns on every
# proxy_* and lbmethod_* submodule with it (measured: 24 modules built where ten
# were asked for, mod_proxy_ftp and mod_proxy_uwsgi among them — both with CVEs in
# 2.4.69's own CHANGES). Each is switched off by name.
NO_PROXY_SUBMODULES=()
for m in proxy-connect proxy-ftp proxy-http proxy-scgi proxy-uwsgi proxy-fdpass proxy-wstunnel \
         proxy-ajp proxy-balancer proxy-express proxy-hcheck proxy-http2 \
         lbmethod-byrequests lbmethod-bytraffic lbmethod-bybusyness lbmethod-heartbeat; do
  NO_PROXY_SUBMODULES+=("--disable-$m")
done
run httpd-configure ./configure --prefix="$P" "${NO_PROXY_SUBMODULES[@]}" \
  --libexecdir="$P/lib/httpd/modules" --sysconfdir="$P/etc/httpd" \
  --with-apr="$P/bin/apr-1-config" --with-apr-util="$P/bin/apu-1-config" \
  --with-pcre="$DEPS/bin/pcre2-config" \
  --enable-so --enable-modules=none --enable-mods-shared="$SHARED" \
  --with-mpm=event --enable-mpms-shared=event
run httpd-make make -j"$JOBS"
run httpd-install make install
cd "$WORK"

say "package"
PKG="$WORK/pkg"
mkdir -p "$PKG/bin" "$PKG/lib/httpd/modules" "$PKG/.bottle/etc/httpd"
cp "$P/bin/httpd" "$PKG/bin/httpd"
# By SONAME, as real files: the loader asks for libapr-1.so.0, and an archive
# rexenv unpacks should not have to carry symlinks.
for l in libapr-1 libaprutil-1; do
  so="$(readelf -d "$P/lib/$l.so" | awk -F'[][]' '/\(SONAME\)/{print $2}')"
  [ "$so" = "$l.so.0" ] || fail "$l SONAME is $so, expected $l.so.0"
  cp -L "$P/lib/$l.so" "$PKG/lib/$so"
done
for m in "${MODS[@]}"; do cp "$P/lib/httpd/modules/mod_$m.so" "$PKG/lib/httpd/modules/"; done
cp "$P/etc/httpd/mime.types" "$PKG/.bottle/etc/httpd/mime.types"
# Exactly the ten were BUILT, not merely copied: an eleventh means the configure
# line no longer says what this header says.
BUILT="$(cd "$P/lib/httpd/modules" && ls mod_*.so | sort | tr '\n' ' ')"
WANT="$(printf 'mod_%s.so\n' "${MODS[@]}" | sort | tr '\n' ' ')"
[ "$BUILT" = "$WANT" ] || fail "built modules: $BUILT — want exactly: $WANT"

patchelf --set-rpath '$ORIGIN/../lib' "$PKG/bin/httpd"
patchelf --set-rpath '$ORIGIN' "$PKG/lib/libaprutil-1.so.0"
patchelf --remove-rpath "$PKG/lib/libapr-1.so.0"
for m in "$PKG"/lib/httpd/modules/*.so; do
  # A module that NEEDS apr directly finds it two levels up; one that does not
  # (the usual case — symbols come from the process) carries no RUNPATH at all.
  if has 'libapr' "$(readelf -d "$m" | awk -F'[][]' '/\(NEEDED\)/{print $2}')"; then
    patchelf --set-rpath '$ORIGIN/../..' "$m"
  else
    patchelf --remove-rpath "$m"
  fi
done
find "$PKG" -type f \( -name httpd -o -name '*.so*' \) -exec strip --strip-debug {} +

say "static gates (the clean-container gates run after, from linux-build.sh)"
mapfile -t ELFS < <(find "$PKG" -type f \( -name httpd -o -name '*.so*' \) | sort)
elf_gate 'libapr-1\.so\.0|libaprutil-1\.so\.0' "${ELFS[@]}"
# No OpenSSL, nghttp2, brotli, system pcre or expat — by NEEDED (above) and by
# what the binary admits to.
VV="$("$PKG/bin/httpd" -V)"
echo "$VV"
has "Apache/$HTTPD_VERSION " "$VV" || fail "wrong httpd version"
# Every compiled-in path is under the placeholder prefix, never this container's
# work tree. rexenv's conf overrides each one the ten modules read; the gate runs
# httpd from another directory to prove nothing else is consulted.
if grep -aF -- "$WORK" "${ELFS[@]}" >/dev/null; then fail "a binary embeds the build directory $WORK"; fi
has "HTTPD_ROOT=\"$P\"" "$VV" || fail "HTTPD_ROOT is not the placeholder prefix"

say "licences"
LIC="$WORK/lic/licenses"
mkdir -p "$LIC"
# Named LICENSE/NOTICE at the top, as the Windows release does (httpd-windows.yml
# asserts licenses/LICENSE) — the server's own terms first.
cp "httpd-$HTTPD_VERSION/LICENSE"        "$LIC/LICENSE"                 # Apache-2.0 (+ bundled-code notices)
cp "httpd-$HTTPD_VERSION/NOTICE"         "$LIC/NOTICE"
cp "apr-$APR_VERSION/LICENSE"            "$LIC/apr.LICENSE"             # Apache-2.0
cp "apr-$APR_VERSION/NOTICE"             "$LIC/apr.NOTICE"
cp "apr-util-$APR_UTIL_VERSION/LICENSE"  "$LIC/apr-util.LICENSE"        # Apache-2.0
cp "apr-util-$APR_UTIL_VERSION/NOTICE"   "$LIC/apr-util.NOTICE"
cp "pcre2-$PCRE2_VERSION/LICENCE.md"     "$LIC/pcre2.LICENCE.md"        # BSD-3
cp "pcre2-$PCRE2_VERSION/COPYING"        "$LIC/pcre2.COPYING"
cp "expat-$EXPAT_VERSION/COPYING"        "$LIC/expat.COPYING"           # MIT
pack_licences "$OUT/licenses-httpd-$HTTPD_VERSION-linux-$ARCH.tar.gz" "$WORK/lic"

NAME="httpd-$HTTPD_VERSION-linux-$ARCH.tar.gz"
pack "$OUT/$NAME" "$PKG" .bottle bin lib
for f in "httpd-$HTTPD_VERSION.tar.bz2" "apr-$APR_VERSION.tar.bz2" "apr-util-$APR_UTIL_VERSION.tar.bz2" \
         "pcre2-$PCRE2_VERSION.tar.gz" "expat-$EXPAT_VERSION.tar.gz"; do cp "/cache/$f" "$OUT/"; done
pack_build_scripts "$OUT/httpd-$HTTPD_VERSION-rexenv-build.tar.gz" httpd
checksum_out "$OUT" "$NAME" "licenses-httpd-$HTTPD_VERSION-linux-$ARCH.tar.gz"
echo "$NAME" > "$OUT/.artifact"
chown -R "${HOST_UID:-0}:${HOST_GID:-0}" "$OUT"
ls -l "$OUT"
say "record"
echo "httpd $HTTPD_VERSION / apr $APR_VERSION / apr-util $APR_UTIL_VERSION / pcre2 $PCRE2_VERSION / expat $EXPAT_VERSION / linux / $ARCH / gcc $(gcc -dumpfullversion)"
