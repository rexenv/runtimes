#!/bin/bash
# Gate a Linux MariaDB artifact in a CLEAN ubuntu container (see gate-common.sh):
# rexenv's own bootstrap and start arguments, then real SQL over the socket and
# TCP, then a dump.
#
#   scripts/gate-mariadb.sh <mariadb-<v>-linux-<arch>.tar.gz>
# shellcheck source=gate-common.sh
. "$(dirname "$0")/gate-common.sh"

TARBALL="${1:?artifact required}"
banner
unpack_artifact "$TARBALL"
V="$(basename "$TARBALL" | sed -E 's/^mariadb-([0-9.]+)-linux-.*/\1/')"

say "layout rexenv reads (core/mariadb.rs)"
for f in bin/mariadbd bin/mariadb bin/mariadb-dump; do [ -x "$ROOT/$f" ] || fail "$f missing"; done
SQL=(share/mysql/mariadb_system_tables.sql share/mysql/mariadb_performance_tables.sql share/mysql/mariadb_system_tables_data.sql)
for f in "${SQL[@]}" share/mysql/english/errmsg.sys share/mysql/charsets/Index.xml; do [ -s "$ROOT/$f" ] || fail "$f missing"; done
# Only what rexenv runs: no plugin dir, no scripts, no test suite.
EXTRA="$(cd "$ROOT" && find . -type f ! -path './bin/mariadbd' ! -path './bin/mariadb' ! -path './bin/mariadb-dump' \
         ! -path './share/mysql/*.sql' ! -path './share/mysql/english/errmsg.sys' ! -path './share/mysql/charsets/*')"
[ -z "$EXTRA" ] || fail "ships more than the server, client, dump, bootstrap SQL, errmsg and charsets: $EXTRA"
echo "  bin: $(ls "$ROOT/bin" | tr '\n' ' ')· share/mysql: $(ls "$ROOT/share/mysql" | tr '\n' ' ')· charsets: $(ls "$ROOT/share/mysql/charsets" | wc -l) files"

say "dynamic closure on this host"
ldd_gate "$ROOT"/bin/*

G="$(mktemp -d /tmp/mdb.XXXXXX)"
DATA="$G/data dir"; RUN="$G/run"; LOGS="$G/logs"
mkdir -p "$RUN" "$LOGS" "$DATA"
SOCK="$RUN/mariadb.sock"
PORT=13399
SHARE=(--lc-messages-dir="$ROOT/share/mysql/english" --character-sets-dir="$ROOT/share/mysql/charsets")

say "bootstrap: mariadbd --bootstrap, the three SQL files over stdin (core/mariadb.rs)"
# The exact preamble and argument list rexenv's bootstrap() sends.
{
  printf 'create database if not exists mysql;\nuse mysql;\nSET @auth_root_socket=NULL;\n'
  for f in "${SQL[@]}"; do cat "$ROOT/$f"; echo; done
} > "$G/bootstrap.sql"
if ! "$ROOT/bin/mariadbd" --no-defaults --bootstrap --basedir="$ROOT" --datadir="$DATA" \
      --log-warnings=0 --max_allowed_packet=8M --net_buffer_length=16K "${SHARE[@]}" \
      < "$G/bootstrap.sql" > "$LOGS/bootstrap.out" 2> "$LOGS/bootstrap.err"; then
  tail -30 "$LOGS/bootstrap.err"; fail "mariadbd --bootstrap failed"
fi
[ -d "$DATA/mysql" ] || fail "bootstrap left no mysql/ schema dir (rexenv's is_initialized marker)"
echo "  datadir: $(ls "$DATA" | tr '\n' ' ')"

say "a real server on a socket and 127.0.0.1:$PORT (rexenv's start() arguments)"
"$ROOT/bin/mariadbd" --no-defaults --basedir="$ROOT" --datadir="$DATA" --port="$PORT" --socket="$SOCK" \
  --bind-address=127.0.0.1 --log-error="$LOGS/mariadb-error.log" "${SHARE[@]}" > "$LOGS/stdout.log" 2>&1 &
MPID=$!
bad() { echo "--- error log"; tail -40 "$LOGS/mariadb-error.log" 2>/dev/null; kill -TERM "$MPID" 2>/dev/null || true; wait "$MPID" 2>/dev/null || true; fail "$*"; }
wait_tcp "$PORT" 60 || bad "mariadbd did not listen on $PORT"
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || bad "no socket at $SOCK"

tcp()  { "$ROOT/bin/mariadb" --no-defaults -uroot -h127.0.0.1 -P"$PORT" --default-character-set=utf8mb4 --batch --skip-column-names "$@"; }
sock() { "$ROOT/bin/mariadb" --no-defaults -uroot -S "$SOCK" --default-character-set=utf8mb4 --batch --skip-column-names "$@"; }

SV="$(sock -e 'SELECT VERSION()')" || bad "socket connection refused"
has "^$V-MariaDB" "$SV" || bad "server says $SV, want $V"
echo "  socket: VERSION() = $SV"
tcp -e "CREATE DATABASE gate CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" || bad "CREATE DATABASE"
tcp gate -e "CREATE TABLE t (id INT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(64) NOT NULL) ENGINE=InnoDB" || bad "CREATE TABLE"
tcp gate -e "INSERT INTO t (v) VALUES ('héllo ✓'), ('second')" || bad "INSERT"
ROWS="$(tcp gate -e "SELECT id, v FROM t ORDER BY id")" || bad "SELECT"
[ "$ROWS" = "$(printf '1\théllo ✓\n2\tsecond')" ] || bad "SELECT returned: $ROWS"
echo "  tcp: CREATE DATABASE / CREATE TABLE (InnoDB) / INSERT / SELECT → $(tr '\t\n' '= ' <<<"$ROWS")"
# errmsg.sys and the charsets dir are what --lc-messages-dir/--character-sets-dir
# point at; an error message and a non-default charset prove both were READ.
E="$(tcp -e 'SELEC 1' 2>&1 || true)"
has 'You have an error in your SQL syntax' "$E" || bad "error message text missing (errmsg.sys): $E"
[ "$(tcp -e "SELECT CONVERT(_utf8mb4'é' USING latin2) = _latin2 X'E9'")" = 1 ] || bad "latin2 conversion (charsets)"
# TLS, both ends: the server and client carry the same static OpenSSL. The
# server's certificate is the one it generates for itself at start (no cert is
# configured), so the client is told not to verify it — what is proven is that a
# handshake completes, not whose certificate it was.
HAVE_SSL="$(tcp -e "SELECT @@have_ssl")"
if [ "$HAVE_SSL" = YES ]; then
  CIPHER="$(tcp --ssl --disable-ssl-verify-server-cert -e "SHOW SESSION STATUS LIKE 'Ssl_cipher'" | cut -f2)"
  [ -n "$CIPHER" ] || bad "TLS connection negotiated no cipher"
  echo "  tls: have_ssl=YES, client↔server handshake → $CIPHER ($(tcp -e "SHOW GLOBAL VARIABLES LIKE 'version_ssl_library'" | cut -f2))"
else
  bad "have_ssl=$HAVE_SSL — the server was built with OpenSSL and should offer TLS"
fi
ENG="$(tcp -e "SELECT GROUP_CONCAT(ENGINE ORDER BY ENGINE) FROM information_schema.ENGINES WHERE SUPPORT IN ('YES','DEFAULT')")"
has 'InnoDB' "$ENG" && has 'Aria' "$ENG" || bad "engines: $ENG"
echo "  engines: $ENG"

say "mariadb-dump"
"$ROOT/bin/mariadb-dump" --no-defaults -uroot -h127.0.0.1 -P"$PORT" gate > "$G/gate.sql" 2> "$LOGS/dump.err" \
  || { cat "$LOGS/dump.err"; bad "mariadb-dump failed"; }
has 'CREATE TABLE `t`' "$(cat "$G/gate.sql")" || bad "dump has no CREATE TABLE"
# 12.x writes one row per line after `INSERT INTO `t` VALUES`; 11.4 one line.
has 'INSERT INTO `t` VALUES' "$(cat "$G/gate.sql")" || bad "dump has no INSERT"
has "\\(1,'héllo ✓'\\)" "$(cat "$G/gate.sql")" || { grep -A2 -m1 'INSERT INTO' "$G/gate.sql" | cut -c1-200; bad "dump lost the row"; }
echo "  dump: $(wc -c < "$G/gate.sql") bytes, CREATE TABLE + INSERT present"
# And it restores: the dump is only useful if it is SQL this server accepts.
tcp -e "CREATE DATABASE gate2" && tcp gate2 < "$G/gate.sql" || bad "restore of the dump failed"
[ "$(tcp gate2 -e 'SELECT COUNT(*) FROM t')" = 2 ] || bad "restored table has the wrong row count"

kill -TERM "$MPID"
for _ in $(seq 1 300); do kill -0 "$MPID" 2>/dev/null || break; sleep 0.1; done
! kill -0 "$MPID" 2>/dev/null || bad "mariadbd did not shut down on SIGTERM"
has 'Shutdown complete' "$(cat "$LOGS/mariadb-error.log")" || bad "no clean shutdown in the log"
if grep -E '\[ERROR\]' "$LOGS/mariadb-error.log"; then fail "[ERROR] lines in the server log (above)"; fi
if grep -F -- '/opt/rexenv' "$LOGS"/*; then fail "the server reached for a compiled-in /opt/rexenv path"; fi
echo "PASS mariadb $V"
