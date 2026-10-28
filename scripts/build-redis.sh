#!/bin/bash
# Build Redis for Linux (x86_64, aarch64) — inside the ubuntu:22.04 build
# container that scripts/linux-build.sh starts. Not meant to run anywhere else.
#
#   scripts/build-redis.sh <aarch64|x86_64> <out-dir>
#
# ─── Why this exists ─────────────────────────────────────────────────────────
#
# rexenv's macOS Redis is a Homebrew bottle bundle (redis + openssl@3). Homebrew's
# Linux bottles are x86_64-only, so rexenv's Linux catalog had no Redis at all and
# `ships_on(.., "linux")` refused it (D-L8, docs/PLAN-linux-port.md). A caching
# plugin needs one (rexenv/rexenv#7, ask 5). Nobody publishes a portable Linux
# Redis for both arches, so it is built here from the redis.io release tarball.
#
# ─── Decisions ───────────────────────────────────────────────────────────────
#
# * glibc-dynamic, not static musl. Redis vendors everything it links (jemalloc,
#   lua, hiredis, linenoise, hdr_histogram, fpconv, tre, xxhash) and links them
#   static by default, so the only shared libraries left are glibc's own. Built
#   on 22.04, that is a glibc-2.35 floor, which is rexenv's Linux floor. musl would
#   buy nothing here and cost jemalloc's well-trodden glibc path.
#
# * NO TLS (BUILD_TLS=no). rexenv runs Redis bound to 127.0.0.1 (port 16379,
#   core/redis.rs) and never passes a --tls-* option; a loopback socket has no
#   network to encrypt against. TLS would mean shipping (and re-releasing for every
#   CVE in) an OpenSSL that no rexenv code path ever reaches — the macOS bundle
#   carries openssl only because Homebrew's formula builds with it. Consequence,
#   stated rather than discovered: `redis-server --tls-port …` on Linux fails
#   where the macOS bundle would accept it. Revisit only if rexenv ever exposes
#   Redis beyond loopback.
#
# * No Redis 8 modules (RedisJSON, Search, Bloom, TimeSeries): BUILD_WITH_MODULES
#   stays off, exactly like the macOS bottle (`redis-server --version`: no modules;
#   they need a Rust toolchain and are not what a WordPress object cache uses).
#
# * jemalloc, Redis's Linux default (the macOS bottle is malloc=libc because
#   jemalloc's Darwin path is not Redis's default there). Asserted below.
set -euo pipefail

ARCH="${1:?arch required: aarch64|x86_64}"
OUT="${2:?output dir required}"
HERE=/src
# shellcheck source=linux-common.sh
. "$HERE/scripts/linux-common.sh"

REDIS_VERSION="${VERSION:-8.8.4}"
# download.redis.io's own digests: github.com/redis/redis-hashes README.
case "$REDIS_VERSION" in
  8.8.4) REDIS_SHA256=ac03312b88534905e35c1791266ae48c0664cea10aa4111a6d05627aad0dc9d2 ;;
  *) fail "no pinned sha256 for redis $REDIS_VERSION — add it from github.com/redis/redis-hashes" ;;
esac

assert_build_host "$ARCH"
say "toolchain"
apt_install build-essential pkg-config ca-certificates curl file binutils

WORK="$(mktemp -d)"
cd "$WORK"
say "fetch (verified against the published digest)"
SRC="redis-$REDIS_VERSION.tar.gz"
fetch_verified "https://download.redis.io/releases/$SRC" "$SRC" "$REDIS_SHA256"
tar xzf "/cache/$SRC"
cd "redis-$REDIS_VERSION"

say "build"
MAKEFLAGS_REDIS=(BUILD_TLS=no USE_SYSTEMD=no MALLOC=jemalloc BUILD_WITH_MODULES=no)
make -j"$JOBS" "${MAKEFLAGS_REDIS[@]}" > "$WORK/make.log" 2>&1 \
  || { tail -60 "$WORK/make.log"; fail "redis did not build"; }
grep -qx 'BUILD_TLS=no' src/.make-settings || fail "the build did not record BUILD_TLS=no"

PKG="$WORK/pkg"
mkdir -p "$PKG/bin"
# Only the two binaries rexenv runs (core/redis.rs). redis-check-*/sentinel are
# the same executable under other names; symlinks are not something an archive
# rexenv unpacks should have to carry, and nothing calls them.
for b in redis-server redis-cli; do
  cp "src/$b" "$PKG/bin/$b"
  # Debug info off, symbols kept: a crash report's backtrace stays readable.
  strip --strip-debug "$PKG/bin/$b"
done

say "static gates (the clean-container gates run after, from linux-build.sh)"
elf_gate '' "$PKG/bin/redis-server" "$PKG/bin/redis-cli"
V="$("$PKG/bin/redis-server" --version)"
echo "$V"
has "v=$REDIS_VERSION " "$V" || fail "wrong version: $V"
has "malloc=jemalloc" "$V" || fail "not jemalloc: $V"
has "^redis-cli $REDIS_VERSION" "$("$PKG/bin/redis-cli" --version)" || fail "redis-cli version"
# No TLS, by decision (above): .make-settings said BUILD_TLS=no, elf_gate refused
# any libssl in NEEDED, and no libssl-dev is installed for a static one to come from.

say "licences"
# Redis 8 is tri-licensed RSALv2 / SSPLv1 / AGPLv3 (LICENSE.txt); rexenv
# redistributes it under AGPLv3, which is why the source tarball and the scripts
# that built it ride the same release (below). REDISCONTRIBUTIONS.txt carries the
# BSD-3 terms of the code that predates 8.0. Then every vendored dependency.
LIC="$WORK/lic/licenses"
mkdir -p "$LIC"
cp LICENSE.txt                    "$LIC/redis.LICENSE.txt"
cp REDISCONTRIBUTIONS.txt         "$LIC/redis.REDISCONTRIBUTIONS.txt"
cp deps/jemalloc/COPYING          "$LIC/jemalloc.COPYING"            # BSD-2
cp deps/hiredis/COPYING           "$LIC/hiredis.COPYING"             # BSD-3
cp deps/lua/COPYRIGHT             "$LIC/lua.COPYRIGHT"               # MIT
cp deps/hdr_histogram/LICENSE.txt "$LIC/hdr_histogram.LICENSE.txt"  # BSD-2 / CC0
cp deps/hdr_histogram/COPYING.txt "$LIC/hdr_histogram.COPYING.txt"
cp deps/fpconv/LICENSE.txt        "$LIC/fpconv.LICENSE.txt"          # BSL-1.0
cp deps/tre/LICENSE               "$LIC/tre.LICENSE"                 # BSD-2
cp deps/xxhash/LICENSE            "$LIC/xxhash.LICENSE"              # BSD-2
# linenoise has no licence FILE; its BSD-2 text is the header comment of the source.
awk 'NR==1,/\*\//' deps/linenoise/linenoise.c > "$LIC/linenoise.LICENSE"
has 'Redistribution and use in source and binary forms' "$(cat "$LIC/linenoise.LICENSE")" \
  || fail "linenoise.c's header no longer carries its licence text"
pack_licences "$OUT/licenses-redis-$REDIS_VERSION-linux-$ARCH.tar.gz" "$WORK/lic"

say "package"
NAME="redis-$REDIS_VERSION-linux-$ARCH.tar.gz"
pack "$OUT/$NAME" "$PKG" bin
cp "/cache/$SRC" "$OUT/$SRC"
pack_build_scripts "$OUT/redis-$REDIS_VERSION-rexenv-build.tar.gz" redis
checksum_out "$OUT" "$NAME" "licenses-redis-$REDIS_VERSION-linux-$ARCH.tar.gz"
echo "$NAME" > "$OUT/.artifact"
chown -R "${HOST_UID:-0}:${HOST_GID:-0}" "$OUT"
ls -l "$OUT"
say "record"
echo "redis $REDIS_VERSION / linux / $ARCH / glibc $(ldd --version | head -1 | awk '{print $NF}') / gcc $(gcc -dumpfullversion) / BUILD_TLS=no"
