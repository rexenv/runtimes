#!/usr/bin/env bash
# Build PHP 8.x (cli + fpm) as a statically-dep-linked Mach-O via static-php-cli,
# with the extension set static-php.dev's "bulk" builds carry **plus the one it
# is missing: `pdo_pgsql`**.
#
# ─── Why this build exists at all ────────────────────────────────────────────
#
# rexenv took its 8.x binaries from static-php.dev's bulk builds, which is a good
# deal: somebody else's CI, a wide extension set, a new patch within days. It has
# one hole, and the hole is not small.
#
# **The bulk builds have `pgsql` and no `pdo_pgsql`** — and their PDO advertises
# `pgsql` anyway. Measured 9 Sep 2026 against real clusters (PostgreSQL 16.14,
# 17.10, 18.6) with the shipped 8.3 and 8.4:
#
#   php -m                          → pgsql, no pdo_pgsql
#   extension_loaded('pdo_pgsql')   → false   (on all seven versions rexenv ships)
#   PDO::getAvailableDrivers()      → mysql, pgsql, sqlite   ← says otherwise
#   pg_connect(...)                 → connects, queries, fine
#   new PDO('pgsql:...')            → TCP accepted, startup packet NEVER SENT;
#                                     the server closes it on authentication_timeout
#                                     ("server closed the connection unexpectedly")
#   the same call from Homebrew PHP  → connects instantly, same server
#
# So a driver that announces itself and then stalls for a minute. Laravel's
# `pgsql` connection and any PDO-based app go through exactly that call, which is
# why rexenv refuses to create a PostgreSQL-backed site today
# (rexenv `core::php::PDO_PGSQL_IN_BUNDLED_PHP`, ledger #545).
#
# And it is fixable here: an spc build of the same PHP with `pdo_pgsql` in the
# extension list produces `extension_loaded('pdo_pgsql') === true` and a working
# connection — built and measured locally on 9 Sep 2026 (PHP 8.3.33, arm64,
# 161 s: `ok 42` out of a real PostgreSQL 18.6). This script is that experiment
# turned into an artifact, which is why the PostgreSQL gate below is a REAL
# CONNECTION and not a module-list check: the module list is what lied.
#
# Usage: scripts/build-php.sh <version> <aarch64|x86_64> <outdir> [prebuilt]
set -euo pipefail

PHP_VERSION="${1:?php version required, e.g. 8.3.33}"
ARCH="${2:?arch required: aarch64 or x86_64}"
OUT="${3:?output dir required}"
# spc's pre-built dependency archives. On by default (a source build of ICU alone
# dominates the run); the toggle exists so a dependency can be ruled out as a
# failure cause without editing this file, exactly as in build-php74.sh.
PREBUILT="${4:-true}"

case "$PHP_VERSION" in
  8.*) ;;
  *) echo "::error::this script builds 8.x — 7.4 has its own (patched source, C23 flags): scripts/build-php74.sh"; exit 1 ;;
esac

# ─── Pins ────────────────────────────────────────────────────────────────────
# static-php-cli, pinned to bytes: the tool that builds a pinned artifact should
# itself be pinned. Same version and digests as the 7.4 build — one tool, one pin.
SPC_VERSION="2.8.5"
SPC_SHA256_aarch64="acf2f25d56d0cbf8e65aa82e5054fef555f7be7c5c38046c6e0819f266d83225"
SPC_SHA256_x86_64="e8b798048f62ca4960764196543b60ae703f7174aa418824cf542aeec1d2cd6a"

# The oldest macOS these binaries run on. 12.0 is spc's own macOS default and the
# floor every PHP rexenv already ships was built at — measured, not assumed, and
# asserted per artifact below so a runner-image change is a build failure here
# rather than a discovery on somebody's older Mac.
export MACOSX_DEPLOYMENT_TARGET="12.0"

# PostgreSQL used by the connect gate. A real server, because the thing this
# build exists to fix is invisible to every check that does not open a socket.
PG_BREW_FORMULA="postgresql@16"
PG_GATE_PORT="55432"

case "$ARCH" in
  aarch64) MAC_ARCH=arm64 ;;
  *)       MAC_ARCH="$ARCH" ;;
esac

# ─── Compiler flags: the C23 default vs PHP 8.0/8.1's sources ────────────────
#
# The runner's clang defaults to `-std=gnu23`, which REMOVED K&R function
# definitions. PHP 8.0 and 8.1 still contain them — measured, not predicted, on
# run 34346526410, where both minors died on both arches while 8.2-8.5 built
# clean:
#
#   ext/bcmath/libbcmath/src/init.c:65: error: unknown type name 'num'
#   ext/libxml/libxml.c:431: error: expected ')'
#
# `-std=gnu17` for those two, applied to PHP'S OWN compile only. NOT via
# SPC_DEFAULT_C_FLAGS, which spc feeds to every library it builds: the moment a
# C++ dependency appears (libjxl, through imagick → ImageMagick) that fails with
# `invalid argument '-std=gnu17' not allowed with 'C++'`. build-php74.sh learned
# that one the expensive way; this is the same lesson, not a new one.
#
# The value RESTATES spc's own default for these versions (from the failing make
# line in that run) because the loader fills UNSET variables only — setting this
# replaces the default rather than extending it, so anything left out is lost.
# Everything this script reads from the repository is resolved to an ABSOLUTE
# path HERE, before the first `cd`. The parity gate below took its reference as
# `$(dirname $0)/../docs/...`, which is correct where the script starts and
# meaningless after `cd "$WORK"` — so in CI the file was "not found" and the gate
# printed a warning and passed. It was green on the laptop only because it was
# invoked by absolute path. A guard whose input path can go missing is a guard
# that reports success when it has checked nothing.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHP_MINOR="${PHP_VERSION%.*}"
PARITY_REF="$REPO_ROOT/docs/bulk-modules-${PHP_MINOR}.txt"
PHP_LICENSE="$REPO_ROOT/licenses/PHP-3.01.txt"

# swoole's own floor. spc pins the swoole source to `v6.*` (config/source.json),
# and swoole 6 refuses to compile below 8.2 — "require PHP version 8.2 or later",
# which is what killed both old minors on run 34351885411 once the C23 flag had
# cleared the first wall. Upstream's bulk 8.0/8.1 DO carry swoole, so dropping it
# would be a parity loss; they carry an older release, and so do these.
SWOOLE_5="https://github.com/swoole/swoole-src/archive/refs/tags/v5.1.7.tar.gz"
CUSTOM_URLS=""
case "$PHP_VERSION" in
  8.0.*|8.1.*) CUSTOM_URLS="swoole:$SWOOLE_5" ;;
esac

case "$PHP_VERSION" in
  8.0.*|8.1.*)
    export SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS="-g -fstack-protector-strong -fpic -fpie -Werror=unknown-warning-option --target=${MAC_ARCH}-apple-darwin -Os -Wno-strict-prototypes -std=gnu17 -Wno-incompatible-function-pointer-types"
    ;;
esac

# ─── Extension set ───────────────────────────────────────────────────────────
# **Parity with the bulk builds, derived from a shipped binary rather than from
# a list somebody typed**: `php -m` on rexenv's pinned 8.3.31 bulk artifact, minus
# the core/always-on modules (core, date, hash, json, libxml, mysqlnd, pcre, pdo,
# random, reflection, session's deps, spl, standard), plus the two PDO drivers.
#
# Parity is the point. This build REPLACES the upstream one for the versions it
# covers, so anything dropped here is a capability a user had yesterday and does
# not have today — the failure mode that is discovered on somebody's site.
#
#   pdo_pgsql   the whole reason this file exists (see the header)
#   pdo_sqlite  bulk's PDO advertises `sqlite` and pdo_sqlite works there, but it
#               is a builtin driver that never appears in `php -m` — named here
#               so parity is a fact rather than an inference from a driver list
#               that has already been caught lying once.
# The BASE set: everything this build knows how to ask spc for. What is actually
# built is this list INTERSECTED with the minor's parity reference, plus the two
# PDO drivers that never appear in a module list.
#
# Derived rather than hand-maintained per version, because the upstream sets are
# not the same across minors and the differences are real version floors: 8.0's
# bulk build has no `opentelemetry`, and asking for it there would fail a build
# to add something the artifact it replaces never had. Reading the floor off the
# artifact is the same discipline as the parity gate itself — the alternative is
# six lists somebody has to remember to edit.
BASE_EXTS="apcu bcmath bz2 calendar ctype curl dba dom event exif fileinfo filter ftp gd gmp iconv imagick imap intl mbstring mysqli opcache opentelemetry openssl pcntl pdo_mysql pgsql phar posix protobuf readline redis session shmop simplexml soap sockets sodium sqlite3 swoole sysvmsg sysvsem sysvshm tokenizer xml xmlreader xmlwriter xsl zip zlib"

# ALWAYS added, never in a module list: pdo_pgsql is the reason this file exists,
# and pdo_sqlite is a builtin driver `php -m` does not print (so the parity file
# cannot carry it either).
ALWAYS_EXTS="pdo_pgsql pdo_sqlite"

[ -f "$PARITY_REF" ] || { echo "::error::no parity reference at $PARITY_REF — it decides the extension set AND the gate; refusing to guess"; exit 1; }
EXTS=""
for e in $BASE_EXTS; do
  if grep -qxF "$e" "$PARITY_REF"; then
    EXTS="${EXTS:+$EXTS,}$e"
  else
    echo "skipping $e — the bulk $PHP_MINOR build does not have it either"
  fi
done
for e in $ALWAYS_EXTS; do EXTS="${EXTS:+$EXTS,}$e"; done

# Libraries named explicitly rather than taken via --with-suggested-libs: the
# suggestion graph pulls things nothing here needs (qdbm, libavif) into the same
# link line that PHP's gd check RUNS a conftest against, and a library that traps
# on load then fails the build blaming gd. Same reasoning as build-php74.sh, and
# the same list plus what the wider 8.x set needs.
LIBS="freetype,libjpeg,libwebp,libpng,zlib,bzip2,gmp,libxslt,libedit,imagemagick,libevent,postgresql,openssl,libzip,icu"

# Extensions the app cannot run without, asserted on the BUILT binary: spc will
# happily drop one that failed to configure and still produce a working php.
# `phar` leads the list because rexenv runs WP-CLI and Composer as phars through
# the site's PHP — a build without it passes `php -v` and fails every WordPress
# action (that is not hypothetical; it shipped once, see build-php74.sh).
# `pdo_pgsql` is here for the same class of reason, one step further: it must be
# present AND it must connect.
REQUIRED_EXTS="phar mysqli pdo_mysql pdo_pgsql pgsql curl gd mbstring json xml dom openssl zip sodium intl posix opcache"

say() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }

# ─── Toolchain ───────────────────────────────────────────────────────────────
say "toolchain"
clang --version | head -2
echo "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
echo "pre-built deps: $PREBUILT"
echo "parity reference: $(basename "$PARITY_REF")"
echo "PHP EXTRA_CFLAGS=${SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS:-<spc default>}"

# ─── static-php-cli ──────────────────────────────────────────────────────────
say "static-php-cli $SPC_VERSION"
WORK="$(pwd)/spc-work"
mkdir -p "$WORK" && cd "$WORK"
curl -fSL -o spc.tar.gz \
  "https://github.com/crazywhalecc/static-php-cli/releases/download/${SPC_VERSION}/spc-macos-${ARCH}.tar.gz"
EXPECT="SPC_SHA256_${ARCH}"
echo "${!EXPECT}  spc.tar.gz" | shasum -a 256 -c - \
  || { echo "::error::spc checksum mismatch — refusing to build with an unpinned tool"; exit 1; }
tar xzf spc.tar.gz && chmod +x spc
./spc --version

# ─── Build ───────────────────────────────────────────────────────────────────
say "download sources"
./spc download \
  --with-php="${PHP_VERSION}" \
  ${CUSTOM_URLS:+--custom-url="$CUSTOM_URLS"} \
  --for-extensions="$EXTS" \
  --for-libs="$LIBS" \
  $( [ "$PREBUILT" = "true" ] && echo --prefer-pre-built ) \
  --retry=5 \
  --debug

say "doctor"
./spc doctor --auto-fix || true

# spc runs ./configure itself and swallows its output — a failed configure comes
# back as "Command exited with non-zero code: 1" with the reason in a config.log
# the runner then throws away. Keep the WHOLE file: twice on the 7.4 build a
# last-120-lines view showed configure's later probes and not the failure.
dump_config_log() {
  mkdir -p "$OUT/debug"
  cp -f source/php-src/config.log "$OUT/debug/" 2>/dev/null || true
  cp -rf log "$OUT/debug/spc-log" 2>/dev/null || true
  n="$(grep -n '^configure: error' source/php-src/config.log 2>/dev/null | tail -1 | cut -d: -f1)"
  if [ -n "${n:-}" ]; then
    echo "::group::config.log around the failure (line $n)"
    sed -n "$(( n > 80 ? n - 80 : 1 )),$((n + 5))p" source/php-src/config.log
    echo "::endgroup::"
  fi
  grep -nE "^configure: error" source/php-src/config.log 2>/dev/null || true
}
trap 'rc=$?; [ $rc -ne 0 ] && dump_config_log; exit $rc' EXIT

say "build (cli + fpm)"
time ./spc build "$EXTS" --with-libs="$LIBS" --build-cli --build-fpm --debug

# ─── Gates. Every one of these has a specific way of being wrong. ────────────
say "gates"
BIN="$WORK/buildroot/bin"

# 1. It is the version we think it is, and it runs.
"$BIN/php" -v
"$BIN/php" -v | grep -q "PHP ${PHP_VERSION}" || { echo "::error::wrong PHP version"; exit 1; }
"$BIN/php-fpm" -v | grep -q "PHP ${PHP_VERSION}" || { echo "::error::wrong php-fpm version"; exit 1; }

# 2. Every required extension is actually IN it.
# `php -m` prints opcache as "Zend OPcache" — a space and a different word from
# the name it is asked for by, which failed this gate on a build that HAD it.
# Normalised here so the required list, the parity list and the build all spell
# modules one way.
# …and `php -m` prints "[php modules]" / "[zend modules]" section headers, which
# are not modules. One normalised list, used by this gate and the parity one.
MODS="$("$BIN/php" -m | tr 'A-Z' 'a-z' | sed 's/zend opcache/opcache/' \
        | grep -v '^\[' | grep . | sort -u)"
for e in $REQUIRED_EXTS; do
  echo "$MODS" | grep -qx "$e" || { echo "::error::missing required extension: $e"; exit 1; }
done
echo "modules ($(echo "$MODS" | grep -c .)): $(echo "$MODS" | tr '\n' ' ')"

# 3. PARITY with the upstream build this replaces. A capability a user had
#    yesterday and lost today is the whole risk of self-hosting, and it is
#    invisible in a green build unless something compares the two lists. The
#    reference list is committed beside this script, generated from a shipped
#    bulk binary; anything in it that is missing here fails the build.
REF="$PARITY_REF"
# A missing reference is a BUILD FAILURE, not a warning. The first version
# warned and carried on, which is how it passed twice in CI having compared
# nothing (run 34335791126).
[ -f "$REF" ] || { echo "::error::no parity reference at $REF — this gate cannot run, and it is not optional"; exit 1; }
if true; then
  lost=""
  while read -r m; do
    # The reference file carries its own provenance in comments — skip those and
    # blanks, or the gate compares the build against English prose (it did).
    case "$m" in ''|'#'*) continue ;; esac
    echo "$MODS" | grep -qx "$m" || lost="$lost $m"
  done < "$REF"
  if [ -n "$lost" ]; then
    echo "::error::this build DROPS extensions the upstream bulk build carries:$lost"
    echo "::error::parity is the contract — add them back, or record the reason in the release notes"
    echo "::error::and remove them from $REF in the same commit."
    exit 1
  fi
  echo "parity: every module in $(basename "$REF") is present ($(grep -cvE '^\s*(#|$)' "$REF") compared)"
fi

# 4. The dylib closure is what rexenv's relink_to_system_libs accepts. Anything
#    outside /usr/lib + /System makes rexenv hard-error at resolve() on the
#    user's machine, long after this build.
for f in "$BIN/php" "$BIN/php-fpm"; do
  if otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/)' | grep .; then
    echo "::error::$f links a non-system dylib"; exit 1
  fi
done
otool -L "$BIN/php" | grep -q libreadline && { echo "::error::links GPL readline"; exit 1; } || true

# 5. Mach-O arch matches the job, and the deployment target survived.
for f in "$BIN/php" "$BIN/php-fpm"; do
  file "$f" | grep -q "$MAC_ARCH" || { echo "::error::$f is not $MAC_ARCH: $(file "$f")"; exit 1; }
  MINOS="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  [ "$MINOS" = "$MACOSX_DEPLOYMENT_TARGET" ] \
    || { echo "::error::$f minos=$MINOS want $MACOSX_DEPLOYMENT_TARGET"; exit 1; }
done

# 6. THE GATE THIS BUILD EXISTS FOR: a real PostgreSQL connection through PDO.
#
#    Not `php -m | grep pdo_pgsql`, and not `PDO::getAvailableDrivers()`. Both of
#    those said PostgreSQL was available in the artifact this build replaces, and
#    both were wrong — the driver list said `pgsql` with no driver behind it. The
#    only check that could have caught it is the one that opens a socket, so that
#    is the check.
#
#    The cluster is this job's own: initdb into a temp dir, trust auth, a port
#    nothing else uses, torn down after. It never touches a runner service.
say "PostgreSQL: a REAL connection through PDO"
if [ "${SKIP_PG_GATE:-}" = "1" ]; then
  echo "::error::SKIP_PG_GATE is set — this is the gate the build exists for; refusing"
  exit 1
fi
# CI installs its own server; a laptop can point at one it already has
# (PG_BIN_DIR). What is NOT negotiable is that the gate runs — the connection is
# the claim, so there is no path here that skips it, only paths that find the
# server differently.
if [ -n "${PG_BIN_DIR:-}" ]; then
  PG_BIN="$PG_BIN_DIR"
  echo "using the PostgreSQL at $PG_BIN (PG_BIN_DIR)"
else
  brew install "$PG_BREW_FORMULA" >/dev/null
  PG_BIN="$(brew --prefix "$PG_BREW_FORMULA")/bin"
fi
[ -x "$PG_BIN/initdb" ] || { echo "::error::no initdb at $PG_BIN — the PostgreSQL gate cannot run"; exit 1; }
PG_DATA="$(mktemp -d)/pgdata"
"$PG_BIN/initdb" -D "$PG_DATA" -U postgres -A trust --no-instructions >/dev/null
"$PG_BIN/pg_ctl" -D "$PG_DATA" -o "-p $PG_GATE_PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=" -w start
pg_stop() { "$PG_BIN/pg_ctl" -D "$PG_DATA" -m immediate stop >/dev/null 2>&1 || true; }
trap 'rc=$?; pg_stop; [ $rc -ne 0 ] && dump_config_log; exit $rc' EXIT

cat > /tmp/pg-probe.php <<'PHP'
<?php
// Everything Laravel's first minute does: connect, DDL, write, read back.
$dsn = sprintf('pgsql:host=127.0.0.1;port=%d;dbname=postgres', (int)$argv[1]);
$pdo = new PDO($dsn, 'postgres', '', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$pdo->exec('CREATE TABLE probe (id serial PRIMARY KEY, note text NOT NULL)');
$st = $pdo->prepare('INSERT INTO probe (note) VALUES (?)');
$st->execute(['built here']);
echo 'PDO_PGSQL_OK:', $pdo->query('SELECT note FROM probe')->fetchColumn(), "\n";
PHP
if ! "$BIN/php" /tmp/pg-probe.php "$PG_GATE_PORT" | grep -q "PDO_PGSQL_OK:built here"; then
  echo "::error::pdo_pgsql cannot talk to a real PostgreSQL — this build is the upstream bug again"
  exit 1
fi
echo "pdo_pgsql: connected, created, wrote and read back on PostgreSQL $("$PG_BIN/postgres" -V | awk '{print $3}')"
# ext/pgsql too: rexenv does not use it, but a build where the two disagree is a
# build worth looking at before it ships.
"$BIN/php" -r '$c = pg_connect("host=127.0.0.1 port='"$PG_GATE_PORT"' dbname=postgres user=postgres") or exit(1);' \
  || { echo "::error::ext/pgsql cannot connect"; exit 1; }
pg_stop
trap 'rc=$?; [ $rc -ne 0 ] && dump_config_log; exit $rc' EXIT

# 7. A real request through php-fpm's own binary, and the tools rexenv runs ON
#    this PHP. Both WP-CLI and Composer are phars executed through the site's
#    PHP: a list of extensions is a proxy, running the tools is the claim.
say "the tools rexenv runs on this PHP"
WP_CLI_VERSION="2.12.0"
COMPOSER_VERSION="2.10.2"
curl -fSL -o /tmp/wp-cli.phar \
  "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"
curl -fSL -o /tmp/composer.phar "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar"
"$BIN/php" /tmp/wp-cli.phar --version \
  || { echo "::error::WP-CLI cannot run on this build"; exit 1; }
"$BIN/php" /tmp/composer.phar --version \
  || { echo "::error::Composer cannot run on this build"; exit 1; }
rm -f /tmp/wp-cli.phar /tmp/composer.phar

# 8. Zend symbols: what decides whether Xdebug can ever dlopen into this binary.
#    Recorded rather than enforced — rexenv's xdebug_supported() answers per
#    minor, and a build that exports fewer simply gets no toggle.
# Read the symbols ONCE into a variable, and match against that.
#
# `nm … | grep -q` under `set -o pipefail` is a trap this build fell into: grep
# exits at the first match, nm is killed by SIGPIPE, the PIPELINE reports 141,
# and the `if` takes the else branch — so the check reports the OPPOSITE of what
# it found. It said "NO _OnUpdateBool" about a binary that exports it. Anywhere a
# `grep -q` reads a long stream here, it reads a variable instead.
SYMTAB="$(nm -gU "$BIN/php-fpm")"
SYMS="$(printf '%s\n' "$SYMTAB" | wc -l | tr -d ' ')"
if grep -q _OnUpdateBool <<<"$SYMTAB"; then
  echo "zend-symbols: $SYMS exported, _OnUpdateBool present → Xdebug can dlopen"
else
  echo "::warning::zend-symbols: $SYMS exported, NO _OnUpdateBool → no Xdebug on this build"
fi

# ─── Licences ────────────────────────────────────────────────────────────────
# Static linking puts these libraries INSIDE the binary, so their licences travel
# with it, and we are the distributor. Collected from the sources spc actually
# downloaded — a hand-kept list would describe the extension set as it was the
# day somebody wrote it.
say "licences"
LIC="$OUT/licenses"
mkdir -p "$LIC"
cp "$PHP_LICENSE" "$LIC/" 2>/dev/null || true
found=0
for d in source/*/; do
  name="$(basename "$d")"
  for f in LICENSE LICENSE.txt LICENSE.md LICENCE LICENCE.txt COPYING COPYING.txt \
           COPYRIGHT Copyright copyright LICENSE-MIT NOTICE; do
    if [ -f "$d$f" ]; then cp "$d$f" "$LIC/${name}.${f}"; found=$((found + 1)); break; fi
  done
done
echo "collected $found dependency licence files from $(ls -d source/*/ 2>/dev/null | wc -l | tr -d ' ') sources"
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
# Same names and shapes as the artifacts these replace, so rexenv's binary
# catalog changes a URL and a digest and nothing else.
say "package"
mkdir -p "$OUT"
tar -C "$BIN" -czf "$OUT/php-${PHP_VERSION}-cli-macos-${ARCH}.tar.gz" php
tar -C "$BIN" -czf "$OUT/php-${PHP_VERSION}-fpm-macos-${ARCH}.tar.gz" php-fpm
tar -C "$OUT" -czf "$OUT/licenses-php-${PHP_VERSION}-${ARCH}.tar.gz" licenses && rm -rf "$LIC"
( cd "$OUT" && shasum -a 256 ./php-${PHP_VERSION}-*-macos-${ARCH}.tar.gz | tee "SHA256SUMS-php-${PHP_VERSION}-${ARCH}" )
ls -lh "$OUT"

say "record"
echo "artifact sizes:"; ls -l "$OUT"/*.tar.gz | awk '{printf "  %-56s %s\n", $9, $5}'
echo "extension count: $(echo "$MODS" | grep -c .)"
