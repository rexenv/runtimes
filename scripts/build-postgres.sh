#!/bin/bash
# Build a relocatable PostgreSQL tree for macOS with a deployment target rexenv
# can ship on macOS 13 and 14.
#
#   scripts/build-postgres.sh <version: e.g. 18.7.0> <arch: aarch64|x86_64> <out-dir>
#
# ─── Why this exists ─────────────────────────────────────────────────────────
#
# rexenv pins theseus-rs/postgresql-binaries, and what those declare is whatever
# runner built them:
#
#   June 2026 builds      minos 26.0, every Mach-O        (re-pinned 30 Aug 2026)
#   18.6.0/17.11.0/…      minos 15.0, both slices
#   16.4.0                minos 14.0 arm64 / 13.0 x86_64  ← the newest that loads on 14
#   anything, arm64       never below 14.0                ← nothing loads on 13
#
# So on macOS 14 rexenv offers ONE PostgreSQL, a 2024 patch of 16, and on macOS 13
# it offers none and says "needs macOS 14" (rexenv docs/PLAN-macos-13-floor.md
# §3.5, §6.2). This build is §6.6 rule 3, item 1: the same reason rexenv builds
# its own nginx — when the floor an artifact declares decides who can run it, the
# only way to control it is to set it yourself.
#
# ─── What it is: upstream's build, lower floor ───────────────────────────────
#
# The configure flags are theseus-rs's, read out of their `pg_config --configure`,
# and a gate below compares the two trees name for name (programs, loadable
# modules, extensions, flags). A site that worked on their build must work on
# this one: the mandate is the floor, not the feature set.
#
# The ONE deliberate difference: OpenSSL is built here, static, at the same
# deployment target, and linked INTO libpq and the server instead of riding along
# as two dylibs. Upstream's `libssl.3.dylib`/`libcrypto.3.dylib` are Homebrew's,
# and a Homebrew bottle's floor is the bottle's macOS — the same accident, one
# level down. Static also means the tree's closure is the system plus itself.
set -euo pipefail

VERSION="${1:?version required, e.g. 18.7.0}"
ARCH="${2:?arch required: aarch64|x86_64}"
OUT="${3:?output dir required}"

OPENSSL_VERSION="${OPENSSL_VERSION:-3.6.5}"
# 13.0: the app's stated floor (rexenv tauri.conf.json, PLAN-macos-13-floor).
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
# A fixture port for the run gate — not PostgreSQL's 5432, not rexenv's 15432.
GATE_PORT="${GATE_PORT:-15499}"

case "$ARCH" in
  aarch64) MAC_ARCH="arm64";  OSSL_TARGET="darwin64-arm64-cc" ;;
  x86_64)  MAC_ARCH="x86_64"; OSSL_TARGET="darwin64-x86_64-cc" ;;
  *) echo "::error::unknown arch $ARCH"; exit 1 ;;
esac

# rexenv spells PostgreSQL versions the way theseus-rs does, `<major>.<minor>.0`;
# postgresql.org's own is `<major>.<minor>`. One spelling in, both derived.
case "$VERSION" in
  *.*.0) PG_SRC_VERSION="${VERSION%.0}" ;;
  *) echo "::error::version must be <major>.<minor>.0 (rexenv's spelling), got $VERSION"; exit 1 ;;
esac

say()  { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
fail() { echo "::error::$*"; exit 1; }

# Native only. The gates RUN the tree (initdb, a server, psql), and configure runs
# test programs: a cross build would pass neither honestly. The x86_64 half runs
# as an x86_64 process tree — a real Intel runner, or `arch -x86_64` under Rosetta.
[ "$(uname -m)" = "$MAC_ARCH" ] \
  || fail "host is $(uname -m), target is $MAC_ARCH — run under \`arch -$MAC_ARCH /bin/bash\`"

# Upstream's flags (theseus-rs 18.6.0, `pg_config --configure`), minus the prefix
# and the Homebrew -L/-I that fed it OpenSSL. The parity gate re-reads upstream's
# own binary, so a flag they add later fails the build instead of going missing.
PG_FLAGS=(
  --enable-integer-datetimes
  --enable-option-checking=fatal
  --without-icu
  --without-ldap
  --with-libxml
  --with-libxslt
  --with-openssl
  --with-pgport=5432
  --with-readline
  --with-system-tzdata=/usr/share/zoneinfo
  --with-uuid=e2fs
)

WORK="$(mktemp -d)"
GATE_ROOT=""
PGPID_DIR=""
cleanup() {
  # A server the gate started must not outlive a failed gate.
  if [ -n "$PGPID_DIR" ] && [ -f "$PGPID_DIR/postmaster.pid" ]; then
    kill "$(head -1 "$PGPID_DIR/postmaster.pid")" 2>/dev/null || true
    sleep 1
  fi
  rm -rf "$WORK"
  [ -z "$GATE_ROOT" ] || rm -rf "$GATE_ROOT"
}
trap cleanup EXIT
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cd "$WORK"

NAME="postgresql-${VERSION}-macos-${ARCH}"
PREFIX="$WORK/stage/$NAME"
CPUS="$(sysctl -n hw.ncpu)"
TARGET_FLAGS="-arch ${MAC_ARCH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"

# Retried: a single HTTP/2 PROTOCOL_ERROR from ftp.postgresql.org (curl exit 92)
# killed the first local build of 18.6.0 before it compiled anything.
fetch() { curl -fsSL --retry 4 --retry-all-errors --retry-delay 3 -O "$1"; }

say "fetch"
PG_TARBALL="postgresql-${PG_SRC_VERSION}.tar.bz2"
OSSL_TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
fetch "https://ftp.postgresql.org/pub/source/v${PG_SRC_VERSION}/${PG_TARBALL}"
fetch "https://ftp.postgresql.org/pub/source/v${PG_SRC_VERSION}/${PG_TARBALL}.sha256"
fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${OSSL_TARBALL}"
fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${OSSL_TARBALL}.sha256"
# Both projects publish the digest beside the tarball. Checked, because these
# bytes are mirrored into the release as "the source that built this".
for t in "$PG_TARBALL" "$OSSL_TARBALL"; do
  WANT="$(awk '{print $1}' "$t.sha256")"
  GOT="$(shasum -a 256 "$t" | awk '{print $1}')"
  [ -n "$WANT" ] && [ "$WANT" = "$GOT" ] || fail "$t: sha256 $GOT, upstream publishes $WANT"
  echo "  $t  $GOT"
done
cp "$PG_TARBALL" "$OSSL_TARBALL" "$OUT/"
tar xjf "$PG_TARBALL"
tar xzf "$OSSL_TARBALL"

# ─── OpenSSL, static ─────────────────────────────────────────────────────────
say "openssl ${OPENSSL_VERSION} (static)"
OSSL="$WORK/ossl"
(
  cd "openssl-${OPENSSL_VERSION}"
  # --openssldir is where `sslrootcert=system` looks; /private/etc/ssl is macOS's
  # own (cert.pem ships with the OS). The default would be a path under $WORK.
  # no-atexit: libpq's own build REFUSES a library that can call exit ("libpq must
  # not be calling any function which invokes exit"), and a static libcrypto
  # brings `atexit` (its cleanup handler) straight into libpq.dylib — a dylib kept
  # it out of sight, which is the only reason upstream's shape passes that check.
  # The other offender, `pthread_exit`, is handled at PostgreSQL's link (LDFLAGS_SL).
  ./Configure "$OSSL_TARGET" no-shared no-tests no-docs no-atexit no-thread-pool no-default-thread-pool \
    --prefix="$OSSL" --openssldir=/private/etc/ssl \
    "-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}" > "$WORK/openssl-configure.log"
  make -j"$CPUS" build_libs > "$WORK/openssl-build.log" 2>&1 \
    || { tail -40 "$WORK/openssl-build.log"; fail "openssl build failed"; }
  make install_dev > "$WORK/openssl-install.log" 2>&1 \
    || { tail -40 "$WORK/openssl-install.log"; fail "openssl install failed"; }
)
[ -f "$OSSL/lib/libssl.a" ] && [ -f "$OSSL/lib/libcrypto.a" ] || fail "static OpenSSL missing"
# A dylib here would be linked in preference to the archive and ride out as a
# dependency on a path that only exists on the build host.
if ls "$OSSL"/lib/*.dylib >/dev/null 2>&1; then fail "OpenSSL built a dylib despite no-shared"; fi

# ─── PostgreSQL ──────────────────────────────────────────────────────────────
say "configure postgresql ${PG_SRC_VERSION}"
cd "postgresql-${PG_SRC_VERSION}"
# -headerpad_max_install_names: the relocation step below rewrites load commands.
# LDFLAGS_SL (shared libraries and modules ONLY) -dead_strip: libcrypto's
# thread_posix.o defines `ossl_crypto_thread_native_exit`, which nothing in
# OpenSSL calls, and the object is pulled in whole for its other symbols — so
# libpq.dylib imported `pthread_exit` for a function that can never run, and
# libpq's "must not call exit" check failed the build. Stripping unreachable code
# removes it; that check then proves it stayed gone. NOT in LDFLAGS: the server
# executable must keep every symbol, reachable or not, for the modules that load
# into it.
./configure --prefix="$PREFIX" "${PG_FLAGS[@]}" \
  CFLAGS="-O2 ${TARGET_FLAGS}" \
  CPPFLAGS="-I${OSSL}/include" \
  LDFLAGS="${TARGET_FLAGS} -L${OSSL}/lib -Wl,-headerpad_max_install_names" \
  LDFLAGS_SL="-Wl,-dead_strip" \
  > "$WORK/pg-configure.log" 2>&1 \
  || { tail -60 "$WORK/pg-configure.log"; fail "postgresql configure failed"; }

say "build"
# world-bin = the server, the clients and every contrib module, without the docs
# (which need an XML toolchain and are not something rexenv reads).
time make -j"$CPUS" world-bin > "$WORK/pg-build.log" 2>&1 \
  || { tail -80 "$WORK/pg-build.log"; fail "postgresql build failed"; }
make install-world-bin > "$WORK/pg-install.log" 2>&1 \
  || { tail -40 "$WORK/pg-install.log"; fail "postgresql install failed"; }
cp COPYRIGHT "$PREFIX/COPYRIGHT"

# ─── Relocate ────────────────────────────────────────────────────────────────
# `make install` writes the BUILD prefix into every load command that names
# libpq/libecpg/libpgtypes. Rewritten to upstream's shape, `@loader_path/../lib/`,
# which resolves from bin/ and from lib/ alike. install_name_tool invalidates the
# linker's ad-hoc signature, and an arm64 Mach-O without a valid one is killed at
# exec — so every rewritten file is re-signed (rexenv ad-hoc signs again, last,
# on the user's machine: `prepare_binary`).
say "relocate"
machos() { find "$1/bin" "$1/lib" -type f \( -perm -u+x -o -name '*.dylib' \) -print0 \
  | while IFS= read -r -d '' f; do
      if file -b "$f" | grep -q 'Mach-O'; then printf '%s\n' "$f"; fi
    done; }
machos "$PREFIX" > "$WORK/machos.txt"
[ -s "$WORK/machos.txt" ] || fail "no Mach-O files found under $PREFIX"
while IFS= read -r f; do
  CHANGED=0
  case "$f" in
    *.dylib)
      ID="$(otool -D "$f" | tail -n +2)"
      case "$ID" in
        "$PREFIX"/lib/*) install_name_tool -id "@loader_path/../lib/${ID##*/}" "$f"; CHANGED=1 ;;
      esac ;;
  esac
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    install_name_tool -change "$dep" "@loader_path/../lib/${dep##*/}" "$f"
    CHANGED=1
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -F "$PREFIX/lib/" || true)
  if [ "$CHANGED" = 1 ]; then codesign --force --sign - "$f" 2>/dev/null; fi
done < "$WORK/machos.txt"
echo "  $(wc -l < "$WORK/machos.txt" | tr -d ' ') Mach-O files"

# ─── Gates. Every one of these has a specific way of being wrong. ────────────
say "gates: static"

# 1. THE reason this build exists, asserted on EVERY Mach-O in the tree, not on
#    bin/postgres alone: a loadable module at a higher floor fails at
#    CREATE EXTENSION on a user's machine, long after the server started fine.
# 2. Right arch (the toolchain's spelling — `file` says arm64, our names aarch64).
# 3. The closure: the system, or this tree. Nothing from the build host.
BAD=""
while IFS= read -r f; do
  rel="${f#"$PREFIX"/}"
  MINOS="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  [ "$MINOS" = "$MACOSX_DEPLOYMENT_TARGET" ] || BAD+=$'\n'"  $rel: minos=${MINOS:-none} want $MACOSX_DEPLOYMENT_TARGET"
  ARCHS="$(lipo -archs "$f")"
  [ "$ARCHS" = "$MAC_ARCH" ] || BAD+=$'\n'"  $rel: archs=$ARCHS want $MAC_ARCH"
  while IFS= read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*|@loader_path/../lib/*) ;;
      *) BAD+=$'\n'"  $rel: links $dep" ;;
    esac
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
  # A dylib's own id is the first line of -L for a dylib; covered by the loop.
done < "$WORK/machos.txt"
[ -z "$BAD" ] || fail "floor / arch / closure:$BAD"
echo "  every Mach-O: minos $MACOSX_DEPLOYMENT_TARGET, $MAC_ARCH, closure = system + tree"

# 4. No OpenSSL dylib rode along, and the server really carries OpenSSL (static
#    leaves no load command to read, so ask for the version string it embeds).
if find "$PREFIX" -name 'libssl*' -o -name 'libcrypto*' | grep -q .; then fail "an OpenSSL library is in the tree"; fi
strings -a "$PREFIX/lib/libpq.5.dylib" > "$WORK/libpq.strings"
grep -qF "OpenSSL ${OPENSSL_VERSION}" "$WORK/libpq.strings" || fail "libpq does not carry OpenSSL ${OPENSSL_VERSION}"

# 5. A symbol newer than the floor, bound hard, is a launch-time crash on 13 that
#    no run on the build host can show. `strchrnul` is the known one: it arrived
#    in the macOS 15.4 SDK and PostgreSQL's configure once took it for granted.
nm -u "$PREFIX/bin/postgres" > "$WORK/postgres.undef"
if grep -qx '_strchrnul' "$WORK/postgres.undef"; then fail "bin/postgres imports strchrnul (macOS 15.4+) at a 13.0 floor"; fi

# 6. It is the version we think it is.
"$PREFIX/bin/postgres" --version > "$WORK/version.txt"
cat "$WORK/version.txt"
grep -qF "(PostgreSQL) ${PG_SRC_VERSION}" "$WORK/version.txt" || fail "wrong PostgreSQL version"

# ─── Licences ────────────────────────────────────────────────────────────────
# Publishing these bytes makes rexenv the DISTRIBUTOR. rexenv refuses to resolve a
# self-hosted artifact with no licence archive beside it, so this is not
# paperwork. Each file named explicitly: a glob that matches nothing is how a
# licence archive ends up empty and passes.
say "licences"
LIC="$WORK/lic/licenses"
mkdir -p "$LIC"
cp COPYRIGHT "$LIC/postgresql.COPYRIGHT"                                  # PostgreSQL Licence
cp "$WORK/openssl-${OPENSSL_VERSION}/LICENSE.txt" "$LIC/openssl.LICENSE.txt"  # Apache-2.0 (static)
for f in "$LIC"/*; do [ -s "$f" ] || fail "empty licence file: $f"; done
LIC_NAME="licenses-postgresql-${VERSION}-macos-${ARCH}.tar.gz"
( cd "$WORK/lic" && tar -czf "$OUT/$LIC_NAME" licenses )

# ─── Package, then gate THE ARTIFACT ─────────────────────────────────────────
say "package"
( cd "$WORK/stage" && tar -czf "$OUT/$NAME.tar.gz" "$NAME" )

# Unpacked somewhere that is NOT the build prefix, at a path WITH A SPACE —
# rexenv's app-data is "Application Support". A compiled-in path that only works
# from the build tree fails here rather than on a user's machine. /tmp, and short:
# a unix socket path is capped at 104 bytes.
say "gates: run the packaged tree"
GATE_ROOT="$(mktemp -d /tmp/pgg.XXXXXX)"
mkdir -p "$GATE_ROOT/rexenv bin"
tar -xzf "$OUT/$NAME.tar.gz" -C "$GATE_ROOT/rexenv bin"
T="$GATE_ROOT/rexenv bin/$NAME"
rm -rf "$WORK/stage"   # the build prefix is GONE before anything runs
DATA="$GATE_ROOT/data"
SOCK="$GATE_ROOT"
if nc -z 127.0.0.1 "$GATE_PORT" 2>/dev/null; then fail "port $GATE_PORT is busy — set GATE_PORT"; fi

"$T/bin/initdb" -D "$DATA" -U postgres --auth=trust -E UTF8 --locale=C > "$WORK/initdb.log" 2>&1 \
  || { cat "$WORK/initdb.log"; fail "initdb failed"; }
PGPID_DIR="$DATA"
pg_start() {
  "$T/bin/pg_ctl" -D "$DATA" -l "$GATE_ROOT/server.log" -w -t 60 \
    -o "-p $GATE_PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories='$SOCK' $*" start > "$WORK/pg_ctl.log" 2>&1 \
    || { cat "$WORK/pg_ctl.log"; tail -30 "$GATE_ROOT/server.log"; fail "server did not start"; }
}
pg_stop() { "$T/bin/pg_ctl" -D "$DATA" -m fast -w stop > /dev/null; }
q() { "$T/bin/psql" -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$GATE_PORT" -U postgres -d "${DB:-postgres}" -At -c "$1"; }
pg_start

# 7. A server answers, and says the version.
V="$(q 'select version()')"
echo "  $V"
case "$V" in "PostgreSQL ${PG_SRC_VERSION} "*) ;; *) fail "server reports: $V" ;; esac

# 8. EVERY extension the tree ships loads. A control file whose module fails to
#    dlopen (a missing symbol, a wrong floor, a build-host path) is exactly what
#    a version check cannot see.
EXT_COUNT=0
for c in "$T"/share/extension/*.control; do
  e="$(basename "$c" .control)"
  q "create extension if not exists \"$e\" cascade" > /dev/null 2> "$WORK/ext.err" \
    || { cat "$WORK/ext.err"; fail "create extension $e failed"; }
  EXT_COUNT=$((EXT_COUNT + 1))
done
[ "$EXT_COUNT" -ge 40 ] || fail "only $EXT_COUNT extensions shipped — contrib did not build"
echo "  $EXT_COUNT extensions created"

# 9. The optional libraries DO something: libxml (xml type), libxslt (xml2),
#    OpenSSL (pgcrypto), e2fs uuid (uuid-ossp).
[ "$(q "select xpath('/a/b/text()', '<a><b>ok</b></a>'::xml)::text")" = "{ok}" ] || fail "libxml: xpath"
[ "$(q "select encode(digest('abc','sha256'),'hex')")" = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" ] || fail "pgcrypto: sha256"
[ "$(q "select length(uuid_generate_v4()::text)")" = "36" ] || fail "uuid-ossp"
XSLT="$(q "select xslt_process('<a>ok</a>', '<xsl:stylesheet version=\"1.0\" xmlns:xsl=\"http://www.w3.org/1999/XSL/Transform\"><xsl:output method=\"text\"/><xsl:template match=\"/\"><xsl:value-of select=\"a\"/></xsl:template></xsl:stylesheet>')")"
[ "$XSLT" = "ok" ] || fail "libxslt: xslt_process returned '$XSLT'"

# 10. Dump and restore round-trips through the tree's own clients.
q "create table t (id int primary key, v text); insert into t select g, md5(g::text) from generate_series(1,1000) g" > /dev/null
q "create database copy" > /dev/null
"$T/bin/pg_dump" -h 127.0.0.1 -p "$GATE_PORT" -U postgres -t t postgres > "$WORK/dump.sql"
"$T/bin/psql" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$GATE_PORT" -U postgres -d copy -f "$WORK/dump.sql" > /dev/null
[ "$(DB=copy q 'select count(*), md5(string_agg(v, chr(44) order by id)) from t')" = "$(q 'select count(*), md5(string_agg(v, chr(44) order by id)) from t')" ] \
  || fail "pg_dump → psql did not round-trip"

# 11. TLS, end to end: the server presents a certificate and libpq negotiates it
#     — both halves through the OpenSSL linked in above. (The certificate is made
#     by the OS's own openssl; only the handshake is under test.)
pg_stop
/usr/bin/openssl req -new -x509 -days 2 -nodes -subj "/CN=localhost" \
  -keyout "$DATA/server.key" -out "$DATA/server.crt" > /dev/null 2>&1
chmod 600 "$DATA/server.key"
pg_start "-c ssl=on"
TLS="$("$T/bin/psql" -X -At "host=127.0.0.1 port=$GATE_PORT user=postgres dbname=postgres sslmode=require" \
  -c "select ssl, version from pg_stat_ssl where pid = pg_backend_pid()")"
case "$TLS" in t\|TLSv1.3|t\|TLSv1.2) echo "  TLS: $TLS" ;; *) fail "TLS session not negotiated: '$TLS'" ;; esac
pg_stop
PGPID_DIR=""

# ─── Parity with upstream's tree ─────────────────────────────────────────────
# The same version, their artifact, compared NAME FOR NAME: programs, loadable
# modules, extensions, configure flags. A 404 is a WARNING that says so — never a
# silent pass — because upstream can lag a postgresql.org release by hours.
say "gates: parity with theseus-rs ${VERSION}"
case "$ARCH" in aarch64) UP_ARCH="aarch64" ;; x86_64) UP_ARCH="x86_64" ;; esac
UP_URL="https://github.com/theseus-rs/postgresql-binaries/releases/download/${VERSION}/postgresql-${VERSION}-${UP_ARCH}-apple-darwin.tar.gz"
if curl -fsSL -o "$WORK/upstream.tar.gz" "$UP_URL"; then
  mkdir -p "$WORK/up"
  tar -xzf "$WORK/upstream.tar.gz" -C "$WORK/up" --strip-components 1
  names() { ( cd "$1" && ls ) | sort; }
  diff <(names "$WORK/up/bin") <(names "$T/bin") > "$WORK/parity-bin.diff" \
    || { cat "$WORK/parity-bin.diff"; fail "bin/ differs from upstream (< theirs, > ours)"; }
  # Modules: theirs minus the two OpenSSL dylibs this build links static.
  mods() { ( cd "$1" && ls ) | grep '\.dylib$' | grep -vE '^lib(ssl|crypto)\.' | sort; }
  diff <(mods "$WORK/up/lib") <(mods "$T/lib") > "$WORK/parity-lib.diff" \
    || { cat "$WORK/parity-lib.diff"; fail "lib/*.dylib differs from upstream (< theirs, > ours)"; }
  ctl() { ( cd "$1/share/extension" && ls ) | grep '\.control$' | sort; }
  diff <(ctl "$WORK/up") <(ctl "$T") > "$WORK/parity-ext.diff" \
    || { cat "$WORK/parity-ext.diff"; fail "extensions differ from upstream (< theirs, > ours)"; }
  # Flags: every `--…` token except the prefix. Read from THEIR binary, so a flag
  # they add is a failure here rather than a feature quietly absent.
  flags() { tr ' ' '\n' <<<"$1" | tr -d "'" | grep '^--' | grep -v '^--prefix' | sort; }
  UP_PGCONFIG="$WORK/up/bin/pg_config"
  if UP_FLAGS="$("$UP_PGCONFIG" --configure 2>/dev/null)"; then
    diff <(flags "$UP_FLAGS") <(flags "$("$T/bin/pg_config" --configure)") > "$WORK/parity-flags.diff" \
      || { cat "$WORK/parity-flags.diff"; fail "configure flags differ from upstream (< theirs, > ours)"; }
    echo "  programs, modules, extensions and configure flags match upstream"
  else
    echo "::warning::upstream's pg_config did not run on this host (its floor is above it?) — flags NOT compared"
    echo "  programs, modules and extensions match upstream; flags NOT compared"
  fi
else
  echo "::warning::upstream publishes no ${VERSION} for ${UP_ARCH} ($UP_URL) — parity NOT compared"
fi

# ─── Checksums ───────────────────────────────────────────────────────────────
say "record"
( cd "$OUT" && for f in "$NAME.tar.gz" "$LIC_NAME"; do shasum -a 256 "$f" > "$f.sha256"; done )
ls -lh "$OUT"
echo "postgresql ${PG_SRC_VERSION} / openssl ${OPENSSL_VERSION} (static) / macos / ${ARCH} / minos ${MACOSX_DEPLOYMENT_TARGET} / ${EXT_COUNT} extensions"
"$T/bin/pg_config" --configure
