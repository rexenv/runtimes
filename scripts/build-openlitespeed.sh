#!/bin/bash
# Build OpenLiteSpeed for rexenv — macOS (arm64, x86_64) and Linux (x86_64, aarch64)
# from ONE recipe and ONE patch set.
#
#   scripts/build-openlitespeed.sh <macos|linux> <aarch64|x86_64> <out-dir>
#
# ─── Why this exists ─────────────────────────────────────────────────────────
#
# rexenv offers OpenLiteSpeed as a per-site override server (like Apache and
# FrankenPHP): a loopback backend behind the Caddy edge, PHP through the site's
# existing php-fpm pool over FastCGI, `.htaccess`, and — the reason anyone wants
# it — the LSCache module, so a WordPress developer gets the cache their LiteSpeed
# host runs. Upstream publishes Linux tarballs only; nobody publishes a macOS build
# rexenv can trust. A macOS self-build was proven on 4 Oct 2026 (rexenv
# docs/PLAN-openlitespeed.md); this script is that recipe made reproducible.
#
# Linux uses the SAME recipe rather than upstream's tarball (owner ruling, 4 Oct
# 2026): the patches below change behaviour rexenv depends on — where the server
# keeps its runtime files, and that it never phones home — and a binary we did
# not build cannot carry them.
#
# ─── The patch set (patches/openlitespeed/, each file explains itself) ───────
#
#   0001-macos-portability      the community tap's Darwin fixes, rebased to 1.9.3
#   0002-statdir-without-dev-shm  no statDir + no /dev/shm = NULL strcmp, SIGSEGV
#   0003-runtime-tmp-dir        LSWS_TMP_DIR replaces the compiled-in /tmp/lshttpd
#   0004-no-remote-fetch        `noRemoteFetch 1`: no release check, no quic.cloud
#   0005-group-change-only-as-root  no dseditgroup/usermod at every start
#   boringssl-lstls            the LSTLS accessors lsquic expects
#
# ─── Dependencies, all built static from pinned sources ──────────────────────
#
# BoringSSL, brotli, libbcrypt, udns, pcre2, zlib, expat — laid out the way
# upstream's own build.sh lays out `../third-party` and `ssl/` on Linux. Nothing
# comes from Homebrew or apt at link time except the OS's own C/C++ runtime:
#   macOS:  /usr/lib/libSystem.B.dylib, /usr/lib/libc++.1.dylib
#   Linux:  glibc (libc, libm, libpthread, libdl, librt) and libcrypt.so.1;
#           libstdc++/libgcc are linked static. Built on Ubuntu 22.04, so the
#           glibc floor is 2.35 — rexenv's Linux floor.
# libxml2 is on upstream's link line but nothing in the server calls it; it is
# dropped rather than built.
set -euo pipefail

OS="${1:?os required: macos|linux}"
ARCH="${2:?arch required: aarch64|x86_64}"
OUT="${3:?output dir required}"

OLS_VERSION="${OLS_VERSION:-1.9.3}"
LSQUIC_COMMIT="${LSQUIC_COMMIT:-d5929af7cec6fd74f1cfea2cb1c07c27ce9102b1}"   # OLS 1.9.3 LSQUICCOMMIT
LSQPACK_COMMIT="${LSQPACK_COMMIT:-91567706c41c0d97ab8dc576873ecd472d7869fa}" # lsquic's submodule at that commit
LSHPACK_COMMIT="${LSHPACK_COMMIT:-cf0f70dd10b352194c97448eb5d00b4aa484f531}" # ditto
BSSL_COMMIT="${BSSL_COMMIT:-9fc1c33e9c21439ce5f87855a6591a9324e569fd}"       # 2023-06-08, the tap's pin
BROTLI_VERSION="${BROTLI_VERSION:-1.1.0}"
BCRYPT_COMMIT="${BCRYPT_COMMIT:-55ff64349dec3012cfbbb1c4f92d4dbd46920213}"
UDNS_VERSION="${UDNS_VERSION:-0.4}"
PCRE2_VERSION="${PCRE2_VERSION:-10.47}"
ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
EXPAT_VERSION="${EXPAT_VERSION:-2.7.1}"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"   # same floor as nginx and PHP 7.4

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES="$HERE/patches/openlitespeed"

case "$OS/$ARCH" in
  macos/aarch64) MAC_ARCH=arm64  ;;
  macos/x86_64)  MAC_ARCH=x86_64 ;;
  linux/aarch64|linux/x86_64) MAC_ARCH="" ;;
  *) echo "::error::unknown target $OS/$ARCH"; exit 1 ;;
esac
if [ "$OS" = macos ]; then
  CFLAGS_T="-arch $MAC_ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2"
  JOBS="$(sysctl -n hw.ncpu)"
  CMAKE_T=(-DCMAKE_OSX_ARCHITECTURES="$MAC_ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET")
  BSSL_CC=()
else
  CFLAGS_T="-O2 -fPIC"
  JOBS="$(nproc)"
  CMAKE_T=()
  # BoringSSL only: its perlasm emits `#if __has_feature(hwaddress_sanitizer)` into
  # the aarch64 .S files, which GCC's preprocessor rejects ("missing binary
  # operator before token"), measured on 22.04 arm64 with GCC 11, 4 Oct 2026.
  # Static archives from clang link into the GCC-built server like any others.
  BSSL_CC=(-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_ASM_COMPILER=clang)
fi
JOBS="${JOBS_OVERRIDE:-$JOBS}"

say() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
fetch() { curl -fsSL --retry 5 --retry-delay 5 "$1" -o "$2"; }
# BSD and GNU sed disagree on -i; perl does not.
subst() { perl -0pi -e "$1" "$2"; }

WORK="$(mktemp -d)"
# KEEP_WORK=1 leaves the tree for a debugger (the probe root is $WORK/probe).
if [ -n "${KEEP_WORK:-}" ]; then echo "work dir kept: $WORK"; else trap 'rm -rf "$WORK"' EXIT; fi
cd "$WORK"
mkdir -p "$OUT" src
TP="$WORK/third-party"          # upstream's layout: a sibling of the source tree
mkdir -p "$TP/lib" "$TP/include"

# ─── Fetch. Every tarball is mirrored into the release beside the binaries: ───
# rexenv becomes the DISTRIBUTOR of a GPL-3.0 program, and "which source built
# this" must be answerable from the release page alone.
say "fetch"
GH=https://github.com
fetch "$GH/litespeedtech/openlitespeed/archive/refs/tags/v$OLS_VERSION.tar.gz" src/openlitespeed-$OLS_VERSION.tar.gz
fetch "$GH/litespeedtech/lsquic/archive/$LSQUIC_COMMIT.tar.gz"   src/lsquic-$LSQUIC_COMMIT.tar.gz
fetch "$GH/litespeedtech/ls-qpack/archive/$LSQPACK_COMMIT.tar.gz" src/ls-qpack-$LSQPACK_COMMIT.tar.gz
fetch "$GH/litespeedtech/ls-hpack/archive/$LSHPACK_COMMIT.tar.gz" src/ls-hpack-$LSHPACK_COMMIT.tar.gz
fetch "$GH/google/boringssl/archive/$BSSL_COMMIT.tar.gz"          src/boringssl-$BSSL_COMMIT.tar.gz
fetch "$GH/google/brotli/archive/refs/tags/v$BROTLI_VERSION.tar.gz" src/brotli-$BROTLI_VERSION.tar.gz
fetch "$GH/litespeedtech/libbcrypt/archive/$BCRYPT_COMMIT.tar.gz" src/libbcrypt-$BCRYPT_COMMIT.tar.gz
fetch "https://deb.debian.org/debian/pool/main/u/udns/udns_$UDNS_VERSION.orig.tar.gz" src/udns-$UDNS_VERSION.tar.gz
fetch "$GH/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz" src/pcre2-$PCRE2_VERSION.tar.gz
fetch "$GH/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz" src/zlib-$ZLIB_VERSION.tar.gz
fetch "$GH/libexpat/libexpat/releases/download/R_${EXPAT_VERSION//./_}/expat-$EXPAT_VERSION.tar.gz" src/expat-$EXPAT_VERSION.tar.gz
cp src/*.tar.gz "$OUT/"
( cd "$HERE" && COPYFILE_DISABLE=1 tar -czf "$OUT/openlitespeed-$OLS_VERSION-rexenv-patches.tar.gz" patches/openlitespeed scripts/build-openlitespeed.sh scripts/boringssl-err-data.py )

unpack() { mkdir -p "$2" && tar xzf "$1" -C "$2" --strip-components=1; }
unpack src/openlitespeed-$OLS_VERSION.tar.gz ols
# src/liblsquic, src/lshpack, include/lsquic*.h are symlinks into ./lsquic, an
# empty git submodule in the release tarball.
rm -rf ols/lsquic
unpack src/lsquic-$LSQUIC_COMMIT.tar.gz   ols/lsquic
rm -rf ols/lsquic/src/liblsquic/ls-qpack ols/lsquic/src/lshpack
unpack src/ls-qpack-$LSQPACK_COMMIT.tar.gz ols/lsquic/src/liblsquic/ls-qpack
unpack src/ls-hpack-$LSHPACK_COMMIT.tar.gz ols/lsquic/src/lshpack
[ -f ols/src/liblsquic/ls-qpack/lsqpack.h ] && [ -f ols/src/lshpack/lshpack.h ] && [ -f ols/include/lsquic.h ] \
  || { echo "::error::lsquic submodules not where OLS's symlinks expect them"; exit 1; }

say "patch"
for p in "$PATCHES"/0*.patch; do
  echo "  $(basename "$p")"
  ( cd ols && patch -p1 -N -s < "$p" )
done

# ─── BoringSSL ───────────────────────────────────────────────────────────────
say "boringssl"
unpack src/boringssl-$BSSL_COMMIT.tar.gz boringssl
( cd boringssl && patch -p1 -N -s < "$PATCHES/boringssl-lstls.patch" )
# BoringSSL's cmake/go.cmake is FATAL without Go, and its build GENERATES
# crypto/err_data.c with `go run err_data_generate.go`. A stub `go` that does
# nothing is NOT enough: make re-runs the rule and an empty err_data.c still
# links, leaving kOpenSSLReasonValues undefined until the final OLS link
# (measured 4 Oct 2026). So `go` here is a wrapper that answers exactly that one
# invocation with the Python port and refuses everything else — on every OS, so
# no artifact depends on a Go toolchain a runner happens to have.
mkdir -p "$WORK/fakego"
cat > "$WORK/fakego/go" <<EOS
#!/bin/sh
if [ "\$1" = run ] && [ "\$2" = err_data_generate.go ]; then exec python3 "$HERE/scripts/boringssl-err-data.py"; fi
echo "fake go: refusing '\$*' — only err_data_generate.go is expected in a non-FIPS build" >&2; exit 1
EOS
chmod +x "$WORK/fakego/go"
( cd boringssl && mkdir -p build && cd build \
  && cmake .. -DCMAKE_BUILD_TYPE=Release -DGO_EXECUTABLE="$WORK/fakego/go" \
       -DCMAKE_C_FLAGS="-fPIC" -DCMAKE_CXX_FLAGS="-fPIC" "${CMAKE_T[@]}" ${BSSL_CC[@]+"${BSSL_CC[@]}"} >/dev/null \
  && make -j"$JOBS" crypto ssl decrepit >/dev/null )
# Captured, never piped into grep -q: under pipefail, grep exiting at the first
# match SIGPIPEs the producer and the PASSING check reports failure (cost two
# builds, 4 Oct 2026).
has() { grep -qE "$1" <<<"$2"; }
has ' [RSD] _?kOpenSSLReasonValues$' "$(nm boringssl/build/crypto/libcrypto.a 2>/dev/null)" \
  || { echo "::error::libcrypto.a lacks kOpenSSLReasonValues — err_data.c was not generated"; exit 1; }
mkdir -p ols/ssl
cp boringssl/build/crypto/libcrypto.a boringssl/build/ssl/libssl.a boringssl/build/decrepit/libdecrepit.a ols/ssl/
cp -R boringssl/include ols/ssl/
ln -sfn ssl ols/openssl     # CMakeModules/common.cmake includes ${PROJECT_SOURCE_DIR}/openssl/include

# ─── The small static deps → ../third-party ──────────────────────────────────
say "brotli"
unpack src/brotli-$BROTLI_VERSION.tar.gz brotli
( cd brotli && mkdir -p out && cd out \
  && cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBROTLI_DISABLE_TESTS=ON \
       -DCMAKE_POSITION_INDEPENDENT_CODE=ON "${CMAKE_T[@]}" >/dev/null \
  && make -j"$JOBS" brotlicommon brotlidec brotlienc >/dev/null )
for a in brotlicommon brotlidec brotlienc; do cp "brotli/out/lib$a.a" "$TP/lib/lib$a-static.a"; done
cp -R brotli/c/include/brotli "$TP/include/"

say "libbcrypt"
unpack src/libbcrypt-$BCRYPT_COMMIT.tar.gz libbcrypt
( cd libbcrypt && make CC="cc $CFLAGS_T" >/dev/null 2>&1 )
cp libbcrypt/bcrypt.a "$TP/lib/libbcrypt.a"; cp libbcrypt/bcrypt.h "$TP/include/"

say "udns"
unpack src/udns-$UDNS_VERSION.tar.gz udns
# udns 0.4's configure probes inet_pton() with an implicit declaration, which
# clang 16+ and gcc 14 reject, so it decides "no", builds its own udns_pton, and
# dns_pton is UNDEFINED at the final link. Every target has inet_pton.
( cd udns && CC=cc CFLAGS="$CFLAGS_T -Wno-implicit-function-declaration -DHAVE_INET_PTON_NTOP" \
    ./configure --disable-ipv6 >/dev/null && make libudns.a >/dev/null 2>&1 )
has ' T _?dns_pton$' "$(nm udns/libudns.a)" || { echo "::error::libudns.a lacks dns_pton"; exit 1; }
cp udns/libudns.a "$TP/lib/"; cp udns/udns.h "$TP/include/"

autotools_static() {   # <dir> <configure args…>
  local d="$1"; shift
  ( cd "$d" && CC=cc CFLAGS="$CFLAGS_T" ./configure --prefix="$TP" "$@" >/dev/null \
    && make -j"$JOBS" >/dev/null && make install >/dev/null )
}
say "pcre2";  unpack src/pcre2-$PCRE2_VERSION.tar.gz pcre2; autotools_static pcre2 --disable-shared --enable-static
say "zlib";   unpack src/zlib-$ZLIB_VERSION.tar.gz zlib;    ( cd zlib && CC=cc CFLAGS="$CFLAGS_T" ./configure --static --prefix="$TP" >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null )
say "expat";  unpack src/expat-$EXPAT_VERSION.tar.gz expat; autotools_static expat --disable-shared --enable-static --without-docbook --without-examples --without-tests --without-xmlwf
for a in libpcre2-8.a libz.a libexpat.a libbcrypt.a libudns.a libbrotlicommon-static.a; do
  [ -f "$TP/lib/$a" ] || { echo "::error::$a missing from third-party/lib"; exit 1; }
done

# ─── OLS's CMake: upstream build.sh's updateSrcCMakelistfile(), plus ours ────
say "cmake edits"
cd ols
for l in 'add_definitions(-DRUN_TEST)' 'add_definitions(-DPOOL_TESTING)' 'add_definitions(-DTEST_OUTPUT_PLAIN_CONF)' \
         'add_definitions(-DDEBUG_POOL)' 'set(libUnitTest' 'find_package(ZLIB' 'find_package(PCRE' 'add_subdirectory(test)' \
         'SET (CMAKE_C_COMPILER' 'SET (CMAKE_CXX_COMPILER' \
         'set(IP2LOC_ADD_LIB' 'add_definitions(-DUSE_IP2LOCATION)' 'set(MMDB_LIB' 'add_definitions(-DENABLE_IPTOGEO2)'; do
  q="$(printf '%s' "$l" | perl -pe 's/([^\w])/\\$1/g')"
  subst "s/$q/#$q/g" CMakeLists.txt
done
# IP2Location and MaxMind are geo-IP modules a loopback dev server has no use for
# and that upstream builds from its third-party repo; off, as above.
subst 's/\$\{unittest_STAT_SRCS\}//g; s/libstdc\+\+\.a//g; s/-nodefaultlibs //g; s/ libxml2\.a//g' src/CMakeLists.txt
subst 's|link_directories\("/usr/lib64"\)|link_directories("/usr/lib64" "\${PROJECT_SOURCE_DIR}/ssl" "\${PROJECT_SOURCE_DIR}/../third-party/lib")|' src/CMakeLists.txt
subst 's/^(\s*)ls_llmq\.c/$1#ls_llmq.c/m; s/^(\s*)ls_llxq\.c/$1#ls_llxq.c/m' src/lsr/CMakeLists.txt
if [ "$OS" = macos ]; then
  # upstream build.sh's Darwin seds, verbatim in effect
  subst 's/ rt\b//g; s/ crypt\b//g; s/gcc_eh//g; s/c_nonshared//g; s/\bgcc\b//g; s/-Wl,--whole-archive//g; s/-Wl,--no-whole-archive//g' src/CMakeLists.txt
else
  # libaio is not on a stock Ubuntu desktop; link the archive. Same for
  # libatomic on aarch64 (upstream links it dynamically there; the gate below
  # caught libatomic.so.1 in NEEDED, 4 Oct 2026) — GCC ships libatomic.a.
  subst 's/set\(LINUX_AIO_LIB\s+aio\)/set(LINUX_AIO_LIB libaio.a)/' CMakeLists.txt
  subst 's/set\(LIBATOMIC atomic\)/set(LIBATOMIC libatomic.a)/' src/CMakeLists.txt
fi

say "build openlitespeed"
mkdir -p build && cd build
LDX=""; [ "$OS" = linux ] && LDX="-static-libstdc++ -static-libgcc"
cmake .. -DCMAKE_BUILD_TYPE=Release -DMOD_PAGESPEED=OFF -DMOD_SECURITY=OFF -DMOD_LUA=OFF \
  -DCMAKE_EXE_LINKER_FLAGS="$LDX" "${CMAKE_T[@]}" >/dev/null
# Only the server. modacme (links libstdc++.a with -nodefaultlibs, which macOS
# does not have) and the Linux namespace helpers are separate targets nobody here ships.
if ! make -j"$JOBS" openlitespeed > "$WORK/make.log" 2>&1; then
  grep -E 'error|Undefined|undefined reference' "$WORK/make.log" | head -40
  cp "$WORK/make.log" "$OUT/make-openlitespeed.log"
  echo "::error::openlitespeed did not build (full log: make-openlitespeed.log)"; exit 1
fi
BIN="$WORK/ols/build/src/openlitespeed"
[ -x "$BIN" ] || { echo "::error::openlitespeed did not link"; exit 1; }
cd "$WORK"

# ─── Gates. Each has a specific way of being wrong. ──────────────────────────
say "gates"

# 1. It runs and is the version we think it is.
"$BIN" -v
has "LiteSpeed/$OLS_VERSION Open" "$("$BIN" -v 2>&1)" || { echo "::error::wrong version"; exit 1; }

# 2. Arch, floor and closure.
if [ "$OS" = macos ]; then
  has "$MAC_ARCH" "$(file "$BIN")" || { echo "::error::not $MAC_ARCH: $(file "$BIN")"; exit 1; }
  MINOS="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  [ "$MINOS" = "$MACOSX_DEPLOYMENT_TARGET" ] || { echo "::error::minos=$MINOS want $MACOSX_DEPLOYMENT_TARGET"; exit 1; }
  echo "minos: $MINOS"
  if otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -vE '^/usr/lib/(libSystem\.B|libc\+\+\.1)\.dylib$' | grep .; then
    echo "::error::links a dylib outside libSystem/libc++"; exit 1
  fi
else
  case "$ARCH" in x86_64) want="x86-64" ;; aarch64) want="aarch64" ;; esac
  has "$want" "$(file "$BIN")" || { echo "::error::not $ARCH: $(file "$BIN")"; exit 1; }
  NEEDED="$(objdump -p "$BIN" 2>/dev/null | awk '/NEEDED/{print $2}' | sort)"
  echo "NEEDED: $(echo $NEEDED)"
  if echo "$NEEDED" | grep -vE '^(libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|libcrypt\.so\.1|ld-linux.*\.so\.[12])$' | grep .; then
    echo "::error::links a shared library outside glibc + libcrypt"; exit 1
  fi
  GLIBC_MAX="$(objdump -T "$BIN" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -t. -k2 -n | tail -1)"
  echo "highest glibc symbol: $GLIBC_MAX"
  [ "$(printf '%s\nGLIBC_2.35\n' "$GLIBC_MAX" | sort -t. -k2 -n | tail -1)" = "GLIBC_2.35" ] \
    || { echo "::error::needs $GLIBC_MAX, above Ubuntu 22.04's 2.35"; exit 1; }
fi

# 3. A REXENV-SHAPED server root, serving, with every patch exercised.
P="$WORK/probe"
RUN="$P/run"                                   # LSWS_TMP_DIR
mkdir -p "$P/bin" "$P/conf/vhosts/site" "$P/logs" "$P/cache" "$P/shm" "$P/swap" "$RUN" "$P/www/sub" "$P/share/autoindex"
cp "$BIN" "$P/bin/openlitespeed"
cp ols/dist/conf/mime.properties "$P/conf/"
echo '<h1>static ok</h1>' > "$P/www/index.html"
echo '<?php // served by the FastCGI probe, never parsed' > "$P/www/index.php"
echo '<h1>sub ok</h1>' > "$P/www/sub/index.html"
printf 'RewriteEngine On\nRewriteRule ^rewritten/(.*)$ /index.php?r=$1 [L,QSA]\n' > "$P/www/.htaccess"
FCGI_PORT=19783; HTTP_PORT=18489
# NOTE: no `statDir` on purpose — patch 0002 must turn its absence into the run dir.
cat > "$P/conf/httpd_config.conf" <<EOF
serverName                 probe
user                       $(id -un)
group                      $(id -gn)
autoRestart                0
swappingDir                $P/swap
mime                       conf/mime.properties
indexFiles                 index.html, index.php
disableWebAdmin            1
noRemoteFetch              1
httpdWorkers               1
errorlog logs/error.log {
  logLevel                 DEBUG
  enableStderrLog          1
}
accessLog logs/access.log {
}
# A developer's docroot holds files with whatever modes their editor and git
# left; OLS's default masks deny some of them ("does not meet the requirements of
# 'Required bits'"), so rexenv clears both, exactly like this.
fileAccessControl {
  followSymbolLink         1
  checkSymbolLink          0
  requiredPermissionMask   000
  restrictedPermissionMask 000
}
tuning {
  shmDefaultDir            $P/shm
  quicEnable               0
  quicShmDir               $P/shm
}
extProcessor pool {
  type                     fcgi
  address                  127.0.0.1:$FCGI_PORT
  maxConns                 10
  initTimeout              10
  retryTimeout             0
  persistConn              1
  autoStart                0
}
scriptHandler {
  add fcgi:pool            php
}
virtualHost site {
  vhRoot                   $P/www/
  allowSymbolLink          1
  enableScript             1
  restrained               0
  configFile               conf/vhosts/site/vhconf.conf
}
listener Default {
  address                  127.0.0.1:$HTTP_PORT
  secure                   0
  map                      site *
}
# Upstream's dist defaults, verbatim but for storagepath. A shorter block (no
# maxCacheObjSize & co.) parses fine and then never answers "hit" — measured.
module cache {
  ls_enabled               1
  storagepath              $P/cache
  checkPrivateCache        1
  checkPublicCache         1
  maxCacheObjSize          10000000
  maxStaleAge              200
  qsCache                  1
  reqCookieCache           1
  respCookieCache          1
  ignoreReqCacheCtrl       1
  ignoreRespCacheCtrl      0
  enableCache              0
  expireInSeconds          3600
  enablePrivateCache       0
  privateExpireInSeconds   3600
}
EOF
cat > "$P/conf/vhosts/site/vhconf.conf" <<'EOF'
docRoot                    $VH_ROOT/
index {
  useServer                0
  indexFiles               index.html, index.php
  autoIndex                0
}
rewrite {
  enable                   1
  autoLoadHtaccess         1
}
context / {
  location                 $DOC_ROOT/
  allowBrowse              1
  rewrite {
    RewriteFile            .htaccess
  }
}
EOF

touch "$WORK/before-start"
export LSWS_TMP_DIR="$RUN"
# `-t` exits 0 clean, 1 with warnings, 2 with errors (lshttpdmain.cpp). A warning
# is the host's business — macOS's `staff` group is gid 20, under OLS's 100
# minimum — an error is ours. Its stdout must carry nothing but OLS's own log
# lines: patch 0005 exists because a group-change command printed into it.
set +e; TOUT="$("$P/bin/openlitespeed" -t 2>&1)"; TRC=$?; set -e
echo "$TOUT"
[ "$TRC" -le 1 ] || { echo "::error::config test reported errors (exit $TRC) — patch 0002?"; exit 1; }
if grep -vE '^[0-9-]+ [0-9:.]+ \[(INFO|NOTICE|WARN|DEBUG)\]' <<<"$TOUT" | grep .; then
  echo "::error::config test printed something that is not a log line (above)"; exit 1
fi
python3 "$HERE/scripts/fcgi-probe.py" "$FCGI_PORT" & FCGIPID=$!
# The pool must be listening BEFORE the server's first PHP request: with
# retryTimeout 0 a refused connect is an immediate 503 (measured: the gate's
# first run raced Python's startup and lost).
for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$FCGI_PORT") 2>/dev/null && break; sleep 0.1; done
"$P/bin/openlitespeed" -d > "$P/logs/stdout.log" 2>&1 & OLSPID=$!
stop() { kill "$OLSPID" "$FCGIPID" 2>/dev/null || true; wait "$OLSPID" 2>/dev/null || true; }
for _ in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$HTTP_PORT/" && break; sleep 0.25; done
fail() { echo "::error::$*"; tail -30 "$P/logs/error.log" 2>/dev/null; stop; exit 1; }
get()  { curl -s "http://127.0.0.1:$HTTP_PORT$1"; }
# Everything below waits for the first timer tick: the cache manager is not up
# before it (requests in the first second or two are served but never cached —
# measured, 0 hits in 6 tries without the wait, 18/18 with it), and it is the
# tick at which the remote fetches used to fire.
sleep 3
hdr()  { curl -s -o /dev/null -D - "http://127.0.0.1:$HTTP_PORT$1" | tr -d '\r' | awk -F': ' 'tolower($1)=="'"$2"'"{print $2}'; }

[ "$(get /)" = '<h1>static ok</h1>' ]        || fail "static index"
[ "$(get /sub/)" = '<h1>sub ok</h1>' ]       || fail "subdirectory index"
[ "$(hdr / server)" = "LiteSpeed" ]          || fail "server header"
# PHP over FastCGI — the path every rexenv site takes.
B="$(get /index.php)"
grep -qx "script=$P/www/index.php" <<<"$B" || { echo "$B"; fail "SCRIPT_FILENAME not the docroot file"; }
# The cache module: a fresh key misses, then hits, and the body is the SAME response.
K="k$(date +%s)$$"
[ "$(hdr "/index.php?$K" x-litespeed-cache)" = "miss" ] || fail "first request should miss the cache"
[ "$(hdr "/index.php?$K" x-litespeed-cache)" = "hit" ]  || fail "second request should hit the cache"
[ -n "$(find "$P/cache" -type f ! -name '.cacheman*' | head -1)" ] || fail "nothing written under storagepath"
# .htaccess rewrite reaches the handler with the original URI.
grep -qx 'uri=/rewritten/abc' <<<"$(get /rewritten/abc)" || fail ".htaccess RewriteRule"

# Patch 0004: nothing reached for the network.
grep -q 'noRemoteFetch: release check' "$P/logs/error.log" || fail "noRemoteFetch was not read"
if grep -E 'HttpFetch|quic\.cloud|autoupdate' "$P/logs/error.log"; then fail "a remote fetch was attempted"; fi
# The DIRECTORIES autoupdate/ and tmp/ are made at every start (testAndFixDirs);
# only the downloaded files would mean a fetch happened.
for f in autoupdate/release autoupdate/releasecb tmp/download-quic-cloud-ips admin/conf/quic-cloud-ips; do
  [ ! -e "$P/$f" ] || fail "remote fetch left $f behind"
done
# Patch 0003: the runtime files are under LSWS_TMP_DIR, and nothing new under /tmp/lshttpd or /tmp/ols.
[ -s "$RUN/lshttpd.pid" ] || fail "pid file not at \$LSWS_TMP_DIR/lshttpd.pid"
[ -e "$RUN/.status" ]     || fail "status link not under \$LSWS_TMP_DIR (patch 0002/0003)"
for d in /tmp/lshttpd /tmp/ols; do
  [ -e "$d" ] && [ -n "$(find "$d" -newer "$WORK/before-start" 2>/dev/null | head -1)" ] && fail "wrote under $d"
done
kill -0 "$OLSPID" 2>/dev/null || fail "server died during the probes"
stop
echo "served: static, subdir, php via fcgi, cache miss→hit, .htaccess; no remote fetch; runtime files under LSWS_TMP_DIR only"

# ─── Licences ────────────────────────────────────────────────────────────────
# Named explicitly, never globbed: a glob that matches nothing is how a licence
# archive ships empty. rexenv refuses to resolve a self-built artifact without one.
say "licences"
LIC="$WORK/licenses"; mkdir -p "$LIC"
cp ols/LICENSE                                   "$LIC/openlitespeed.LICENSE"        # GPL-3.0
cp ols/GPL.txt                                   "$LIC/openlitespeed.GPL.txt"
cp ols/lsquic/LICENSE                            "$LIC/lsquic.LICENSE"               # MIT
cp ols/lsquic/LICENSE.chrome                     "$LIC/lsquic.LICENSE.chrome"        # BSD-3 (Chromium-derived parts)
cp ols/lsquic/src/liblsquic/ls-qpack/LICENSE     "$LIC/ls-qpack.LICENSE"             # MIT
cp ols/lsquic/src/lshpack/LICENSE                "$LIC/ls-hpack.LICENSE"             # MIT
cp boringssl/LICENSE                             "$LIC/boringssl.LICENSE"
cp brotli/LICENSE                                "$LIC/brotli.LICENSE"               # MIT
cp libbcrypt/README                              "$LIC/libbcrypt.README"             # CC0 (stated in the README)
cp udns/COPYING.LGPL                             "$LIC/udns.COPYING.LGPL"            # LGPL-2.1
cp pcre2/LICENCE.md                              "$LIC/pcre2.LICENCE.md"             # BSD-3
cp zlib/LICENSE                                  "$LIC/zlib.LICENSE"
cp expat/COPYING                                 "$LIC/expat.COPYING"                # MIT
for f in "$LIC"/*; do [ -s "$f" ] || { echo "::error::empty licence file: $f"; exit 1; }; done
( cd "$WORK" && tar -czf "$OUT/licenses-openlitespeed-$OLS_VERSION-$OS-$ARCH.tar.gz" licenses )
echo "licences: $(ls "$LIC" | tr '\n' ' ')"

# ─── Package ─────────────────────────────────────────────────────────────────
# bin/openlitespeed + conf/mime.properties: the server root is derived from the
# binary's own path (<root>/bin/..), so rexenv unpacks this tree per version and
# writes each site's conf/ beside it.
say "package"
# share/autoindex/ is empty on purpose: the server checks that the path exists
# (an ERROR, and a non-zero `-t`, without it) even with autoIndex off.
PKG="$WORK/pkg"; mkdir -p "$PKG/bin" "$PKG/conf" "$PKG/share/autoindex"
cp "$BIN" "$PKG/bin/openlitespeed"
cp ols/dist/conf/mime.properties "$PKG/conf/"
NAME="openlitespeed-$OLS_VERSION-$OS-$ARCH.tar.gz"
( cd "$PKG" && tar -czf "$OUT/$NAME" bin conf share )
( cd "$OUT" && for f in "$NAME" "licenses-openlitespeed-$OLS_VERSION-$OS-$ARCH.tar.gz"; do shasum -a 256 "$f" > "$f.sha256"; done )
ls -lh "$OUT"
say "record"
echo "openlitespeed $OLS_VERSION / $OS / $ARCH / boringssl ${BSSL_COMMIT:0:8} / lsquic ${LSQUIC_COMMIT:0:8}"
