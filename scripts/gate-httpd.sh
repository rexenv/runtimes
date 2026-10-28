#!/bin/bash
# Gate a Linux httpd artifact in a CLEAN ubuntu container (see gate-common.sh):
# rexenv's conf, a running server, and PHP answering through mod_proxy_fcgi.
#
#   scripts/gate-httpd.sh <httpd-<v>-linux-<arch>.tar.gz> <php-<v>-fpm-linux-<arch>.tar.gz>
# shellcheck source=gate-common.sh
. "$(dirname "$0")/gate-common.sh"

TARBALL="${1:?artifact required}"
FPM_TARBALL="${2:?php-fpm artifact required}"
banner
unpack_artifact "$TARBALL"
V="$(basename "$TARBALL" | sed -E 's/^httpd-([0-9.]+)-linux-.*/\1/')"

# The ten modules, in core/apache.rs's load order (MPM_MODULES, then MODULES).
MODS=(mpm_event:mod_mpm_event.so unixd:mod_unixd.so authz_core:mod_authz_core.so dir:mod_dir.so
      mime:mod_mime.so env:mod_env.so log_config:mod_log_config.so rewrite:mod_rewrite.so
      proxy:mod_proxy.so proxy_fcgi:mod_proxy_fcgi.so)

say "layout rexenv reads (core/apache.rs Layout::for_os(\"linux\"))"
[ -x "$ROOT/bin/httpd" ] || fail "bin/httpd missing"
[ -s "$ROOT/.bottle/etc/httpd/mime.types" ] || fail ".bottle/etc/httpd/mime.types missing"
for m in "${MODS[@]}"; do [ -f "$ROOT/lib/httpd/modules/${m#*:}" ] || fail "lib/httpd/modules/${m#*:} missing"; done
N="$(find "$ROOT/lib/httpd/modules" -name '*.so' | wc -l)"
[ "$N" = 10 ] || fail "$N modules shipped, want exactly the ten the conf loads"
echo "  $(cd "$ROOT" && find . -type f | sort | tr '\n' ' ')"

say "dynamic closure on this host"
mapfile -t ELFS < <(find "$ROOT" -type f \( -name httpd -o -name '*.so*' \) | sort)
ldd_gate "${ELFS[@]}"

say "php-fpm (static, our own build) as the FastCGI pool"
FPMDIR="$(mktemp -d)"
tar -xzf "$FPM_TARBALL" -C "$FPMDIR"
[ -x "$FPMDIR/php-fpm" ] || fail "no php-fpm in $FPM_TARBALL"
FPM_PORT=19783
cat > "$FPMDIR/fpm.conf" <<EOF
[global]
error_log = $FPMDIR/fpm.log
daemonize = no
pid = $FPMDIR/fpm.pid
[www]
listen = 127.0.0.1:$FPM_PORT
pm = static
pm.max_children = 2
catch_workers_output = yes
EOF
"$FPMDIR/php-fpm" -n -y "$FPMDIR/fpm.conf" -F > "$FPMDIR/stdout.log" 2>&1 &
FPMPID=$!
wait_tcp "$FPM_PORT" 15 || { cat "$FPMDIR/stdout.log" "$FPMDIR/fpm.log"; fail "php-fpm did not listen"; }

say "rexenv's conf (core/apache.rs generate_config, Linux layout)"
G="$(mktemp -d /tmp/site.XXXXXX)"
DOC="$G/my site/public"; RUN="$G/run"; LOGS="$G/logs"
mkdir -p "$DOC/sub" "$RUN" "$LOGS"
PORT=18300
echo '<h1>static ok</h1>' > "$DOC/index.html"
echo 'plain text' > "$DOC/a.txt"
echo 'SECRET=1' > "$DOC/.env"
echo '<h1>rewritten by htaccess</h1>' > "$DOC/target.html"
cat > "$DOC/info.php" <<'EOF'
<?php
echo "php ok\n";
echo "script=", $_SERVER['SCRIPT_FILENAME'], "\n";
echo "uri=", $_SERVER['REQUEST_URI'], "\n";
echo "https=", $_SERVER['HTTPS'] ?? '', "\n";
echo "env=", getenv('REXENV_GATE') ?: ($_SERVER['REXENV_GATE'] ?? ''), "\n";
EOF
cp "$DOC/info.php" "$DOC/index.php"
# A site's own .htaccess, AllowOverride All — the reason rexenv ships Apache.
printf 'RewriteEngine On\nRewriteRule ^from-htaccess$ target.html [L]\n' > "$DOC/.htaccess"
# A stray .htaccess ABOVE the docroot must be ignored (the <Directory "/"> stanza;
# the Dell's C:\.htaccess answered every request with 500).
printf 'RewriteEngine On\nThis is not a directive\n' > "$G/.htaccess"

CONF="$G/apache-gate.rex.conf"
{
  echo "ServerRoot \"$ROOT\""
  echo "Listen 127.0.0.1:$PORT"
  for m in "${MODS[@]}"; do echo "LoadModule ${m%%:*}_module \"lib/httpd/modules/${m#*:}\""; done
  cat <<EOF
ServerName gate.rex
PidFile "$RUN/apache-gate.rex.pid"
DefaultRuntimeDir "$RUN"
ErrorLog "$LOGS/apache-gate.rex-error.log"
LogLevel warn
TypesConfig "$ROOT/.bottle/etc/httpd/mime.types"
DocumentRoot "$DOC"
DirectoryIndex index.php index.html
<Directory "/">
	AllowOverride None
	Require all denied
</Directory>
<Directory "$DOC">
	Options FollowSymLinks
	AllowOverride All
	Require all granted
</Directory>
<FilesMatch "\.php$">
	SetHandler "proxy:fcgi://127.0.0.1:$FPM_PORT"
</FilesMatch>
SetEnv REXENV_GATE "set-env-ok"
RewriteEngine On
RewriteCond %{HTTP:X-Forwarded-Proto} =https
RewriteRule .* - [E=HTTPS:on]
RewriteRule "(^|/)\.(?!well-known(/|$))" - [R=404,L]
FallbackResource /index.php
EOF
} > "$CONF"

T="$("$ROOT/bin/httpd" -t -f "$CONF" 2>&1)" || { echo "$T"; fail "httpd -t failed"; }
echo "  httpd -t: $T"
has 'Syntax OK' "$T" || fail "httpd -t did not say Syntax OK"
LOADED="$("$ROOT/bin/httpd" -M -f "$CONF" 2>&1)"
for m in "${MODS[@]}"; do has " ${m%%:*}_module \(shared\)" "$LOADED" || { echo "$LOADED"; fail "${m%%:*} not loaded"; }; done
VV="$("$ROOT/bin/httpd" -V -f "$CONF")"
has "Server version: Apache/$V " "$VV" || fail "httpd -V does not say $V"
has 'Server MPM: +event' "$VV" || fail "MPM is not event"

say "a real server"
"$ROOT/bin/httpd" -f "$CONF" -DFOREGROUND > "$LOGS/stdout.log" 2>&1 &
HPID=$!
stop() { kill -TERM "$HPID" "$FPMPID" 2>/dev/null || true; wait "$HPID" 2>/dev/null || true; wait "$FPMPID" 2>/dev/null || true; }
bad() { echo "--- error log"; cat "$LOGS"/*.log 2>/dev/null | tail -30; echo "--- fpm"; tail -20 "$FPMDIR/fpm.log" 2>/dev/null; stop; fail "$*"; }
wait_tcp "$PORT" 15 || bad "httpd did not listen on $PORT"

expect() {   # <name> <want code> <want body regex> <path> [header]
  local r code body
  r="$(http_get "$PORT" "$4" "${5:-}")"
  code="$(head -1 <<<"$r")"; body="$(tail -n +2 <<<"$r")"
  [ "$code" = "$2" ] || { echo "$body" | head -20; bad "$1: $4 returned $code, want $2"; }
  [ -z "$3" ] || has "$3" "$body" || { echo "$body" | head -20; bad "$1: $4 body does not match /$3/"; }
  printf '  %-22s %s → %s\n' "$1" "$4" "$code"
}
expect "static index"        200 '^<h1>static ok</h1>$'          /index.html
expect "static file"         200 '^plain text$'                  /a.txt
expect ".htaccess rewrite"   200 'rewritten by htaccess'         /from-htaccess
expect "dotfile deny"        404 ''                              /.env
expect "php via fcgi"        200 "^script=$DOC/info.php$"        /info.php
expect "SetEnv to php"       200 '^env=set-env-ok$'              /info.php
expect "HTTPS mapped"        200 '^https=on$'                    /info.php 'X-Forwarded-Proto: https'
expect "FallbackResource"    200 '^uri=/no/such/pretty-url$'     /no/such/pretty-url
expect "DirectoryIndex php"  200 '^php ok$'                      /
kill -0 "$HPID" 2>/dev/null || bad "httpd died during the probes"
stop

# Nothing it wrote may point at the build machine's prefix — a compiled-in path
# the conf did not override would show up here as a failed open.
if grep -h -- '/opt/rexenv' "$LOGS"/*.log; then fail "httpd reached for a compiled-in /opt/rexenv path"; fi
if grep -hE '\[(error|crit|alert|emerg)\]|\[[a-z_]+:(error|crit|alert|emerg)\]' "$LOGS"/*.log; then fail "error-level lines in the log"; fi
echo "PASS httpd $V"
