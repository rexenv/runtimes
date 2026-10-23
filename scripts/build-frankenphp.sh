#!/usr/bin/env bash
# Build FrankenPHP for macOS x86_64 — the one target upstream stopped publishing.
#
# ─── Why this build exists ───────────────────────────────────────────────────
#
# FrankenPHP 1.13.2 (21 Oct 2026) is the security release that embeds PHP 8.5.12,
# the fix for CVE-2026-109618/109619 ("PHP2Shell", unauthenticated RCE). The same
# release moved its static builds to static-php-cli v3 and dropped the Intel Mac
# asset: "Binaries are only published for Apple Silicon. There is no
# `frankenphp-mac-x86_64` asset anymore. On Intel Macs, build from source with
# `build-static.sh`." rexenv pins one FrankenPHP version for both Mac arches, so
# without this build an Intel Mac either keeps 1.12.4 (PHP 8.5.8, vulnerable) or
# loses FrankenPHP. The owner chose this build (23 Oct 2026).
#
# **It is upstream's own build, run here — not a re-derivation.** The tag is
# checked out at a pinned commit and its `build-static.sh` + `craft.yml` run
# unmodified; the only thing this script supplies is a PINNED spc. The gates then
# hold the result to upstream's arm64 asset of the same release, the same rule
# build-php.sh keeps: their build, never a subset of it.
#
# Usage: scripts/build-frankenphp.sh <outdir>
set -euo pipefail

OUT="${1:?output dir required}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# ─── Pins ────────────────────────────────────────────────────────────────────
FRANKENPHP_VERSION="1.13.2"
FRANKENPHP_COMMIT="0ad8a403a5c2eb13aacab92fffa6abc397157d10"   # tag v1.13.2 (annotated tag 49a9d53a), php/frankenphp
EXPECT_PHP="8.5.12"

# static-php-cli v3. Upstream's script takes the NIGHTLY, which moves daily and has
# no versioned copies (dl.static-php.dev/v3/spc-bin/ holds `nightly/` only). A tool
# that builds a pinned artifact is itself pinned to bytes here, and the bytes are
# mirrored into the release beside the artifact so the build is reproducible from
# our URLs once the nightly has moved on. Hashed from a full download, 23 Oct 2026
# (nightly of 22 Oct 16:53 UTC — upstream's 1.13.2 build used an earlier one).
SPC_URL="https://dl.static-php.dev/v3/spc-bin/nightly/spc-macos-x86_64"
SPC_SHA256="e0c4daef9e7ff0edc9cc5adddff6ad8a4305a43d4f7bb16e6b1d25a3f5ae39ff"

# The floor every macOS binary rexenv ships declares, and what upstream's arm64
# 1.13.2 declares (`minos 12.0`, measured).
export MACOSX_DEPLOYMENT_TARGET="12.0"

say() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }

[ "$(uname -s)" = Darwin ] || { echo "::error::macOS only"; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "::error::this builds the x86_64 binary; run it on an Intel runner or under arch -x86_64"; exit 1; }

say "toolchain"
clang --version | head -1
go version 2>/dev/null || echo "go: none on PATH (spc fetches its own)"

# ─── Source ──────────────────────────────────────────────────────────────────
say "frankenphp v${FRANKENPHP_VERSION} (${FRANKENPHP_COMMIT:0:12})"
WORK="$(pwd)/fp-work"
rm -rf "$WORK"
git clone --quiet --depth 1 --branch "v${FRANKENPHP_VERSION}" https://github.com/php/frankenphp.git "$WORK"
HEAD="$(git -C "$WORK" rev-parse HEAD)"
[ "$HEAD" = "$FRANKENPHP_COMMIT" ] || { echo "::error::v${FRANKENPHP_VERSION} is $HEAD, pinned $FRANKENPHP_COMMIT — the tag moved"; exit 1; }

# ─── spc, pinned ─────────────────────────────────────────────────────────────
say "static-php-cli v3 (pinned nightly)"
mkdir -p "$WORK/dist"
curl -fsSL --retry 5 -o "$WORK/dist/spc" "$SPC_URL"
echo "$SPC_SHA256  $WORK/dist/spc" | shasum -a 256 -c - \
  || { echo "::error::spc nightly changed since it was pinned — re-pin it deliberately (hash, run, record)"; exit 1; }
chmod +x "$WORK/dist/spc"
cp "$WORK/dist/spc" "$OUT/spc-macos-x86_64"

# ─── Build: upstream's script, unmodified ────────────────────────────────────
# RELEASE stays unset: with it, build-static.sh uploads to upstream's release with
# --clobber — never something this repo does to anyone's release, its own included.
say "build-static.sh"
unset RELEASE EMBED PHP_VERSION PHP_EXTENSIONS PHP_EXTENSION_LIBS XCADDY_ARGS MIMALLOC DEBUG_SYMBOLS
( cd "$WORK" && FRANKENPHP_VERSION="$FRANKENPHP_VERSION" OUTPUT_DIR="$WORK/dist" bash ./build-static.sh )
BIN="$WORK/dist/frankenphp-mac-x86_64"
[ -x "$BIN" ] || { echo "::error::build-static.sh produced no $BIN"; exit 1; }

# ─── Gates ───────────────────────────────────────────────────────────────────
say "gates"
# 1. The version it claims, with the PHP that carries the fix.
VER="$("$BIN" version)"
echo "$VER"
grep -q "^FrankenPHP v${FRANKENPHP_VERSION} PHP ${EXPECT_PHP} " <<<"$VER" \
  || { echo "::error::expected FrankenPHP v${FRANKENPHP_VERSION} with PHP ${EXPECT_PHP}"; exit 1; }

# 2. Mach-O x86_64, the floor survived, and only system libraries — what rexenv's
#    macos_floor_check and its relink step accept.
FILE="$(file "$BIN")"
grep -q 'x86_64' <<<"$FILE" || { echo "::error::not x86_64: $FILE"; exit 1; }
MINOS="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
[ "$MINOS" = "$MACOSX_DEPLOYMENT_TARGET" ] || { echo "::error::minos=$MINOS want $MACOSX_DEPLOYMENT_TARGET"; exit 1; }
DYLIBS="$(otool -L "$BIN" | tail -n +2 | awk '{print $1}')"
NONSYS="$(grep -vE '^(/usr/lib/|/System/)' <<<"$DYLIBS" || true)"
[ -z "$NONSYS" ] || { echo "::error::links non-system dylibs: $NONSYS"; exit 1; }

# 3. It serves PHP: a real request through the embedded runtime, not --version.
PORT=58080
DOC="$(mktemp -d)"
echo '<?php echo "FP_OK:", PHP_VERSION, ":", (int)extension_loaded("pdo_pgsql");' > "$DOC/index.php"
"$BIN" php-server --root "$DOC" --listen "127.0.0.1:$PORT" >/tmp/fp-server.log 2>&1 &
FP_PID=$!
trap 'kill $FP_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -fsS "http://127.0.0.1:$PORT/" >/tmp/fp-out 2>/dev/null && break; sleep 1; done
grep -q "FP_OK:${EXPECT_PHP}:1" /tmp/fp-out 2>/dev/null \
  || { echo "::error::php-server did not answer as PHP ${EXPECT_PHP} with pdo_pgsql"; cat /tmp/fp-server.log; exit 1; }
kill $FP_PID 2>/dev/null || true
trap - EXIT
echo "php-server: served PHP ${EXPECT_PHP} with pdo_pgsql"

# 4. What parity with upstream's arm64 asset is measured against — written here,
#    compared in the workflow's verify job (an Intel runner cannot run arm64).
"$BIN" php-cli -n -r '$e = get_loaded_extensions(); sort($e); echo implode("\n", $e), "\n";' > "$OUT/extensions-x86_64.txt"
"$BIN" php-cli -n -r '$f = get_defined_functions()["internal"]; sort($f); echo implode("\n", $f), "\n";' > "$OUT/functions-x86_64.txt"
"$BIN" build-info > "$OUT/build-info-x86_64.txt"
echo "extensions: $(grep -c . "$OUT/extensions-x86_64.txt") · functions: $(grep -c . "$OUT/functions-x86_64.txt")"

# ─── Licences ────────────────────────────────────────────────────────────────
# We are the distributor of these bytes, and they carry three kinds of code: the C
# libraries spc built (their sources are on disk), PHP itself, and every Go module
# Caddy and FrankenPHP link (named, with versions, by the binary's own build-info).
say "licences"
LIC="$OUT/licenses"
mkdir -p "$LIC"
cp "$(cd "$(dirname "$0")/.." && pwd)/licenses/PHP-3.01.txt" "$LIC/"
SRC_ROOT="$WORK/dist/source"
[ -d "$SRC_ROOT" ] || SRC_ROOT="$(find "$WORK/dist" -maxdepth 2 -type d -name source | head -1)"
[ -n "$SRC_ROOT" ] && [ -d "$SRC_ROOT" ] || { echo "::error::cannot find spc's source directory under $WORK/dist"; exit 1; }
missing=""
for d in "$SRC_ROOT"/*/; do
  name="$(basename "$d")"
  for f in LICENSE LICENSE.txt LICENSE.TXT LICENSE.md LICENCE LICENCE.txt COPYING COPYING.txt \
           COPYRIGHT Copyright copyright LICENSE-MIT NOTICE doc/COPYING.LGPL doc/COPYING; do
    if [ -f "$d$f" ]; then cp "$d$f" "$LIC/${name}.$(basename "$f")"; continue 2; fi
  done
  if [ "$name" = sqlite ]; then
    printf '%s\n' "SQLite is in the public domain: https://sqlite.org/copyright.html" \
      "The amalgamation ships no licence file; this note stands in for one." > "$LIC/sqlite.PUBLIC-DOMAIN.txt"
    continue
  fi
  missing="$missing $name"
done
# Go modules: fetched by the exact versions build-info names, through the module
# proxy, which verifies them against sum.golang.org.
command -v go >/dev/null || { echo "::error::Go is needed to collect the Go modules' licences"; exit 1; }
GOLIC="$LIC/go"
mkdir -p "$GOLIC"
GOMODS="$(awk -F'\t' '$1=="dep" && $3 ~ /^v/ {print $2"@"$3}' "$OUT/build-info-x86_64.txt")"
while read -r m; do
  [ -n "$m" ] || continue
  dir="$(cd "$(mktemp -d)" && GOFLAGS=-mod=mod go mod download -json "$m" 2>/dev/null | sed -n 's/.*"Dir": "\(.*\)".*/\1/p')"
  safe="$(tr '/@' '__' <<<"$m")"
  for f in LICENSE LICENSE.txt LICENSE.md LICENCE COPYING NOTICE LICENSE-APACHE LICENSE-MIT UNLICENSE; do
    if [ -n "$dir" ] && [ -f "$dir/$f" ]; then cp "$dir/$f" "$GOLIC/${safe}.${f}"; continue 2; fi
  done
  missing="$missing $m"
done <<<"$GOMODS"
echo "collected $(find "$LIC" -type f | wc -l | tr -d ' ') licence files ($(grep -c . <<<"$GOMODS") Go modules)"
if [ -n "$missing" ]; then
  echo "::error::no licence file found for:$missing"
  echo "::error::we distribute these bytes — find the licence, or record WHY one ships without it."
  exit 1
fi

# ─── Package ─────────────────────────────────────────────────────────────────
say "package"
cp "$BIN" "$OUT/frankenphp-mac-x86_64"
tar -C "$OUT" -czf "$OUT/licenses-frankenphp-${FRANKENPHP_VERSION}-mac-x86_64.tar.gz" licenses && rm -rf "$LIC"
( cd "$OUT" && shasum -a 256 frankenphp-mac-x86_64 licenses-frankenphp-*.tar.gz spc-macos-x86_64 | tee SHA256SUMS )
ls -lh "$OUT"
