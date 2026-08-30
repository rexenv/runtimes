nginx for macOS, built by rexenv — `nginx` as a single per-arch binary, arm64 and x86_64.

Built by `.github/workflows/nginx.yml` from the nginx.org release and PCRE2, both
mirrored in this release beside the binaries so "which source built this" is
answerable from this page alone.

**macOS floor: `MACOSX_DEPLOYMENT_TARGET=12.0`, asserted per artifact.**
`scripts/build-nginx.sh` fails the build unless each binary's `LC_BUILD_VERSION
minos` equals it.

**Why this build exists.** Upstream's darwin binaries are rebuilt on macOS-26
runners and declare `minos 26.0` — on x86_64 for every version from 1.26.3 up, and
on arm64 too from 1.28.3. rexenv states a floor of macOS 15, so an Intel user
between 15 and 26 was installing an app whose **shared web server** may refuse to
load, and nginx is not an optional engine there: it is the request path for every
default site. Found 30 Aug 2026 by a check that compares a stated floor against
what the binaries themselves declare, per slice.

**This tag is immutable and will never be re-uploaded.** A rebuild is the next
build number. See the README for why that matters to anything pinning these hashes.

Verify origin:

```sh
gh attestation verify nginx-<version>-macos-aarch64 --repo rexenv/runtimes
```

**What is in it, and deliberately not in it:**

- **No TLS.** The ssl module is never asked for, so this nginx cannot terminate
  HTTPS. In rexenv the edge (Caddy) holds every certificate; a web server that
  could listen on 443 invites a config that does.
- **No gzip** (`--without-http_gzip_module`), which is also why zlib is absent.
- **PCRE2 is built in from source** (`--with-pcre=<dir> --with-pcre-jit`), so the
  regex locations and `map` blocks rexenv generates work with no external library.
- **The dylib closure is `/usr/lib/libSystem.B.dylib` and nothing else** — asserted
  in the build. Anything outside `/usr/lib` + `/System` would become a hard error
  on a user's machine long after this build.

Gated before publishing: the version it claims, the deployment target, the arch,
the dylib closure, the absence of the ssl module, a **rexenv-shaped config**
(`map`, `log_format`, fastcgi, the four temp paths, the dotfile-deny regex) and a
real request against a running server — static 200, `/.env` 404, wildcard host 200,
and access-log lines in rexenv's own format.
