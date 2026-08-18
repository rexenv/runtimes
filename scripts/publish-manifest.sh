#!/bin/bash
# Discover new PHP patches, sign them, and publish the update manifest.
#
#   ./scripts/publish-manifest.sh                 discover everything and publish
#   ./scripts/publish-manifest.sh --dry-run       discover and sign, publish nothing
#   ./scripts/publish-manifest.sh 8.3.32 8.4.24   only these, no discovery
#   ./scripts/publish-manifest.sh --discover      print what is new, touch nothing
#
# `--discover` is the read-only half, for the daily cron: it probes upstream,
# subtracts what the published manifest already carries, and prints the leftover
# versions one per line on stdout — nothing else goes to stdout in that mode. It
# needs NO signing key, so the workflow that runs it every day never touches the
# secret. An empty stdout means there is nothing to tell a human about.
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
# Two ways in, and the script does not care which:
#
#   • `~/.rexenv/manifest-key.pem` (0600) — a maintainer publishing from a laptop.
#   • `$REXENV_MANIFEST_KEY` holding the PEM — what the GitHub Actions workflow
#     passes from the `REXENV_MANIFEST_KEY` secret.
#
# Be clear-eyed about the second one: this key can make every rexenv install
# download and run arbitrary bytes as the user, so on CI it is only as safe as
# push access to this repo. The workflow is `workflow_dispatch`-only and gated on
# a protected Environment, so reading the secret needs a human approval that is
# logged — which is the property that makes it acceptable, not the secret store.
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
# ── Adminer: a SECOND family in the same document ─────────────────────────────
#
# Not a `PINS` row — Adminer has no "minor track" the way PHP does. rexenv's
# `updates::Family::Adminer` accepts any version up to a MAJOR ceiling, because
# rexenv's controls for the database console (the loopback login gate, the
# frame-ancestors bound) live inside Adminer's own plugin API and a major bump is
# what may move those hooks.
#
# `ADMINER_MAX_MAJOR` must equal `updates::ADMINER_MAX_MAJOR` in the app, and
# BOTH are evidence: the app's number is the newest major whose plugin API has
# been run against rexenv's wrapper. Raising it here without raising it there
# publishes entries every installed app silently drops.
# `../rexenv/scripts/check-php-pins.sh` compares the two.
ADMINER_PIN="5.4.2"
ADMINER_MAX_MAJOR="6"
ADMINER_REPO="vrana/adminer"
ADMINER_BASE="https://github.com/$ADMINER_REPO/releases/download"

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
DISCOVER=0
EXPLICIT=()
ADMINER_EXPLICIT=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --discover) DISCOVER=1 ;;
    --check-pins)
      printf '%s\n' "${PINS[@]}"
      echo "adminer:$ADMINER_PIN (ceiling: major <= $ADMINER_MAX_MAJOR)"
      echo
      echo "Compare with PHP_VERSIONS in rexenv's src-tauri/src/core/binaries.rs."
      exit 0 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    # `adminer:6.0.1` names the OTHER family. Prefixed rather than guessed from
    # the number: 5.4.2 is a plausible Adminer version and a plausible typo for a
    # PHP one, and guessing wrong publishes an entry every app drops.
    adminer:*) ADMINER_EXPLICIT+=("${a#adminer:}") ;;
    *) EXPLICIT+=("$a") ;;
  esac
done

command -v openssl >/dev/null || { echo "openssl required" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh required" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; chmod 700 "$WORK"

# The key, from the environment if CI supplied it. Written 0600 inside the 0700
# work dir and removed with it — never to the repo, never to a shared /tmp path,
# and never echoed. `set -x` is deliberately not used anywhere in this script.
# `--discover` reads and reports; it never signs. Skipping the key here is the
# whole point — the daily workflow can run with `contents: read` and no access to
# the `manifest-signing` environment at all.
if [ "$DISCOVER" -eq 0 ]; then
if [ -n "${REXENV_MANIFEST_KEY:-}" ]; then
  KEY="$WORK/manifest-key.pem"
  (umask 077; printf '%s\n' "$REXENV_MANIFEST_KEY" > "$KEY")
fi
[ -f "$KEY" ] || {
  echo "no signing key: set \$REXENV_MANIFEST_KEY or put one at $KEY" >&2
  echo "see docs/MANIFEST.md" >&2
  exit 1
}
openssl pkey -in "$KEY" -noout 2>/dev/null || {
  # A truncated or CRLF-mangled secret fails here rather than three minutes and
  # ~400 MB of downloads later, at the signing step.
  echo "the signing key is not a readable PEM private key" >&2
  exit 1
}
fi

# ── Serial: read what is published, increment ─────────────────────────────────
#
# The two states are told APART on purpose. "No release yet" is a genuine first
# publish and starts at 1. "There is a release and I could not read it" is a
# refusal, because the fallback is catastrophic and silent: `CUR=0` makes
# `SERIAL=1`, the tag is deleted and republished, and every installed app then
# rejects the new document forever (`accept_with`: serial 1 is not > the 4 it
# already accepted). A correctly signed manifest that nobody can install, from
# one flaky `gh` call — a TOTAL update outage with no error anywhere.
#
# The old form was a single `view && download` conditional, so a transient
# failure of either landed in the same branch as "first run ever".
CUR=0
FIRST_RUN=0
PUBLISHED=""
if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  FIRST_RUN=1
  echo "no '$TAG' release yet — this is the first publish (serial 1)" >&2
else
  gh release download "$TAG" --repo "$REPO" --pattern manifest.json --dir "$WORK" 2>/dev/null || {
    echo "the '$TAG' release EXISTS but manifest.json could not be downloaded." >&2
    echo "Refusing: publishing now would reset the serial to 1, and every installed" >&2
    echo "rexenv would reject the result as a replay — permanently. Retry." >&2
    exit 1
  }
  CUR="$(sed -n 's/.*"serial"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$WORK/manifest.json" | head -1)"
  [ -n "$CUR" ] || {
    echo "the published manifest.json has no readable \"serial\" — refusing for the" >&2
    echo "same reason as above (see docs/MANIFEST.md §3)." >&2
    exit 1
  }
  # The versions the published document already carries. Used ONLY by --discover,
  # to decide whether a human needs telling. It must never filter the publish
  # path: the manifest is a REPLACEMENT set, not an accumulating one, so dropping
  # an already-published version from a later run would delete it from the
  # document and drop those users back to the pin compiled into their app.
  PUBLISHED="$(tr ',' '\n' < "$WORK/manifest.json" \
    | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' | sort -u)"
fi
SERIAL=$((CUR + 1))
# Belt and braces on the same failure: only a genuine first run may publish 1.
if [ "$SERIAL" -le 1 ] && [ "$FIRST_RUN" -eq 0 ]; then
  echo "serial would be $SERIAL on a repo that already has a '$TAG' release — refusing" >&2
  exit 1
fi

exists() { curl -sIL -o /dev/null -w '%{http_code}' --max-time 20 "$1" | grep -qE '^(200|302)$'; }

# ── Discovery ─────────────────────────────────────────────────────────────────
#
# Probe upward from each minor's PIN until two consecutive misses. Two, not one:
# upstream has skipped a patch number before, and stopping at the first 404 would
# hide everything after it. Only the CLI artifact is probed here — all four are
# fetched and hashed below, and a version missing any of them is dropped whole,
# because rexenv requires both arches of both kinds or it will not resolve.
#
# Naming versions on the command line ADDS to discovery; it does not replace it.
# It used to replace it, and that is a truncation bug rather than a preference:
# the manifest is a REPLACEMENT document, so `publish-manifest.sh 8.3.32` wrote a
# manifest containing ONLY 8.3.32 and silently DELETED every other version from
# it — after which a user on 8.2.32 can no longer resolve it (a fresh install or
# a cache repair fails, and `php_update_apply` refuses it as unvouched).
#
# The one legitimate use of an explicit version — "upstream published it but my
# probe cannot see it" — is served by adding, not by replacing.
VERSIONS=()
if [ ${#EXPLICIT[@]} -gt 0 ]; then
  VERSIONS=("${EXPLICIT[@]}")
  echo "explicit versions: ${VERSIONS[*]} (discovery still runs; these are added)" >&2
fi
{
  echo "discovering patches newer than each pin…" >&2
  for entry in "${PINS[@]}"; do
    minor="${entry%%:*}"; pin="${entry##*:}"
    [ "$minor" = "7.4" ] && continue   # ours; static-php.dev has never published it
    start="${pin##*.}"
    misses=0; p=$((start + 1))
    while [ "$misses" -lt 2 ] && [ "$p" -lt $((start + 30)) ]; do
      v="${minor}.${p}"
      if exists "$BASE/php-${v}-cli-macos-aarch64.tar.gz"; then
        echo "  found $v" >&2
        VERSIONS+=("$v"); misses=0
      else
        misses=$((misses + 1))
      fi
      p=$((p + 1))
    done
  done
}
# Dedupe, keep version order. `sort -V` so 8.3.9 precedes 8.3.10.
if [ ${#VERSIONS[@]} -gt 0 ]; then
  # shellcheck disable=SC2207
  VERSIONS=($(printf '%s\n' "${VERSIONS[@]}" | sort -Vu))
fi

# ── Adminer discovery: a LISTING, not a probe ────────────────────────────────
#
# PHP is probed upward because static-php.dev publishes no index. Adminer does:
# the GitHub releases API is authoritative, so guessing 5.4.3, 5.4.4, … would be
# slower AND wrong at every track boundary — the pin is 5.4.2 and the newest is
# 6.0.1, which no upward-from-the-pin walk with a miss budget would ever reach.
#
# `.draft==false` is load-bearing and non-obvious: this script runs with GH_TOKEN
# in CI, so drafts ARE visible to it — and a draft's asset URL 404s for everyone
# else. Publishing one would put an entry in the manifest that no user can
# resolve. Prereleases are excluded for the ordinary reason.
ADMINER_VERSIONS=()
if [ ${#ADMINER_EXPLICIT[@]} -gt 0 ]; then
  ADMINER_VERSIONS=("${ADMINER_EXPLICIT[@]}")
  echo "explicit adminer versions: ${ADMINER_VERSIONS[*]} (discovery still runs)" >&2
fi
echo "listing adminer releases newer than ${ADMINER_PIN}…" >&2
while read -r tag; do
  v="${tag#v}"
  case "$v" in [0-9]*.[0-9]*.[0-9]*) ;; *) continue ;; esac
  # Strictly newer than the pin. `sort -V` decides, so 5.4.10 beats 5.4.9.
  [ "$(printf '%s\n%s\n' "$ADMINER_PIN" "$v" | sort -V | tail -1)" = "$v" ] || continue
  [ "$v" = "$ADMINER_PIN" ] && continue
  # …and at or below the ceiling the app will accept.
  [ "${v%%.*}" -le "$ADMINER_MAX_MAJOR" ] || {
    echo "  skipping $v — major above the probed ceiling ($ADMINER_MAX_MAJOR)" >&2
    continue
  }
  echo "  found adminer $v" >&2
  ADMINER_VERSIONS+=("$v")
done < <(gh api "repos/$ADMINER_REPO/releases" --paginate \
  --jq '.[] | select(.draft==false and .prerelease==false) | .tag_name' 2>/dev/null || true)
if [ ${#ADMINER_VERSIONS[@]} -gt 0 ]; then
  # shellcheck disable=SC2207
  ADMINER_VERSIONS=($(printf '%s\n' "${ADMINER_VERSIONS[@]}" | sort -Vu))
fi

if [ "$DISCOVER" -eq 1 ]; then
  # QUALIFIED: unqualified, an issue body reads "8.4.24 5.5.1" and a human
  # cannot tell which project 5.5.1 belongs to.
  NEW=()
  for V in "${VERSIONS[@]}"; do
    printf '%s\n' "$PUBLISHED" | grep -qx "$V" || NEW+=("php:$V")
  done
  for V in "${ADMINER_VERSIONS[@]}"; do
    printf '%s\n' "$PUBLISHED" | grep -qx "$V" || NEW+=("adminer:$V")
  done
  echo "upstream above the pins — php: ${VERSIONS[*]:-none}" >&2
  echo "upstream above the pins — adminer: ${ADMINER_VERSIONS[*]:-none}" >&2
  echo "already in the published manifest: $(printf '%s ' $PUBLISHED)" >&2
  [ ${#NEW[@]} -gt 0 ] && printf '%s\n' "${NEW[@]}"
  exit 0
fi

if [ ${#VERSIONS[@]} -eq 0 ] && [ ${#ADMINER_VERSIONS[@]} -eq 0 ]; then
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

# ── Adminer: one artifact per version, arch-free ─────────────────────────────
#
# `arch: "any"` because it is ONE .php file — the same bytes on every machine.
# Publishing it twice under two arch labels would be a fiction stated twice, and
# rexenv refuses it: `Family::Adminer::arch_ok` accepts only "any", so a per-arch
# row is dropped and the version becomes unofferable.
for V in "${ADMINER_VERSIONS[@]}"; do
  case "$V" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "not an x.y.z adminer version: $V" >&2; exit 1 ;; esac
  [ "${V%%.*}" -le "$ADMINER_MAX_MAJOR" ] || {
    echo "adminer $V is above the probed ceiling ($ADMINER_MAX_MAJOR) — the app would drop it. Skipping." >&2
    continue
  }
  # The `-en.php` asset: the English-only build, which is what rexenv pins.
  URL="$ADMINER_BASE/v${V}/adminer-${V}-en.php"
  OUT="$WORK/adminer-$V"
  printf '  adminer %s … ' "$V"
  if ! curl -fsSL --retry 3 -o "$OUT" "$URL"; then
    echo "MISSING"
    echo "  → adminer $V has no $(basename "$URL") asset; dropped." >&2
    continue
  fi
  SHA="$(shasum -a 256 "$OUT" | awk '{print $1}')"
  echo "$SHA"
  ENTRIES="${ENTRIES:+$ENTRIES,}$(printf '{"name":"adminer","version":"%s","arch":"any","url":"%s","sha256":"%s"}' \
    "$V" "$URL" "$SHA")"
  KEPT+=("adminer $V")
done

[ ${#KEPT[@]} -gt 0 ] || { echo "no complete version to publish"; exit 0; }

printf '{"serial":%d,"generatedAt":"%s","minAppVersion":"%s","artifacts":[%s]}' \
  "$SERIAL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MIN_APP" "$ENTRIES" > manifest.json

# ── Nothing the published document carries may DISAPPEAR ──────────────────────
#
# The manifest is a REPLACEMENT document, so every publish can silently delete.
# A dropped entry is not cosmetic: a user already on that version can no longer
# resolve it (a fresh install or a cache repair fails, and an apply refuses it as
# unvouched), and the app has no way to notice — the document it fetched is
# perfectly signed.
#
# Discovery is a live probe of somebody else's server, so "it answered yesterday
# and 404s today" is a normal Tuesday, not a decision. This is the check that
# turns that into a refusal instead of a deletion. Checked HERE, after the
# document is written and before it is signed, because the thing to compare is
# what will actually be published.
if [ "$FIRST_RUN" -eq 0 ]; then
  missing=""
  # name|version|arch triples, one per line, from the PUBLISHED document.
  while IFS= read -r triple; do
    [ -n "$triple" ] || continue
    n="${triple%%|*}"; rest="${triple#*|}"; v="${rest%%|*}"; a="${rest##*|}"
    grep -q "\"name\":\"$n\",\"version\":\"$v\",\"arch\":\"$a\"" manifest.json \
      || missing="${missing}  $n $v ($a)"$'\n'
  done < <(tr '{' '\n' < "$WORK/manifest.json" \
    | sed -n 's/.*"name":"\([^"]*\)","version":"\([^"]*\)","arch":"\([^"]*\)".*/\1|\2|\3/p')
  if [ -n "$missing" ]; then
    echo >&2
    echo "REFUSING: the new manifest DROPS entries the published one carries:" >&2
    printf '%s' "$missing" >&2
    echo "Publishing it would delete them from the document, and users already on" >&2
    echo "those versions could no longer resolve them. If a version really is gone" >&2
    echo "upstream, say so deliberately: name every version you DO want on the" >&2
    echo "command line (they are added to discovery, not substituted for it) and" >&2
    echo "re-run with REXENV_MANIFEST_ALLOW_DROP=1." >&2
    [ "${REXENV_MANIFEST_ALLOW_DROP:-0}" = "1" ] || exit 1
    echo "REXENV_MANIFEST_ALLOW_DROP=1 — proceeding anyway." >&2
  fi
fi

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
