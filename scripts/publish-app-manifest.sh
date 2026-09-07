#!/bin/bash
# Sign and publish the descriptor that tells installed rexenv copies a newer
# rexenv exists.
#
#   ./scripts/publish-app-manifest.sh              publish the tap's latest release
#   ./scripts/publish-app-manifest.sh --dry-run    build and sign, publish nothing
#   ./scripts/publish-app-manifest.sh 0.6.1        publish that version specifically
#
# ── What this is, next to publish-manifest.sh ─────────────────────────────────
#
# `publish-manifest.sh` describes PHP and Adminer artifacts, which rexenv resolves
# through its binary cache. This one describes rexenv ITSELF — the bundle the app
# replaces itself with. Two documents, two serials, one key.
#
# They are separate on purpose. The PHP manifest's `Family` enum locks it to
# artifacts that flow through rexenv's `binaries::resolve*`, and an app bundle is
# not one of those: it is chmod-ed by nothing, spawned by nobody, and swapped into
# /Applications by a platform trait. The grant is also larger — whoever can name
# a PHP tarball can run native code as the user; whoever can name an app bundle
# gets that PLUS the binary that re-execs as the DNS agent and the tunnel guard,
# PLUS the process that enforces rexenv's own agent-access dial. Keeping the two
# documents apart keeps that difference visible instead of buried in a field.
#
# ── Where the facts come from, and why none of them are typed here ────────────
#
# Everything is read from the PUBLISHED release on the tap:
#
#   • the version — from the latest non-draft, non-prerelease tag;
#   • the URL — the release's own asset URL, name-based and stable;
#   • the digest — GitHub's immutable per-asset `digest`, then re-verified by
#     downloading the asset and hashing it here. Trusting the API alone would
#     mean signing a hash nobody in this run ever computed;
#   • the size — from the downloaded bytes.
#
# It CANNOT name a draft or a prerelease, because `releases/latest` excludes both.
# That is what makes rexenv's human §A gate protect in-app updaters for free: a
# release nobody published has no assets anyone can fetch.
#
# ── The one fact that is typed, and how it is checked ────────────────────────
#
# `MIN_MACOS` — the floor a build needs. It lives in rexenv's tauri.conf.json,
# which is a PRIVATE repo this workflow cannot read, so it is declared below and
# cross-checked from the other side: rexenv's `scripts/check-app-manifest.sh`
# compares the published descriptor against its own tauri.conf.json and says so
# when they drift. A number restated in two repos is exactly the shape that goes
# stale (the cask's macOS floor did, for four releases), so it is checked rather
# than remembered.
#
# ── The key ──────────────────────────────────────────────────────────────────
#
# The SAME ed25519 key as the PHP manifest: `~/.rexenv/manifest-key.pem` on a
# laptop, or `$REXENV_MANIFEST_KEY` from the reviewer-gated `manifest-signing`
# environment. One key, one ceremony, one rotation — and one honest cost, which
# is that a compromise takes PHP, Adminer and the app together. Rotation means
# pinning a new public half in rexenv and shipping a release, which is what makes
# a stolen key survivable.
set -euo pipefail
cd "$(dirname "$0")/.."

TAP_REPO="${TAP_REPO:-rexenv/homebrew-tap}"
# The public half rexenv compiles in (RELEASE_PUBKEY in core/updates.rs). Public
# by definition — pinning it here is not a secret, it is a tripwire. Signing with
# any other key produces a document every installed app silently ignores, and
# nothing anywhere reports it: the apps refuse quietly, which is exactly what a
# forged document should look like from the outside. Checked BEFORE publishing so
# a rotation done backwards fails in this run instead of in the field.
EXPECTED_PUBKEY="faa52f961af3e0542d836ab539823f598ef88b976055809f73247f88af13cb12"
# rexenv's `minimumSystemVersion`. Cross-checked by rexenv's check-app-manifest.sh.
MIN_MACOS="15.0"
DOC="app-manifest.json"
SIG="$DOC.sig"
KEY="${REXENV_MANIFEST_KEY_FILE:-$HOME/.rexenv/manifest-key.pem}"

DRY=0
WANT=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) WANT="${arg#v}" ;;
  esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "publish-app-manifest: $*" >&2; exit 1; }

command -v gh >/dev/null || fail "gh is required"
command -v openssl >/dev/null || fail "openssl is required"

# ── The key, either way in ───────────────────────────────────────────────────
if [ -n "${REXENV_MANIFEST_KEY:-}" ]; then
  KEY="$WORK/key.pem"
  (umask 077; printf '%s\n' "$REXENV_MANIFEST_KEY" > "$KEY")
fi
[ -f "$KEY" ] || fail "no signing key: set \$REXENV_MANIFEST_KEY or put one at $KEY"

# Checked HERE, before a single byte is downloaded: a key mismatch makes the whole
# run pointless, and finding that out after the signature is the version of this
# failure that gets published anyway.
PUB="$(openssl pkey -in "$KEY" -pubout -outform DER | tail -c 32 | xxd -p -c 64)"
if [ "$PUB" != "$EXPECTED_PUBKEY" ]; then
  fail "this key is not the one shipped rexenv builds trust.
  signing key: $PUB
  app pins:    $EXPECTED_PUBKEY
  Publishing would produce a document every install refuses in silence. If the key
  was rotated on purpose, the order is: ship an app release carrying the new public
  half FIRST, then update EXPECTED_PUBKEY here, then publish."
fi

# ── 1. What did the tap actually publish? ────────────────────────────────────
if [ -n "$WANT" ]; then
  TAG="v$WANT"
else
  TAG="$(gh release list --repo "$TAP_REPO" --limit 1 --exclude-drafts --exclude-pre-releases \
           --json tagName --jq '.[0].tagName // ""')"
  [ -n "$TAG" ] || fail "no published release on $TAP_REPO"
fi
V="${TAG#v}"
printf '%s' "$V" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || fail "'$V' is not plain three-segment semver — rexenv refuses anything else, and a prerelease is not offerable by design"

ASSET="rexenv_${V}_universal.app.tar.gz"
REL="$(gh api "repos/$TAP_REPO/releases/tags/$TAG" 2>/dev/null)" \
  || fail "no release $TAG on $TAP_REPO (a draft is invisible here, which is the point)"

DIGEST="$(printf '%s' "$REL" | jq -r --arg n "$ASSET" 'first(.assets[] | select(.name == $n) | .digest) // ""')"
DIGEST="${DIGEST#sha256:}"
URL="$(printf '%s' "$REL" | jq -r --arg n "$ASSET" 'first(.assets[] | select(.name == $n) | .browser_download_url) // ""')"
PUBLISHED_AT="$(printf '%s' "$REL" | jq -r '.published_at // ""')"

if [ -z "$URL" ]; then
  fail "release $TAG carries no $ASSET.
  That release predates in-app self-update, or its build did not run
  scripts/release-assets.sh. There is nothing to describe — publish a release
  that has the archive first."
fi

# ── 2. Hash what a USER would download, not what the API says it is ──────────
echo "downloading $ASSET …"
curl -fsSL "$URL" -o "$WORK/$ASSET" || fail "could not download $URL"
SHA="$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}')"
SIZE="$(wc -c < "$WORK/$ASSET" | tr -d ' ')"
if [ -n "$DIGEST" ] && [ "$DIGEST" != "$SHA" ]; then
  fail "the asset's API digest and its bytes DISAGREE ($DIGEST vs $SHA) — refusing to sign"
fi
# The archive must be the shape rexenv's extractor expects. Checked HERE too,
# because this is the last point before a signature makes it trusted.
# Listed in FULL and sliced afterwards, never `tar … | head -1`: head closes the
# pipe on the first line, GNU tar takes the write error and exits 2, and under
# `set -o pipefail` that kills the whole run. bsdtar on macOS stays quiet about
# it, so this failed only on the Linux runner — found by the first dry run,
# 7 Sep 2026, which is what a dry run is for.
listing="$(tar -tzf "$WORK/$ASSET")"
first="${listing%%$'\n'*}"
[ "$first" = "rexenv.app/" ] || fail "the archive's first entry is '$first', not 'rexenv.app/'"

# ── 3. The serial: read the published one and increment ─────────────────────
CUR=0
if [ -f "$DOC" ]; then
  CUR="$(sed -n 's/.*"serial"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$DOC" | head -1)"
  CUR="${CUR:-0}"
fi
SERIAL=$((CUR + 1))
PREV_V="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$DOC" 2>/dev/null | head -1 || true)"
if [ -n "$PREV_V" ] && [ "$PREV_V" = "$V" ]; then
  echo "note: the published descriptor already names $V; this run re-signs it at serial $SERIAL"
fi

# ── 4. Build it ─────────────────────────────────────────────────────────────
cat > "$WORK/$DOC" <<JSON
{
  "serial": $SERIAL,
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "release": {
    "version": "$V",
    "url": "$URL",
    "sha256": "$SHA",
    "sizeBytes": $SIZE,
    "minAppVersion": "",
    "minimumSystemVersion": "$MIN_MACOS",
    "notes": "",
    "publishedAt": "$PUBLISHED_AT"
  }
}
JSON

# rexenv only accepts an artifact URL under a compiled-in releases/download
# prefix. Checked here so a wrong host fails in this run rather than silently
# never being offered to anyone.
case "$URL" in
  https://github.com/rexenv/homebrew-tap/releases/download/*|https://github.com/rexenv/rexenv/releases/download/*) ;;
  *) fail "the asset URL ($URL) is not under a prefix rexenv allows — it would be refused by every install" ;;
esac

# ── 5. Sign, then verify OUR OWN signature ──────────────────────────────────
# A signature nobody checked is a release nobody can install, and the failure
# lands on a user as "the signature does not verify".
openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$WORK/$DOC" -out "$WORK/sig.bin"
xxd -p -c 256 < "$WORK/sig.bin" | tr -d '\n' > "$WORK/$SIG"
openssl pkeyutl -verify -pubin -inkey <(openssl pkey -in "$KEY" -pubout) \
  -rawin -in "$WORK/$DOC" -sigfile "$WORK/sig.bin" >/dev/null \
  || fail "our own signature does not verify — refusing to publish"

echo
echo "serial $CUR → $SERIAL   release $V   $SIZE bytes"
echo "sha256 $SHA"
echo "signed with public key $PUB (matches the key shipped builds pin)"

if [ "$DRY" -eq 1 ]; then
  cp "$WORK/$DOC" "$WORK/$SIG" . 2>/dev/null || true
  echo
  echo "--dry-run: written to $(pwd)/$DOC (+ .sig), nothing committed."
  exit 0
fi

# ── 6. Publish: a COMMIT on the default branch ──────────────────────────────
#
# Not a release. A moved release tag broke this repo's PHP manifest in
# production (GitHub burns a tag name once an immutable release on it is
# deleted, and delete-then-create has no document at all in between), and the
# app's own descriptor URL is compiled into every shipped build — so it must be
# a path that never moves.
cp "$WORK/$DOC" "$DOC"
cp "$WORK/$SIG" "$SIG"
git add "$DOC" "$SIG"
git -c user.name="rexenv publisher" -c user.email="noreply@rexenv.dev" \
  commit -q -m "app-manifest: rexenv $V (serial $SERIAL)"
git push -q
echo
echo "published. Installed copies will be offered $V at their next check."
echo "Verify from the rexenv repo: ./scripts/check-app-manifest.sh"
