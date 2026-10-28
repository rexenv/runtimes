# shellcheck shell=bash
# Sourced by scripts/build-{redis,mariadb,httpd}.sh — INSIDE the ubuntu:22.04
# build container that scripts/linux-build.sh starts. Never run on its own.
#
# What lives here is what all three builds must agree on: where sources come from
# and how they are verified, what an artifact may link, and how it is packed.
# A rule copied into three scripts drifts in three directions.

say() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
fail() { echo "::error::$*"; exit 1; }
# Captured, never piped into grep -q: under pipefail, grep exiting at the first
# match SIGPIPEs the producer and a PASSING check reports failure (CLAUDE.md).
has() { grep -qE -- "$1" <<<"$2"; }

# The floor is the glibc the binary was linked against, so the build host IS the
# floor: Ubuntu 22.04, glibc 2.35 (rexenv D-L4). A build that ran anywhere else
# would demand whatever glibc that host had, and nothing would say so until a
# 22.04 user ran it.
assert_build_host() {   # <arch>
  [ "$(uname -s)" = Linux ] || fail "this script runs inside the ubuntu:22.04 build container (scripts/linux-build.sh)"
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "$ID/$VERSION_ID" = "ubuntu/22.04" ] || fail "build host is $ID $VERSION_ID; the glibc floor needs ubuntu 22.04"
  [ "$(uname -m)" = "$1" ] || fail "asked for $1, running on $(uname -m) — spc-style native builds only, no cross"
  JOBS="${JOBS_OVERRIDE:-$(nproc)}"
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends "$@" >/dev/null
}

# Every source is checked against the digest its PROJECT publishes, written into
# the build script beside the version — so a version bump without a digest is a
# build that refuses to start, not one that trusts whatever the URL served.
# /cache survives between local runs (linux-build.sh mounts it) so a MariaDB
# retry does not re-download 210 MB; a cached file is re-verified every time.
fetch_verified() {   # <url> <file> <sha256>
  local url="$1" f="/cache/$2" want="$3" got
  [ -n "$want" ] || fail "no pinned sha256 for $2 — add the project's published digest to the script"
  if [ ! -f "$f" ] || [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$want" ]; then
    curl -fsSL --retry 5 --retry-delay 5 "$url" -o "$f.part"
    mv "$f.part" "$f"
  fi
  got="$(sha256sum "$f" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || fail "$2: sha256 $got, published $want"
  echo "  $2  $got"
}

# What an artifact may NEED from the host: glibc's own libraries and libcrypt.so.1
# (split out of glibc in 2.33's distros, Priority: required on every Ubuntu — the
# OpenLiteSpeed build allows the same set), plus whatever the caller bundles.
# Everything else is static or ships in the archive. Built on 22.04, the highest
# GLIBC_x.y symbol cannot exceed 2.35 — asserted anyway, because "cannot" is
# the kind of word this repo has had to take back.
GLIBC_NEEDED='libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|libcrypt\.so\.1|ld-linux[-a-z0-9_]*\.so\.[12]'
elf_gate() {   # <extra NEEDED regex or ''> <file>...
  local extra="$1"; shift
  local allow="^($GLIBC_NEEDED${extra:+|$extra})$" f needed bad rp glibc
  case "$(uname -m)" in x86_64) local want="x86-64" ;; aarch64) local want="aarch64" ;; esac
  for f in "$@"; do
    has "ELF 64-bit.*$want" "$(file -b "$f")" || fail "$f is not a $want ELF: $(file -b "$f")"
    needed="$(readelf -d "$f" | awk -F'[][]' '/\(NEEDED\)/{print $2}')"
    bad="$(grep -vE -- "$allow" <<<"$needed" || true)"
    [ -z "$bad" ] || fail "$f needs $(echo $bad) — not glibc and not bundled"
    # An absolute RUNPATH is a path on the BUILD machine; on a user's it is
    # either missing or, worse, somebody else's directory.
    rp="$(readelf -d "$f" | awk -F'[][]' '/\((RPATH|RUNPATH)\)/{print $2}')"
    if [ -n "$rp" ]; then
      bad="$(tr ':' '\n' <<<"$rp" | grep -v '^\$ORIGIN' || true)"
      [ -z "$bad" ] || fail "$f has a non-\$ORIGIN RUNPATH: $rp"
    fi
    glibc="$(objdump -T "$f" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -t. -k2 -n -u | tail -1 || true)"
    [ "$(printf '%s\nGLIBC_2.35\n' "${glibc:-GLIBC_2.0}" | sort -t. -k2 -n | tail -1)" = "GLIBC_2.35" ] \
      || fail "$f needs $glibc, above Ubuntu 22.04's 2.35"
    printf '  %-28s NEEDED: %s  RUNPATH: %s  max %s\n' "${f##*/}" "$(echo $needed)" "${rp:--}" "${glibc:-none}"
  done
}

# Deterministic member order, ownership and mode bits: the archive says nothing
# about the container that made it. (Timestamps stay real; the README says these
# builds are not bit-for-bit reproducible and does not claim otherwise.)
pack() {   # <out.tar.gz> <dir> <member>...
  local out="$1" dir="$2"; shift 2
  tar -C "$dir" --sort=name --owner=0 --group=0 --numeric-owner -czf "$out" "$@"
}

# The licence archive, in the layout rexenv reads (`licenses/` at the top, as
# every other release here): each file named EXPLICITLY by the caller, because a
# glob that silently matches nothing is how a licence archive ships empty.
pack_licences() {   # <out.tar.gz> <dir holding licenses/>
  local f
  for f in "$2"/licenses/*; do [ -s "$f" ] || fail "empty licence file: $f"; done
  pack "$1" "$2" licenses
  echo "licences: $(ls "$2/licenses" | tr '\n' ' ')"
}

# The scripts that drove this build, beside the sources: for the GPL/AGPL
# runtimes they are part of the corresponding source ("the scripts used to
# control compilation"), and for all three they answer "how was this made" from
# the release page alone.
pack_build_scripts() {   # <out.tar.gz> <name>
  tar -C /src --sort=name --owner=0 --group=0 --numeric-owner -czf "$1" \
    scripts/linux-build.sh scripts/linux-common.sh scripts/gate-common.sh \
    "scripts/build-$2.sh" "scripts/gate-$2.sh"
}

checksum_out() {   # <out-dir> <file>...
  local d="$1"; shift
  ( cd "$d" && for f in "$@"; do sha256sum "$f" > "$f.sha256"; done )
}
