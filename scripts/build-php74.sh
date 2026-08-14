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

# The oldest macOS these binaries must run on. Exported before EVERY dep build,
# not just PHP's: one dependency compiled without it produces a silent `minos`
# bump that only shows up on a user's older Mac.
export MACOSX_DEPLOYMENT_TARGET="11.0"

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
EXTS="bcmath,bz2,calendar,ctype,curl,dba,dom,exif,fileinfo,filter,ftp,gd,gmp,iconv,intl,mbstring,mysqli,openssl,pcntl,pdo_mysql,pgsql,posix,readline,redis,session,shmop,simplexml,soap,sockets,sodium,sqlite3,sysvmsg,sysvsem,sysvshm,tokenizer,xml,xmlreader,xmlwriter,xsl,zip,zlib"

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

# ─── Build ───────────────────────────────────────────────────────────────────
say "download sources (--prefer-pre-built keeps this from being ICU-dominated)"
./spc download \
  --with-php="${PHP_VERSION}" \
  --custom-url="php-src:file://$(pwd)/php-src.tar.gz" \
  --for-extensions="$EXTS" \
  --prefer-pre-built \
  --retry=2 \
  --debug

say "doctor"
./spc doctor --auto-fix || true

# spc runs ./configure itself and does NOT echo its output — a failed configure
# comes back as a bare "Command exited with non-zero code: 1" and the actual
# reason is in config.log, which the runner then throws away. Dump it on the way
# out so a failing build says WHY on its first attempt rather than its second.
dump_config_log() {
  for f in source/php-src/config.log source/php-src/configure.log; do
    [ -f "$f" ] || continue
    echo "::group::$f (last 120 lines)"
    tail -120 "$f"
    echo "::endgroup::"
    # The line configure itself considers the failure.
    echo "--- configure error lines ---"
    grep -nE "^configure: error|error:|not found|No package" "$f" | tail -20 || true
  done
}
trap 'rc=$?; [ $rc -ne 0 ] && dump_config_log; exit $rc' EXIT

say "build (cli + fpm)"
time ./spc build "$EXTS" --build-cli --build-fpm --debug

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
