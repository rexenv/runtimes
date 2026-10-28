#!/bin/bash
# Build one of rexenv's Linux runtimes and gate it — the SAME command on the
# laptop and in CI, so a local green means the CI lane runs the same steps.
#
#   scripts/linux-build.sh <redis|mariadb|httpd> <aarch64|x86_64> <out-dir> [version]
#
# Two containers, never one:
#
#   1. BUILD  in ubuntu:22.04 (root, network, compilers): scripts/build-<name>.sh.
#      22.04 because the glibc a binary links against is the floor it demands,
#      and 22.04 (glibc 2.35) is rexenv's Linux floor (D-L4).
#   2. GATE   in a CLEAN ubuntu:22.04 AND ubuntu:24.04 (unprivileged, --network
#      none, nothing installed): scripts/gate-<name>.sh starts the real server and
#      talks to it. The build container has every -dev package the build needed;
#      a library the artifact forgot to bundle resolves there and is "not found"
#      on a user's machine, so the build container never judges its own work.
#
# The images are pinned by index digest (multi-arch, so one digest serves both
# arches): a moving `ubuntu:22.04` tag would let the toolchain change between two
# builds of the same build number. Bump them deliberately.
#
# Locally (Apple Silicon): aarch64 runs native in Docker. x86_64 would run under
# emulation — that half is CI's (ubuntu-24.04), as CLAUDE.md says of every build.
set -euo pipefail

NAME="${1:?name required: redis|mariadb|httpd}"
ARCH="${2:?arch required: aarch64|x86_64}"
OUT="${3:?output dir required}"
VERSION="${4:-}"

BUILD_IMAGE="ubuntu:22.04@sha256:e0f80c829509ef4df9e76bd8944eb7b8ec25cbb379b112a7f9448b2c77a77c9b"
GATE_IMAGES=(
  "ubuntu:22.04@sha256:e0f80c829509ef4df9e76bd8944eb7b8ec25cbb379b112a7f9448b2c77a77c9b"
  "ubuntu:24.04@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c"
)

# php-fpm for the httpd gate: a REAL FastCGI responder behind mod_proxy_fcgi, not
# a stub. Our own static build (release php-8x-linux-1, digests as in
# manifest-linux.json) — fully static, so it adds no library to the clean
# container that could mask one httpd forgot.
PHP_FPM_VERSION="8.4.27"
PHP_FPM_TAG="php-8x-linux-1"
PHP_FPM_SHA256_aarch64="a9945966d5b91499e3ac6187477eae6873d8ed6ba3599f3c8fa46c2577c95a0b"
PHP_FPM_SHA256_x86_64="286be22da1aa1b8f44a5034f8860af48ee3926b4a3957b141527b5ba7c0b4f5a"

case "$NAME" in redis|mariadb|httpd) ;; *) echo "::error::unknown runtime $NAME"; exit 1 ;; esac
case "$ARCH" in
  aarch64) PLATFORM=linux/arm64 ;;
  x86_64)  PLATFORM=linux/amd64 ;;
  *) echo "::error::unknown arch $ARCH"; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
CACHE="${SRC_CACHE:-$HERE/.cache/src}"
mkdir -p "$CACHE"
say() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }

say "build $NAME${VERSION:+ $VERSION} for linux/$ARCH in $BUILD_IMAGE"
docker run --rm --platform "$PLATFORM" \
  -v "$HERE:/src:ro" -v "$OUT:/out" -v "$CACHE:/cache" \
  -e VERSION="$VERSION" -e JOBS_OVERRIDE="${JOBS_OVERRIDE:-}" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$BUILD_IMAGE" bash /src/scripts/build-"$NAME".sh "$ARCH" /out

# The build script writes the artifact's name here, so this driver never guesses
# a filename the build did not produce.
ARTIFACT="$(cat "$OUT/.artifact")"
[ -f "$OUT/$ARTIFACT" ] || { echo "::error::$ARTIFACT was not produced"; exit 1; }

GATE_ARGS=()
ASSETS="$(mktemp -d)"
trap 'rm -rf "$ASSETS"' EXIT
if [ "$NAME" = httpd ]; then
  want_var="PHP_FPM_SHA256_$ARCH"; want="${!want_var}"
  fpm="$CACHE/php-$PHP_FPM_VERSION-fpm-linux-$ARCH.tar.gz"
  if [ ! -f "$fpm" ] || [ "$(shasum -a 256 "$fpm" | cut -d' ' -f1)" != "$want" ]; then
    curl -fsSL --retry 5 "https://github.com/rexenv/runtimes/releases/download/$PHP_FPM_TAG/php-$PHP_FPM_VERSION-fpm-linux-$ARCH.tar.gz" -o "$fpm"
  fi
  got="$(shasum -a 256 "$fpm" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || { echo "::error::php-fpm sha256 $got, pinned $want"; exit 1; }
  cp "$fpm" "$ASSETS/php-fpm.tar.gz"
  GATE_ARGS=(/assets/php-fpm.tar.gz)
fi
chmod -R a+rX "$ASSETS"

for img in "${GATE_IMAGES[@]}"; do
  say "gate $ARTIFACT in a clean ${img%@*} (no network, uid 1000, nothing installed)"
  docker run --rm --platform "$PLATFORM" --network none --user 1000:1000 -e HOME=/tmp \
    -v "$HERE/scripts:/scripts:ro" -v "$OUT:/out:ro" -v "$ASSETS:/assets:ro" \
    "$img" bash /scripts/gate-"$NAME".sh "/out/$ARTIFACT" ${GATE_ARGS[@]+"${GATE_ARGS[@]}"}
done

rm -f "$OUT/.artifact"
say "$ARTIFACT: built on 22.04, gated on ${#GATE_IMAGES[@]} clean images"
ls -l "$OUT"
