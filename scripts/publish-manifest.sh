#!/bin/bash
# Discover new PHP patches, sign them, and publish the update manifest.
#
#   ./scripts/publish-manifest.sh                 discover everything and publish
#   ./scripts/publish-manifest.sh --dry-run       discover and sign, publish nothing
#   ./scripts/publish-manifest.sh 8.3.32 8.4.24   only these, no discovery
#
# This is the whole "support the new PHP versions" job. There is nothing to build:
# rexenv installs static-php.dev's portable builds for 8.x, so what a new version
# needs is a DIGEST somebody vouched for. That is what this produces.
#
# ── What rexenv does with it ───────────────────────────────────────────────────
#
# rexenv compiles a pin for every version it ships and, separately, an ed25519
# PUBLIC key. It fetches this manifest, verifies the signature against that key,
# and will then resolve a patch it was never built with — subject to four limits
# it enforces itself and this script must respect:
#
#   1. `name` may only be `php` or `php-fpm`. Nothing else. rexenv's resolver is
#      name-generic and `caddy` runs as a ROOT LaunchDaemon on a user's machine.
#   2. URLs must be https and from a host rexenv allows
#      (`dl.static-php.dev/`, `github.com/rexenv/`).
#   3. `version` must be a patch of a minor rexenv ALREADY ships. A new MINOR
#      cannot arrive this way — per-minor facts (EOL date, Xdebug availability,
#      the pool port) are compiled into the app.
#   4. Digests are lowercase 64-hex.
#
# It also refuses a `serial` that is not higher than the highest it has accepted,
# so a replayed old manifest cannot hold anyone on a stale patch. This script reads
# the published serial and increments; never hand-edit it downwards.
#
# ── The key ────────────────────────────────────────────────────────────────────
#
# `~/.rexenv/manifest-key.pem`, 0600, on the maintainer's machine. NOT a CI secret
# and not in this repo: releases are published locally anyway, so the key has no
# reason to leave, and keeping it off CI means a GitHub account compromise does not
# get an attacker the ability to make every rexenv install run arbitrary bytes.
#
# Mint or rotate it with rexenv's own `scripts/gen-release-key.sh`. Rotation means
# pinning the new public half in the app and shipping a release — which is exactly
# what makes a stolen key survivable.
#
# See docs/MANIFEST.md for the full walkthrough, including what to do when
# static-php.dev has not built a version yet.
set -euo pipefail
cd "$(dirname "$0")/.."

KEY="${REXENV_MANIFEST_KEY_FILE:-$HOME/.rexenv/manifest-key.pem}"
REPO="${REXENV_MANIFEST_REPO:-rexenv/runtimes}"
TAG="manifest"
MIN_APP="${REXENV_MANIFEST_MIN_APP:-0.3.0}"
BASE="https://dl.static-php.dev/static-php-cli/bulk"

# ── The minors rexenv ships, and the patch each one PINS ──────────────────────
#
# This list must match `PHP_VERSIONS` in rexenv's `core/binaries.rs`. It is
# duplicated because this repo cannot read that one, and a duplicated fact is a
# fact that drifts — so `--check-pins` below prints them for comparison, and the
# discovery probe starts AT the pin, which makes a stale entry harmless rather
# than silent: the worst a wrong floor does is offer a patch the app already has,
# which the app then filters out because it is not newer than its own pin.
PINS=(
  "7.4:7.4.33"   # ours, built here — never on static-php.dev
  "8.0:8.0.30"
  "8.1:8.1.34"
  "8.2:8.2.31"
  "8.3:8.3.31"
  "8.4:8.4.23"
  "8.5:8.5.8"
)

DRY=0
EXPLICIT=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --check-pins)
      printf '%s\n' "${PINS[@]}"
      echo
      echo "Compare with PHP_VERSIONS in rexenv's src-tauri/src/core/binaries.rs."
      exit 0 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) EXPLICIT+=("$a") ;;
  esac
done

[ -f "$KEY" ] || { echo "no signing key at $KEY — see docs/MANIFEST.md" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl required" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh required" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; chmod 700 "$WORK"

# ── Serial: read what is published, increment ─────────────────────────────────
CUR=0
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 \
  && gh release download "$TAG" --repo "$REPO" --pattern manifest.json --dir "$WORK" 2>/dev/null; then
  CUR="$(sed -n 's/.*"serial"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$WORK/manifest.json" | head -1)"
  CUR="${CUR:-0}"
fi
SERIAL=$((CUR + 1))

exists() { curl -sIL -o /dev/null -w '%{http_code}' --max-time 20 "$1" | grep -qE '^(200|302)$'; }

# ── Discovery ─────────────────────────────────────────────────────────────────
#
# Probe upward from each minor's PIN until two consecutive misses. Two, not one:
# upstream has skipped a patch number before, and stopping at the first 404 would
# hide everything after it. Only the CLI artifact is probed here — all four are
# fetched and hashed below, and a version missing any of them is dropped whole,
# because rexenv requires both arches of both kinds or it will not resolve.
VERSIONS=()
if [ ${#EXPLICIT[@]} -gt 0 ]; then
  VERSIONS=("${EXPLICIT[@]}")
  echo "explicit versions: ${VERSIONS[*]}"
else
  echo "discovering patches newer than each pin…"
  for entry in "${PINS[@]}"; do
    minor="${entry%%:*}"; pin="${entry##*:}"
    [ "$minor" = "7.4" ] && continue   # ours; static-php.dev has never published it
    start="${pin##*.}"
    misses=0; p=$((start + 1))
    while [ "$misses" -lt 2 ] && [ "$p" -lt $((start + 30)) ]; do
      v="${minor}.${p}"
      if exists "$BASE/php-${v}-cli-macos-aarch64.tar.gz"; then
        echo "  found $v"
        VERSIONS+=("$v"); misses=0
      else
        misses=$((misses + 1))
      fi
      p=$((p + 1))
    done
  done
fi

if [ ${#VERSIONS[@]} -eq 0 ]; then
  echo
  echo "Nothing newer than the pins is published upstream. Nothing to do."
  echo "That is the NORMAL state: static-php.dev rebuilds after each upstream"
  echo "release and trails php.net by days or weeks. Re-run later."
  exit 0
fi

# ── Hash every artifact, from the URL rexenv itself will use ──────────────────
# Not from a build directory: the digest has to describe the bytes a USER receives.
ENTRIES=""; KEPT=()
for V in "${VERSIONS[@]}"; do
  case "$V" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "not an x.y.z patch: $V" >&2; exit 1 ;; esac
  MINOR="${V%.*}"
  printf '%s\n' "${PINS[@]}" | grep -q "^${MINOR}:" || {
    echo "$V is not a patch of a minor rexenv ships — the app would drop it. Skipping." >&2
    continue
  }
  GROUP=""; ok=1
  for KIND in cli fpm; do
    for ARCH in arm64 x86_64; do
      case "$ARCH" in arm64) U=aarch64 ;; *) U=x86_64 ;; esac
      URL="$BASE/php-${V}-${KIND}-macos-${U}.tar.gz"
      OUT="$WORK/${V}-${KIND}-${ARCH}"
      printf '  %s %s %s … ' "$V" "$KIND" "$ARCH"
      if ! curl -fsSL --retry 3 -o "$OUT" "$URL"; then
        echo "MISSING"; ok=0; break 2
      fi
      SHA="$(shasum -a 256 "$OUT" | awk '{print $1}')"
      echo "$SHA"
      NAME=$([ "$KIND" = fpm ] && echo php-fpm || echo php)
      GROUP="${GROUP:+$GROUP,}$(printf '{"name":"%s","version":"%s","arch":"%s","url":"%s","sha256":"%s"}' \
        "$NAME" "$V" "$ARCH" "$URL" "$SHA")"
    done
  done
  if [ "$ok" -eq 1 ]; then
    ENTRIES="${ENTRIES:+$ENTRIES,}$GROUP"; KEPT+=("$V")
  else
    # All four or none. rexenv resolves cli AND fpm, on whichever arch the user
    # has; a half-published version would offer an update that fails on one Mac
    # and works on another.
    echo "  → $V is incomplete upstream; dropped entirely."
  fi
done

[ ${#KEPT[@]} -gt 0 ] || { echo "no complete version to publish"; exit 0; }

printf '{"serial":%d,"generatedAt":"%s","minAppVersion":"%s","artifacts":[%s]}' \
  "$SERIAL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MIN_APP" "$ENTRIES" > manifest.json

# ── Sign, then verify OUR OWN signature ───────────────────────────────────────
# A signature nobody checked is a release nobody can install, and the failure
# lands on a user as "the manifest signature does not verify".
openssl pkeyutl -sign -inkey "$KEY" -rawin -in manifest.json -out "$WORK/sig.bin"
xxd -p -c 256 < "$WORK/sig.bin" | tr -d '\n' > manifest.json.sig
openssl pkeyutl -verify -pubin -inkey <(openssl pkey -in "$KEY" -pubout) \
  -rawin -in manifest.json -sigfile "$WORK/sig.bin" >/dev/null \
  || { echo "our own signature does not verify — refusing to publish" >&2; exit 1; }

PUB="$(openssl pkey -in "$KEY" -pubout -outform DER | tail -c 32 | xxd -p -c 64)"
echo
echo "serial $CUR → $SERIAL   versions: ${KEPT[*]}   entries: $(( $(grep -o '"name"' manifest.json | wc -l) ))"
echo "signed with public key $PUB"
echo "  ↳ this MUST equal RELEASE_PUBKEY in rexenv's src-tauri/src/core/updates.rs,"
echo "    or every shipped build will ignore this manifest."

if [ "$DRY" -eq 1 ]; then
  echo
  echo "--dry-run: manifest.json and manifest.json.sig written, nothing published."
  exit 0
fi

# ── Publish. The tag is MOVED, which is safe HERE and nowhere else in rexenv ──
# Everywhere else a pin must never change bytes under a URL. These bytes are
# trusted for their SIGNATURE, not their location, so replacing them is fine —
# and the serial rule is what stops an OLD one being served in their place.
gh release delete "$TAG" --repo "$REPO" --yes >/dev/null 2>&1 || true
gh release create "$TAG" --repo "$REPO" \
  --title "PHP update manifest" \
  --notes "Signed manifest of PHP patch builds for rexenv's in-app updates. Serial $SERIAL. Verified in-app against the ed25519 public key compiled into the release; the tag moves on every publish because these bytes are trusted for their signature, not their URL." \
  manifest.json manifest.json.sig
echo
echo "Published. Verify what a user's app will see:"
echo "  curl -sL https://github.com/$REPO/releases/download/$TAG/manifest.json | head -c 200"
