# shellcheck shell=bash
# Sourced by scripts/gate-{redis,mariadb,httpd}.sh — INSIDE a CLEAN ubuntu
# container (22.04, then 24.04) that scripts/linux-build.sh starts with no
# network, as an unprivileged user, and with nothing installed: not the build
# container, whose compilers and -dev packages would hide a library the artifact
# forgot to bundle. Bash, coreutils, tar and ldd are all this may assume.

set -euo pipefail
say() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
fail() { echo "::error::$*"; exit 1; }
has() { grep -qE -- "$1" <<<"$2"; }

banner() {
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "gate host: $PRETTY_NAME, $(uname -m), $(ldd --version | head -1), uid $(id -u)"
  [ "$(id -u)" != 0 ] || fail "gates run unprivileged (rexenv never runs these as root)"
}

# Unpack into a directory whose path has a SPACE and is not where anything was
# built: rexenv's app-data paths have spaces on macOS, and a compiled-in path
# that only works from the build tree fails here rather than on a user's machine.
unpack_artifact() {   # <tar.gz> → sets ROOT
  ROOT="$(mktemp -d /tmp/gate.XXXXXX)/rexenv bin/tree"
  mkdir -p "$ROOT"
  tar -xzf "$1" -C "$ROOT"
  cd /
}

# The dynamic closure as THIS host resolves it: every library must be glibc's
# own (+ libcrypt.so.1) or live inside the unpacked tree. "not found" is the
# whole point — it is what a user without the -dev package would see.
GLIBC_SONAMES='linux-vdso\.so\.1|libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|libcrypt\.so\.1|ld-linux[-a-z0-9_]*\.so\.[12]'
ldd_gate() {   # <file>...
  local f out line name path bad=""
  for f in "$@"; do
    out="$(ldd "$f" 2>&1)" || fail "ldd $f: $out"
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      [ -n "$line" ] || continue
      name="${line%% *}"
      case "$line" in
        *"not found"*) bad+=" $name(not found)"; continue ;;
      esac
      # Up to the load address, not the first space: the tree's path has one.
      path="$(sed -nE 's/.*=> (.*) \(0x[0-9a-f]+\)$/\1/p' <<<"$line")"
      [ -n "$path" ] || path="$name"
      if [[ "$path" == "$ROOT"/* ]]; then continue; fi
      if has "^(/[^ ]*/)?($GLIBC_SONAMES)$" "$path" || has "^($GLIBC_SONAMES)$" "${path##*/}"; then continue; fi
      bad+=" $name=>$path"
    done <<<"$out"
    echo "  ${f#"$ROOT"/}: $(awk '{print $1}' <<<"$out" | tr '\n' ' ')"
  done
  [ -z "$bad" ] || fail "outside glibc and the bundle:$bad"
}

wait_tcp() {   # <port> <seconds>
  for _ in $(seq 1 $(( $2 * 10 ))); do
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# HTTP/1.0 over bash's /dev/tcp — there is no curl here, on purpose.
# Prints the status line's code on the first line, then the body.
http_get() {   # <port> <path> [extra header line]
  local resp
  exec 3<>"/dev/tcp/127.0.0.1/$1"
  printf 'GET %s HTTP/1.0\r\nHost: gate.rex\r\n%s\r\n' "$2" "${3:+$3$'\r\n'}" >&3
  resp="$(cat <&3)"
  exec 3<&-
  awk 'NR==1{print $2; next} f{print} /^\r?$/{f=1}' <<<"$resp" | tr -d '\r'
}
