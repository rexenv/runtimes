#!/bin/bash
# Build a static-ish nginx for macOS with a deployment target rexenv can ship.
#
#   scripts/build-nginx.sh <arch: aarch64|x86_64> <out-dir>
#
# ─── Why this exists ─────────────────────────────────────────────────────────
#
# rexenv pinned jirutka/nginx-binaries, and on 30 Aug 2026 a check that compares
# the app's stated macOS floor against what its own binaries DECLARE found this:
#
#   nginx-1.30.3-arm64-darwin    minos 15.0
#   nginx-1.30.3-x86_64-darwin   minos 26.0     ← app states 15.0
#
# Every Intel user between macOS 15 and 26 was installing an app whose SHARED WEB
# SERVER may refuse to load, and nginx is not an optional engine — it is the
# request path for every default site. The survey made it worse: upstream rebuilt
# on macOS-26 runners, so x86_64 is 26.0 for every version from 1.26.3 up, and
# 1.28.3 / 1.30.4 / 1.31.4 are 26.0 on arm64 too. The next routine bump would have
# taken Apple Silicon with it. Only ≤1.25.5 x86_64 is still 12.0, and pinning a
# 2024 mainline nginx to dodge a deployment target is not a plan.
#
# So rexenv builds its own, the same way it builds PHP 7.4 and for the same
# reason: when the floor an artifact declares is load-bearing for your users, the
# only way to control it is to set it yourself.
#
# ─── What it takes, which is much less than PHP ──────────────────────────────
#
# rexenv's generated config uses: rewrite + map (PCRE), fastcgi, log_format,
# types, sendfile, and the proxy/uwsgi/scgi temp-path directives. It does NOT
# terminate TLS — Caddy does that at the edge — and never gzips. So:
#
#   * no OpenSSL (the ssl module is opt-in; we simply never ask for it),
#   * no zlib (--without-http_gzip_module),
#   * PCRE2 is the ONLY dependency, and nginx statically links it from source.
#
# The result links nothing but /usr/lib/libSystem.B.dylib — which means rexenv's
# `relink_to_system_libs` has nothing to do for it, unlike the Homebrew-bottle
# binaries that made that function necessary.
set -euo pipefail

ARCH="${1:?arch required: aarch64|x86_64}"
OUT="${2:?output dir required}"

NGINX_VERSION="${NGINX_VERSION:-1.30.4}"
PCRE2_VERSION="${PCRE2_VERSION:-10.47}"

# 12.0, matching the PHP 7.4 build. NOT 15.0 (today's app floor): the point of
# owning the build is that the floor becomes a decision instead of an accident,
# and a binary that can run on 12 costs nothing to produce. What the app STATES
# stays a separate, deliberate number in tauri.conf.json.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"

case "$ARCH" in
  aarch64) MAC_ARCH="arm64"  ;;
  x86_64)  MAC_ARCH="x86_64" ;;
  *) echo "::error::unknown arch $ARCH"; exit 1 ;;
esac

say() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

say "fetch"
curl -fsSLO "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
curl -fsSLO "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz"
# Mirrored into the release beside the binary: "which source built this" must be
# answerable from the release page alone, the same rule the PHP 7.4 build follows.
mkdir -p "$OUT"
cp "nginx-${NGINX_VERSION}.tar.gz" "pcre2-${PCRE2_VERSION}.tar.gz" "$OUT/"
tar xzf "nginx-${NGINX_VERSION}.tar.gz"
tar xzf "pcre2-${PCRE2_VERSION}.tar.gz"

say "configure"
cd "nginx-${NGINX_VERSION}"
# --with-pcre=<dir> makes nginx BUILD pcre2 into itself, so there is no dylib to
# relink and no bottle to bundle. --with-pcre-jit is safe here (pcre2 10.47 has
# working Apple Silicon JIT; PHP 7.4's ancient bundled 10.35 is why THAT build
# has JIT off — a different library, a different decision).
./configure \
  --prefix=/opt/rexenv/nginx \
  --with-pcre="../pcre2-${PCRE2_VERSION}" \
  --with-pcre-jit \
  --without-http_gzip_module \
  --with-cc-opt="-arch ${MAC_ARCH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}" \
  --with-ld-opt="-arch ${MAC_ARCH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"

say "build"
time make -j"$(sysctl -n hw.ncpu)"
BIN=objs/nginx

# ─── Gates. Every one of these has a specific way of being wrong. ────────────
say "gates"

# 1. It is the version we think it is, and it runs.
"./$BIN" -v
"./$BIN" -v 2>&1 | grep -q "nginx/${NGINX_VERSION}" || { echo "::error::wrong nginx version"; exit 1; }

# 2. THE reason this build exists. A deployment target that silently reverts to
#    the SDK's default is the whole defect being fixed, so it is asserted per
#    artifact rather than trusted to the environment variable.
MINOS="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
[ "$MINOS" = "$MACOSX_DEPLOYMENT_TARGET" ] \
  || { echo "::error::minos=$MINOS want $MACOSX_DEPLOYMENT_TARGET — the floor is the point of this build"; exit 1; }
echo "minos: $MINOS"

# 3. Right arch. `file(1)` says arm64 where our artifact names say aarch64, so
#    compare against the TOOLCHAIN spelling — the PHP build failed a good binary
#    on exactly this once.
file "$BIN" | grep -q "$MAC_ARCH" || { echo "::error::not $MAC_ARCH: $(file "$BIN")"; exit 1; }

# 4. The dylib closure rexenv's relink_to_system_libs accepts. This build should
#    need NOTHING but libSystem — if a dependency ever creeps in, it lands on a
#    user's machine as a resolve-time hard error long after this build.
if otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/)' | grep .; then
  echo "::error::links a non-system dylib"; exit 1
fi

# 5. No TLS compiled in, deliberately. Caddy terminates TLS at the edge; an nginx
#    that could listen on 443 invites a config that does, and rexenv's whole
#    request topology says the edge is the only thing that ever holds a cert.
if "./$BIN" -V 2>&1 | grep -q -- "--with-http_ssl_module"; then
  echo "::error::built WITH the ssl module — the edge owns TLS in rexenv (see ARCHITECTURE §topology)"; exit 1
fi
"./$BIN" -V 2>&1 | grep -q -- "--with-pcre-jit" || { echo "::error::pcre jit missing"; exit 1; }

# 6. A REXENV-SHAPED CONFIG, not `-t` on the default one. The modules that matter
#    are the ones the generated config names: map, rewrite, fastcgi, log_format,
#    and the four temp_path directives. A module missing from this build shows up
#    as "unknown directive" on a user's first site, not here, unless we ask.
P="$WORK/probe"
mkdir -p "$P/logs" "$P/temp" "$P/docroot"
echo "<h1>ok</h1>" > "$P/docroot/index.html"
cat > "$P/nginx.conf" <<EOF
worker_processes 1;
daemon off;
pid "$P/logs/nginx.pid";
error_log "$P/logs/error.log";
events { worker_connections 256; }
http {
	log_format rexenv '\$host \$time_iso8601 \$body_bytes_sent';
	access_log "$P/logs/access.log" rexenv;
	types { text/html html htm; text/css css; application/javascript js; }
	default_type application/octet-stream;
	sendfile on;
	client_body_temp_path "$P/temp/client_body";
	fastcgi_temp_path "$P/temp/fastcgi";
	proxy_temp_path "$P/temp/proxy";
	uwsgi_temp_path "$P/temp/uwsgi";
	scgi_temp_path "$P/temp/scgi";
	map \$http_x_forwarded_proto \$rexenv_https { default ''; https on; }
	server {
		listen 127.0.0.1:18099;
		server_name probe.rex *.probe.rex;
		absolute_redirect off;
		root "$P/docroot";
		index index.php index.html;
		location ~ /\.(?!well-known(/|\$)) { return 404; }
		location ~ \.php\$ {
			fastcgi_pass 127.0.0.1:9783;
			fastcgi_index index.php;
			fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
			fastcgi_param HTTPS \$rexenv_https;
		}
	}
}
EOF
"./$BIN" -t -p "$P" -c "$P/nginx.conf"

# 7. And it must SERVE. A config test proves the directives parse; only a request
#    proves the binary works — the same distinction that makes php-fpm's
#    "starts but cannot execute a script" failure invisible to a version check.
"./$BIN" -p "$P" -c "$P/nginx.conf" &
NGPID=$!
sleep 2
code() { curl -s -o /dev/null -w '%{http_code}' -H "Host: $1" "http://127.0.0.1:18099$2"; }
STATIC="$(code probe.rex /)"
DOT="$(code probe.rex /.env)"
WILD="$(code sub.probe.rex /)"
kill "$NGPID" 2>/dev/null || true
wait "$NGPID" 2>/dev/null || true
[ "$STATIC" = "200" ] || { echo "::error::static request returned $STATIC"; exit 1; }
# The dotfile deny is a rexenv SECURITY rule (docroots carry .git/.env and a
# tunnel makes a docroot public), and it is regex-location behaviour — i.e. it
# depends on the PCRE this build links. Worth asserting in the build that
# produces that PCRE.
[ "$DOT" = "404" ] || { echo "::error::dotfile deny returned $DOT, want 404"; exit 1; }
[ "$WILD" = "200" ] || { echo "::error::wildcard server_name returned $WILD"; exit 1; }
grep -q "probe.rex" "$P/logs/access.log" || { echo "::error::log_format rexenv wrote nothing parseable"; exit 1; }
echo "served: static=$STATIC dotfile=$DOT wildcard=$WILD, access log has host lines"

# ─── Package ─────────────────────────────────────────────────────────────────
say "package"
mkdir -p "$OUT"
cp "$BIN" "$OUT/nginx-${NGINX_VERSION}-macos-${ARCH}"
( cd "$OUT" && shasum -a 256 "nginx-${NGINX_VERSION}-macos-${ARCH}" > "nginx-${NGINX_VERSION}-macos-${ARCH}.sha256" )
ls -lh "$OUT"

say "record"
echo "nginx ${NGINX_VERSION} / pcre2 ${PCRE2_VERSION} / ${ARCH} / minos ${MINOS}"
"./$BIN" -V 2>&1 | tail -2
