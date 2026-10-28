#!/bin/bash
# Gate a Linux Redis artifact in a CLEAN ubuntu container (see gate-common.sh):
# a real server answers, not a file listing.
#
#   scripts/gate-redis.sh <redis-<v>-linux-<arch>.tar.gz>
# shellcheck source=gate-common.sh
. "$(dirname "$0")/gate-common.sh"

TARBALL="${1:?artifact required}"
banner
unpack_artifact "$TARBALL"
V="$(basename "$TARBALL" | sed -E 's/^redis-([0-9.]+)-linux-.*/\1/')"

say "layout rexenv reads (core/redis.rs)"
for f in bin/redis-server bin/redis-cli; do [ -x "$ROOT/$f" ] || fail "$f missing"; done
echo "  $(cd "$ROOT" && find . -type f | sort | tr '\n' ' ')"

say "dynamic closure on this host"
ldd_gate "$ROOT/bin/redis-server" "$ROOT/bin/redis-cli"

say "a real server"
P=16399
DATA="$(mktemp -d)"
# rexenv's own argument list (core/redis.rs) plus --save '' so the gate leaves no
# snapshot behind; LC_ALL=C exactly as rexenv sets it (ledger #714).
LC_ALL=C "$ROOT/bin/redis-server" --port "$P" --bind 127.0.0.1 --dir "$DATA" --daemonize no --save '' \
  > "$DATA/stdout.log" 2>&1 &
PID=$!
wait_tcp "$P" 15 || { cat "$DATA/stdout.log"; fail "redis-server did not listen on $P"; }
cli() { "$ROOT/bin/redis-cli" -p "$P" "$@"; }

[ "$(cli PING)" = PONG ] || fail "PING did not return PONG"
[ "$(cli SET rexenv:gate "hello ✓ $$")" = OK ] || fail "SET"
[ "$(cli GET rexenv:gate)" = "hello ✓ $$" ] || fail "GET did not round-trip"
# The object-cache shape: an expiring key and an atomic counter.
cli SET rexenv:ttl x EX 60 >/dev/null
T="$(cli TTL rexenv:ttl)"; [ "$T" -gt 0 ] && [ "$T" -le 60 ] || fail "TTL $T"
cli INCR rexenv:n >/dev/null; [ "$(cli INCR rexenv:n)" = 2 ] || fail "INCR"
INFO="$(cli INFO server | tr -d '\r')"
has "^redis_version:$V$" "$INFO" || fail "INFO says $(grep redis_version <<<"$INFO")"
has '^mem_allocator:jemalloc' "$(cli INFO memory | tr -d '\r')" || fail "not jemalloc at runtime"
echo "  PING PONG · SET/GET round trip · TTL $T · INCR · $(grep -E '^(redis_version|os|arch_bits)' <<<"$INFO" | tr '\n' ' ')"

cli SHUTDOWN NOSAVE >/dev/null 2>&1 || true
for _ in $(seq 1 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
! kill -0 "$PID" 2>/dev/null || fail "redis-server did not stop on SHUTDOWN"
if has '# (Failed|FATAL|Fatal)' "$(cat "$DATA/stdout.log")"; then cat "$DATA/stdout.log"; fail "the server log has a fatal line"; fi
echo "PASS redis $V"
