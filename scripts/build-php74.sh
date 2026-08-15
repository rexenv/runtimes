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

# PHP 7.4 contains K&R (old-style) function definitions — ext/bcmath's libbcmath
# is full of them:
#
#     void bc_add (n1, n2, result, scale_min)
#          bc_num n1, n2, *result;
#          int scale_min;
#
# **C23 removed that syntax**, and the runner's clang now defaults to
# `-std=gnu23`, so every one becomes `error: unknown type name 'n1'`. Homebrew's
# php@7.4 formula sets the same flag for the same reason.
#
# It goes through SPC_DEFAULT_C_FLAGS rather than CFLAGS because spc composes its
# own compile flags from that variable and would otherwise drop ours — and
# because spc's env loader only fills variables that are UNSET
# (`GlobalEnvManager::init`: `if (getenv($k) === false)`), so exporting it here
# wins over config/env.ini. The value must therefore repeat spc's own default
# (`--target=<arch>-apple-darwin -Os`), since we are replacing it, not appending.
case "$ARCH" in
  aarch64) MAC_ARCH=arm64 ;;
  *)       MAC_ARCH="$ARCH" ;;
esac
#
# `-Wno-incompatible-function-pointer-types` is the second half of the same
# story. clang 16+ promoted that mismatch from warning to ERROR, and 7.4's
# ext/curl declares its progress callback with the pre-curl-8 signature
# (`double` where curl now passes `curl_off_t`). Homebrew's php@7.4 formula
# passes the same flag, gated on Apple clang >= 1500.
#
# It is a real narrowing of safety and worth naming as such: the mismatch it
# permits is the one PHP 7.4 has always had with modern curl, and the callback
# is called by curl with the wider type either way. The alternative is patching
# ext/curl's signatures, which is a bigger diff against a dead branch for the
# same runtime behaviour.
export SPC_DEFAULT_C_FLAGS="--target=${MAC_ARCH}-apple-darwin -Os -std=gnu17 -Wno-incompatible-function-pointer-types"
# NOTE: this does NOT fix intl. `PHP_CXX_COMPILE_STDCXX` appends intl's own
# `-std=` AFTER the environment's, so `-std=c++11` wins whatever we set here —
# which is why patches/0002 changes the standard where intl chooses it. Kept
# because it is still the right default for C++ elsewhere in the tree.
export SPC_DEFAULT_CXX_FLAGS="--target=${MAC_ARCH}-apple-darwin -Os -std=c++17"
# Repeats spc's own macOS default and appends one flag; the loader only fills
# UNSET variables, so exporting replaces rather than extends — the default has
# to be restated or the build loses --disable-all and every other part of it.
export SPC_CMD_PREFIX_PHP_CONFIGURE="./configure --prefix= --with-valgrind=no --enable-shared=no --enable-static=yes --disable-all --disable-phpdbg --without-pcre-jit"

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
# Extension set, aimed at parity with the static-php.dev "bulk" builds rexenv
# ships for 8.x — because a 7.4 site should not quietly have fewer capabilities
# than an 8.3 one.
#
# **`phar` is not optional and its absence is not cosmetic.** rexenv runs WP-CLI
# and Composer as .phar archives THROUGH THE SITE'S PHP, so a build without it
# cannot perform a single WordPress operation: `wp core download` dies with
# `Class 'Phar' not found` before it reads a byte of the site. This set once
# omitted it — narrowed while chasing the gd failure on a hypothesis that turned
# out wrong, and never widened back — and the gate below did not catch it because
# the required list did not name it. Both are fixed; see the phar gate.
#
# gd works via patches/0001 — upstream's own PHP_TEST_BUILD fix. 7.4's macro
# EXECUTES a probe linked against libpng/webp/jpeg/freetype; by PHP 8.3 upstream
# had made it link-only.
#
# Still absent, and each for a reason rather than an oversight:
#   opcache                     spc's static-opcache patch series starts at 8.0
#   opentelemetry, protobuf     spc guards them on PHP >= 8.0
#   swoole, event               modern releases dropped 7.4
#   random                      a PHP 8.2 core extension; 7.4 has no equivalent
#   apcu, redis, imagick, imap  PECL; added after the first parity build proves out
EXTS="bcmath,bz2,calendar,ctype,curl,dba,dom,exif,fileinfo,filter,ftp,gd,gmp,iconv,intl,mbstring,mysqli,openssl,pcntl,pdo_mysql,pgsql,phar,posix,readline,session,shmop,simplexml,soap,sockets,sodium,sqlite3,sysvmsg,sysvsem,sysvshm,tokenizer,xml,xmlreader,xmlwriter,xsl,zip,zlib"

# Libraries gd needs before PHP's bundled GD will link at all. spc only builds an
# extension's SUGGESTED libs when asked (`--with-suggested-libs`), and without
# them `gd.php` emits a bare `--enable-gd` — which on 7.4 fails configure with
# "GD build test failed", 40 minutes into the build and with the reason only in
# config.log. Named explicitly as well as via the suggestion flag, so the set is
# visible here rather than implied by another project's defaults.
LIBS="freetype,libjpeg,libwebp,libpng,zlib,bzip2,gmp,libxslt,libedit"

# Extensions WordPress cannot run without. Asserted on the built binary, so a
# silently-dropped extension fails the build instead of shipping.
# phar leads this list deliberately: rexenv's own tooling is phars, so a build
# without it fails every WordPress action while `php -v` looks perfectly healthy.
REQUIRED_EXTS="phar mysqli pdo_mysql curl gd mbstring json xml dom openssl zip sodium intl posix"

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
echo "SPC_DEFAULT_C_FLAGS=$SPC_DEFAULT_C_FLAGS"
echo "SPC_DEFAULT_CXX_FLAGS=$SPC_DEFAULT_CXX_FLAGS"

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
  grep -q 'AC_LINK_IFELSE' build/php.m4 \
    || { echo "::error::PHP_TEST_BUILD still RUNS its conftest — the gd trap is back"; exit 1; }
  grep -q "char foobar(void) { return '\\\\0'; }" ext/gd/config.m4 \
    || { echo "::error::the gd conftest stub was not updated"; exit 1; }
  grep -q 'atleast-version=74' ext/intl/config.m4 \
    || { echo "::error::intl still hardcodes C++11 — ICU 74+ headers will not compile"; exit 1; }
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
# PCRE JIT is removed at CONFIGURE time, not asked off via ini.
#
# PHP 7.4 bundles **PCRE2 10.35 (May 2020)**, which predates sljit's Apple
# Silicon support; 8.3 bundles 10.42. So on arm64 the JIT allocation always
# fails — measured identical signed and unsigned, so it is the library, not our
# codesign. `preg_match` survives (JIT quietly disables) but Composer's Symfony
# console promotes the warning to an exception and dies outright.
#
# **This is invisible to CI**, which is why it is a hardcoded ini rather than a
# gate: the GitHub runner's OS permits the allocation and a developer's Mac does
# not, so a build that passes every check here still fails on the machine that
# matters. The only honest fix is to stop attempting JIT at all. Cost is some
# regex throughput on a version nobody runs for speed.
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
  # file(1) says "arm64"; our artifact names say "aarch64". Compare against the
  # TOOLCHAIN spelling (MAC_ARCH), not the filename one — this gate failed a
  # perfectly good binary once already, which is the failure mode a strict check
  # is allowed exactly once.
  file "$f" | grep -q "$MAC_ARCH" || { echo "::error::$f is not $MAC_ARCH: $(file "$f")"; exit 1; }
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

# 7. THE TOOLS REXENV ACTUALLY RUNS ON THIS PHP. Both WP-CLI and Composer are
#    .phar archives executed through the SITE'S php, so a build without `phar`
#    passes every check above and then fails every WordPress action with
#    `Class 'Phar' not found` — which is exactly what shipped, because the
#    module list this gate compares against did not name phar. A list of
#    extensions is a proxy; running the tools is the claim itself.
say "the tools rexenv runs on this PHP"
WP_CLI_VERSION="2.12.0"
COMPOSER_VERSION="2.10.2"
curl -fSL -o /tmp/wp-cli.phar \
  "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"
curl -fSL -o /tmp/composer.phar "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar"
"$BIN/php" /tmp/wp-cli.phar --version \
  || { echo "::error::WP-CLI cannot run on this build — every WordPress action in rexenv is this phar"; exit 1; }
"$BIN/php" /tmp/composer.phar --version \
  || { echo "::error::Composer cannot run on this build — the site's PHP is what runs it"; exit 1; }
rm -f /tmp/wp-cli.phar /tmp/composer.phar

# 8. PCRE JIT must be OFF and must stay off. Asserted on the ini AND on real
#    behaviour, because the ini alone would not notice a build that ignored it —
#    and the failure this prevents cannot be reproduced on this runner at all.
#    Assert the CAPABILITY is absent, not that a setting requests it be unused:
#    an ini can be overridden and, as `-I` proved, can silently fail to apply.
if "$BIN/php" -i | grep -i "PCRE JIT Support" | grep -qi "enabled"; then
  echo "::error::PCRE JIT is still compiled in — Composer will die on Apple Silicon"
  echo "::error::$("$BIN/php" -i | grep -i 'PCRE JIT Support')"
  exit 1
fi
if "$BIN/php" -r 'preg_match("/^a(b)c$/","abc");' 2>&1 | grep -q "JIT memory"; then
  echo "::error::PCRE still attempts JIT"; exit 1
fi
echo "PCRE JIT: $("$BIN/php" -i | grep -i 'PCRE JIT Support') — PHP 7.4 bundles PCRE2 10.35, too old for Apple Silicon"

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
  # libxml2 ships `Copyright`; others use COPYING/LICENSE/LICENCE spellings.
  # The list grew by one real miss — keep adding rather than lowering the bar.
  for f in LICENSE LICENSE.txt LICENSE.md LICENCE LICENCE.txt COPYING COPYING.txt \
           COPYRIGHT Copyright copyright LICENSE-MIT NOTICE; do
    if [ -f "$d$f" ]; then
      cp "$d$f" "$LIC/${name}.${f}"
      found=$((found + 1))
      break
    fi
  done
done
echo "collected $found dependency licence files from $(ls -d source/*/ 2>/dev/null | wc -l | tr -d ' ') sources"

# A statically linked dependency whose licence we cannot find is one we would be
# shipping blind, and we are the distributor. This is a build FAILURE, not a
# warning: a warning in a green build is a warning nobody reads, and the whole
# point of collecting these from the real sources was to stop the licence set
# from describing last year's extension list.
missing=""
for d in source/*/; do
  name="$(basename "$d")"
  ls "$LIC/${name}."* >/dev/null 2>&1 || missing="$missing $name"
done
if [ -n "$missing" ]; then
  echo "::error::no licence file found for:$missing"
  echo "::error::we distribute these bytes — find the licence, or add an explicit"
  echo "::error::exception here saying WHY that source ships without one."
  exit 1
fi

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
