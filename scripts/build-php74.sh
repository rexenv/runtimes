#!/usr/bin/env bash
# Build PHP 7.4.33 (cli + fpm) as a statically-dep-linked Mach-O, via
# static-php-cli, from the shivammathur security-backports source.
#
# Runs on a GitHub-hosted macOS runner. Everything it needs is pinned: the spc
# binary, the PHP source tarball, and the deployment target. Nothing here reads
# the host's Homebrew prefix — that is the entire reason this build exists
# rather than a bottle bundle.
#
# Usage: scripts/build-php74.sh <aarch64|x86_64> <outdir>
set -euo pipefail

ARCH="${1:?arch required: aarch64 or x86_64}"
OUT="${2:?output dir required}"
# Use spc's pre-built dependency archives, or build every dep from source.
# A toggle rather than a constant because it is a live HYPOTHESIS: the pre-built
# archives are produced for the 8.x toolchain, and PHP's GD check RUNS a conftest
# linked against the whole dep set — a library that traps on load fails it with
# SIGILL and blames gd. static-php-cli's own 7.4-era CI did not use pre-built
# deps. Source builds are much slower, so this stays opt-out, not the default.
PREBUILT="${3:-true}"

# ─── Pins ────────────────────────────────────────────────────────────────────
PHP_VERSION="7.4.33"

# static-php-cli. A released binary, not `composer create-project`: the tool that
# builds a pinned artifact should itself be pinned to bytes.
SPC_VERSION="2.8.5"
SPC_SHA256_aarch64="acf2f25d56d0cbf8e65aa82e5054fef555f7be7c5c38046c6e0819f266d83225"
SPC_SHA256_x86_64="e8b798048f62ca4960764196543b60ae703f7174aa418824cf542aeec1d2cd6a"

# The SOURCE. Not php.net's 7.4.33 tarball — that fails on OpenSSL 3.6 with
# `error: use of undeclared identifier 'RSA_SSLV23_PADDING'` (the constant was
# removed from OpenSSL's headers). This branch guards it with #ifdef, and also
# carries the Xcode-16 clang inline-asm fix and the Apple-Silicon ITIMER_PROF
# fix. Same source Homebrew's php@7.4 formula builds.
#
# The branch is REBASED, not appended, so this commit stops being reachable at
# the next security update — which is why the tarball is mirrored into the
# release and pinned by hash. When the URL below 404s, the mirror is the copy.
SRC_COMMIT="5a576d8eb53e44aff3af9259cfd29e599f604471"
SRC_URL="https://github.com/shivammathur/php-src-backports/archive/${SRC_COMMIT}.tar.gz"
SRC_SHA256="d82887f2166e8526ea9b1cfd8c5ecf5649718f0b6e341380d333eba8066429a4"

# The oldest macOS these binaries run on. This is **12.0, matching spc's own
# macOS default and every PHP build rexenv already ships** — measured, not
# assumed: the cached php 8.1.34 / 8.3.31 / 8.5.8 binaries are all `minos 12.0`.
#
# Forcing 11.0 here was the original plan and it is the wrong call: it would make
# 7.4 the only row with a lower floor, buying nothing, while fighting the
# builder's default on every dependency. The number is asserted per artifact
# below, so a runner-image change that moves it is a build failure rather than a
# discovery on somebody's older Mac.
#
# (Separately: rexenv's INSTALL.md claims macOS 11+, and its pinned nginx is
# `minos 15.0`. That gap is real and is NOT this build's to fix — it is filed in
# rexenv's docs/TODO.md.)
export MACOSX_DEPLOYMENT_TARGET="12.0"

# Extension set. Aims at parity with the static-php.dev "bulk" builds rexenv
# ships for 8.x, so a 7.4 site's `php -m` is not a surprise. Deliberately absent:
#
#   opcache        — spc's static-opcache patch series starts at 8.0 and
#                    patchMicro() returns early for '74'. Genuinely unavailable.
#   opentelemetry  — spc guards it on PHP >= 8.0.
#   protobuf       — same.
#   swoole, event  — modern releases dropped 7.4; not worth a fork.
#   imagick, imap  — the two that historically break a 7.4 build first. Left out
#                    of the first green build ON PURPOSE: get a working artifact,
#                    then add them one at a time with CI as the judge.
# NARROWED to the WordPress/Laravel-critical set for the FIRST green build. The
# wide set (dba, pgsql, redis, soap, xsl, sysv*, gmp, bz2, ftp, calendar, posix,
# pcntl, readline, shmop) is what the 8.x bulk builds carry and is where this
# should end up — but every extension drags libraries into one shared LIBS line,
# and PHP's GD check is a RUN test, so an unrelated library can kill it. Get one
# artifact that works, then grow the set with CI as the judge. The divergence is
# recorded in the release notes rather than discovered by a user.
EXTS="bcmath,ctype,curl,dom,exif,fileinfo,filter,gd,iconv,intl,mbstring,mysqli,openssl,pdo_mysql,session,simplexml,sockets,sodium,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zip,zlib"

# Libraries gd needs before PHP's bundled GD will link at all. spc only builds an
# extension's SUGGESTED libs when asked (`--with-suggested-libs`), and without
# them `gd.php` emits a bare `--enable-gd` — which on 7.4 fails configure with
# "GD build test failed", 40 minutes into the build and with the reason only in
# config.log. Named explicitly as well as via the suggestion flag, so the set is
# visible here rather than implied by another project's defaults.
LIBS="freetype,libjpeg,libwebp,libpng,zlib"

# Extensions WordPress cannot run without. Asserted on the built binary, so a
# silently-dropped extension fails the build instead of shipping.
REQUIRED_EXTS="mysqli pdo_mysql curl gd mbstring json xml dom openssl zip sodium"

say() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }

# ─── Toolchain ───────────────────────────────────────────────────────────────
# Pin Xcode explicitly: Xcode 27 hard-errors on a deployment target below macOS
# 12, so an unpinned `xcode-select` would silently break the 11.0 floor the day
# the runner image moves.
if [ -d /Applications/Xcode_16.4.app ]; then
  sudo xcode-select -s /Applications/Xcode_16.4.app
fi
say "toolchain"
clang --version | head -2
xcodebuild -version | head -1 || true
echo "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
echo "pre-built deps: $PREBUILT"

# ─── Fetch spc ───────────────────────────────────────────────────────────────
say "static-php-cli ${SPC_VERSION} (${ARCH})"
eval "SPC_SHA=\$SPC_SHA256_${ARCH}"
curl -fSL -o spc.tar.gz \
  "https://github.com/crazywhalecc/static-php-cli/releases/download/${SPC_VERSION}/spc-macos-${ARCH}.tar.gz"
echo "${SPC_SHA}  spc.tar.gz" | shasum -a 256 -c -
tar xzf spc.tar.gz
chmod +x spc
./spc --version

# ─── Fetch + verify the source ───────────────────────────────────────────────
say "php-src (${SRC_COMMIT:0:12})"
curl -fSL -o php-src.tar.gz "$SRC_URL"
echo "${SRC_SHA256}  php-src.tar.gz" | shasum -a 256 -c -
# Fail loudly if the OpenSSL 3 guard is not in this source — the single check
# that separates a buildable tree from php.net's tarball.
tar xzf php-src.tar.gz "php-src-backports-${SRC_COMMIT}/ext/openssl/openssl.c" \
  "php-src-backports-${SRC_COMMIT}/main/php_version.h"
grep -q '#ifdef RSA_SSLV23_PADDING' "php-src-backports-${SRC_COMMIT}/ext/openssl/openssl.c" \
  || { echo "::error::source lacks the OpenSSL 3 guard — wrong tarball?"; exit 1; }
grep -q "#define PHP_VERSION \"${PHP_VERSION}\"" "php-src-backports-${SRC_COMMIT}/main/php_version.h" \
  || { echo "::error::source is not PHP ${PHP_VERSION}"; exit 1; }
rm -rf "php-src-backports-${SRC_COMMIT}"

# ─── Patch the source ────────────────────────────────────────────────────────
# The pin is verified against the ORIGINAL bytes above; patches are applied
# after, on a tarball we repack. That order is the point: the hash still says
# what upstream shipped, and every change we make to it is a reviewable file in
# `patches/` rather than an in-place edit nobody can diff. The original tarball
# — not this one — is what gets mirrored into the release.
say "patches"
mkdir -p patched && tar -C patched -xzf php-src.tar.gz
( cd "patched/php-src-backports-${SRC_COMMIT}"
  for f in "$GITHUB_WORKSPACE"/patches/*.patch; do
    [ -f "$f" ] || continue
    echo "  applying $(basename "$f")"
    # --forward + no fuzz: a patch that is already applied, or that no longer
    # matches, is an ERROR. A silently skipped patch would put us straight back
    # to the failure it exists to fix, 40 minutes later and looking identical.
    patch -p1 --forward --fuzz=0 < "$f" \
      || { echo "::error::$(basename "$f") did not apply cleanly"; exit 1; }
  done
  # Prove the thing the patch is FOR, not just that patch(1) exited 0.
  grep -q 'char foobar () { return 0; }' ext/gd/config.m4 \
    || { echo "::error::the gd conftest still falls off the end"; exit 1; }
)
tar -C patched -czf php-src-patched.tar.gz "php-src-backports-${SRC_COMMIT}"
rm -rf patched
echo "  patched source: $(shasum -a 256 php-src-patched.tar.gz | cut -d' ' -f1)"

# ─── Build ───────────────────────────────────────────────────────────────────
say "download sources (--prefer-pre-built keeps this from being ICU-dominated)"
./spc download \
  --with-php="${PHP_VERSION}" \
  --custom-url="php-src:file://$(pwd)/php-src-patched.tar.gz" \
  --for-extensions="$EXTS" \
  --for-libs="$LIBS" \
  $( [ "$PREBUILT" = "true" ] && echo --prefer-pre-built ) \
  --retry=2 \
  --debug

say "doctor"
./spc doctor --auto-fix || true

# spc runs ./configure itself and does NOT echo its output — a failed configure
# comes back as a bare "Command exited with non-zero code: 1" and the actual
# reason is in config.log, which the runner then throws away. Dump it on the way
# out so a failing build says WHY on its first attempt rather than its second.
# Keep the WHOLE log, not a window. Twice now the last-120-lines view showed
# configure's later probes and not the failure — a tail is the wrong tool when
# the interesting line is in the middle. The files are uploaded as an artifact by
# the workflow, so the next question can be answered without another 40-minute
# round trip.
dump_config_log() {
  mkdir -p "$OUT/debug"
  cp -f source/php-src/config.log "$OUT/debug/" 2>/dev/null || true
  cp -rf log "$OUT/debug/spc-log" 2>/dev/null || true
  for f in source/php-src/config.log; do
    [ -f "$f" ] || continue
    # The line configure itself calls the failure, with the context above it —
    # which is where the real cause lives. Note several of PHP's checks (GD's
    # among them) COMPILE, LINK and then RUN a conftest, so "build test failed"
    # can mean the program was signalled at runtime (`$? = 132` is SIGILL), not
    # that anything failed to compile. The distinction decides where to look.
    n="$(grep -n '^configure: error' "$f" | tail -1 | cut -d: -f1)"
    if [ -n "$n" ]; then
      echo "::group::config.log around the failure (line $n)"
      sed -n "$(( n > 80 ? n - 80 : 1 )),$((n + 5))p" "$f"
      echo "::endgroup::"
    fi
    echo "--- every configure error line ---"
    grep -nE "^configure: error" "$f" || true
  done
}
trap 'rc=$?; [ $rc -ne 0 ] && dump_config_log; exit $rc' EXIT

say "build (cli + fpm)"
# --with-suggested-libs is deliberately NOT used. It fixed gd's missing
# --with-freetype/--with-jpeg/--with-webp, but it also built libavif (PHP 7.4's
# gd has no avif support at all, so `--with-avif` is meaningless there) and qdbm
# (dba's suggestion, an ancient library nothing here needs) — and those land in
# the same LIBS line the GD RUN test links against. Ask for the three libs gd
# actually needs, by name, instead of taking every suggestion in the graph.
time ./spc build "$EXTS" --with-libs="$LIBS" --build-cli --build-fpm --debug

# ─── Gates. Every one of these has a specific way of being wrong. ────────────
say "gates"
BIN=buildroot/bin

# 1. It is the version we think it is, and it runs.
"$BIN/php" -v
"$BIN/php" -v | grep -q "PHP ${PHP_VERSION}" || { echo "::error::wrong PHP version"; exit 1; }
"$BIN/php-fpm" -v | grep -q "PHP ${PHP_VERSION}" || { echo "::error::wrong php-fpm version"; exit 1; }

# 2. Every extension WordPress needs is actually IN it. spc will happily drop an
#    extension that failed to configure and still produce a working php.
MODS="$("$BIN/php" -m | tr 'A-Z' 'a-z')"
for e in $REQUIRED_EXTS; do
  echo "$MODS" | grep -qx "$e" || { echo "::error::missing required extension: $e"; exit 1; }
done
echo "modules: $(echo "$MODS" | tr '\n' ' ')"

# 3. The dylib closure is what rexenv's relink_to_system_libs accepts. Anything
#    outside /usr/lib + /System (bar the four names it knows) makes rexenv
#    hard-error at resolve() on the user's machine — long after this build.
for f in "$BIN/php" "$BIN/php-fpm"; do
  if otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/)' | grep .; then
    echo "::error::$f links a non-system dylib"; exit 1
  fi
done
# …and specifically NOT GPL readline (libedit is the permissive one PHP uses).
otool -L "$BIN/php" | grep -q libreadline && { echo "::error::links GPL readline"; exit 1; } || true

# 4. Mach-O arch matches the job, and the deployment target survived.
for f in "$BIN/php" "$BIN/php-fpm"; do
  file "$f" | grep -q "$ARCH" || { echo "::error::$f is not $ARCH"; exit 1; }
  MINOS="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  [ "$MINOS" = "$MACOSX_DEPLOYMENT_TARGET" ] \
    || { echo "::error::$f minos=$MINOS want $MACOSX_DEPLOYMENT_TARGET"; exit 1; }
done

# 5. Zend symbols exported. This is what decides whether Xdebug can ever dlopen
#    into this binary: rexenv's static PHP 8.0.30 exports 98 symbols and no
#    _OnUpdateBool, which is exactly why PHP 8.0 has no Xdebug toggle. Recorded
#    rather than enforced — if it comes out low, 7.4 ships without Xdebug like
#    8.0, and rexenv's xdebug_supported() already answers false for free.
SYMS="$(nm -gU "$BIN/php-fpm" | wc -l | tr -d ' ')"
if nm -gU "$BIN/php-fpm" | grep -q _OnUpdateBool; then
  echo "zend-symbols: $SYMS exported, _OnUpdateBool present → Xdebug can dlopen"
else
  echo "::warning::zend-symbols: $SYMS exported, NO _OnUpdateBool → 7.4 gets no Xdebug (like 8.0)"
fi

# 6. A real request, not just --version. php-fpm that starts and cannot execute
#    a script is the failure mode a version check cannot see.
echo '<?php echo "OK:", PHP_VERSION, ":", (int)extension_loaded("mysqli");' > /tmp/probe.php
"$BIN/php" /tmp/probe.php | grep -q "OK:${PHP_VERSION}:1" \
  || { echo "::error::the built php cannot run a script with mysqli"; exit 1; }

# ─── Licences ────────────────────────────────────────────────────────────────
# Static linking puts these libraries INSIDE the binary, so their licences travel
# with it. Collected from the sources spc actually downloaded rather than from a
# hand-kept list: a list would describe the extension set as it was the day
# somebody wrote it, and the whole point is that this one is generated by the
# same run that produced the bytes.
say "licences"
LIC="$OUT/licenses"
mkdir -p "$LIC"
cp licenses/PHP-3.01.txt "$LIC/" 2>/dev/null || \
  cp "$GITHUB_WORKSPACE/licenses/PHP-3.01.txt" "$LIC/" 2>/dev/null || true
found=0
for d in source/*/; do
  name="$(basename "$d")"
  for f in LICENSE LICENSE.txt LICENSE.md COPYING COPYING.txt LICENSE-MIT NOTICE; do
    if [ -f "$d$f" ]; then
      cp "$d$f" "$LIC/${name}.${f}"
      found=$((found + 1))
      break
    fi
  done
done
echo "collected $found dependency licence files from $(ls -d source/*/ 2>/dev/null | wc -l | tr -d ' ') sources"
# A dependency whose licence we could not find is a thing we would be shipping
# blind. Say which, loudly, rather than discovering it in a takedown.
for d in source/*/; do
  name="$(basename "$d")"
  ls "$LIC/${name}."* >/dev/null 2>&1 || echo "::warning::no licence file found in source/$name"
done

# ─── Package ─────────────────────────────────────────────────────────────────
say "package"
mkdir -p "$OUT"
tar -C "$BIN" -czf "$OUT/php-${PHP_VERSION}-cli-macos-${ARCH}.tar.gz" php
tar -C "$BIN" -czf "$OUT/php-${PHP_VERSION}-fpm-macos-${ARCH}.tar.gz" php-fpm
cp php-src.tar.gz "$OUT/php-src-backports-${SRC_COMMIT:0:12}.tar.gz"
tar -C "$OUT" -czf "$OUT/licenses-${ARCH}.tar.gz" licenses && rm -rf "$LIC"
( cd "$OUT" && shasum -a 256 ./*.tar.gz | tee "SHA256SUMS-${ARCH}" )
ls -lh "$OUT"

# The numbers the plan owes an answer to. Printed rather than asserted: the first
# run is the measurement, and a threshold invented before it would be fiction.
say "record"
echo "artifact sizes:"; ls -l "$OUT"/*.tar.gz | awk '{printf "  %-52s %s\n", $9, $5}'
echo "extension count: $(echo "$MODS" | wc -l | tr -d ' ')"
