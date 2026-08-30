Static PHP 7.4.33 for macOS — `php` (cli) and `php-fpm`, arm64 and x86_64.

Built by `.github/workflows/php-74.yml` from `shivammathur/php-src-backports@5a576d8`
(mirrored in this release as `php-src-backports-5a576d8eb53e.tar.gz`), via
static-php-cli 2.8.5.

**macOS floor: the artifacts carry `LC_BUILD_VERSION minos 12.0`** — static-php-cli's
own default — measured on BOTH slices with `vtool -show-build`, so 12.0 is the floor
anything linking or shipping these binaries inherits. Earlier builds' notes said
`MACOSX_DEPLOYMENT_TARGET=11.0` "asserted per artifact": the number was wrong (the
bytes said 12.0 all along) and the assertion did not exist anywhere in the workflow.
A wrong floor is not cosmetic — it is inherited by whoever ships these, and it is
discovered by their users, on the machines that cannot run it.

**This tag is immutable and will never be re-uploaded.** A rebuild is the next build
number. See the README for why that matters to anything pinning these hashes.

Verify origin:

```sh
gh attestation verify php-7.4.33-cli-macos-aarch64.tar.gz --repo rexenv/runtimes
```

PHP 7.4 has been end-of-life since 28 Nov 2022.

**Known gaps in this build, stated rather than discovered:**

- **No `opcache`** — static-php-cli cannot build it for 7.4 (its static-opcache
  patch series starts at 8.0).
- **OpenSSL 3's legacy provider is off**, so `openssl_encrypt` with `bf-cbc`,
  `rc4` or `des-*` fails. True of the 8.x static builds too — not a 7.4
  regression.
- **Five extensions the 8.x builds have and this one does not**, measured rather than
  estimated (`php -m`, build 6 arm64: 57 modules, against 62 on a static 8.3.32 — the
  difference is exactly these five, and nothing else is missing):
  `Zend OPcache`, `random`, `opentelemetry`, `protobuf`, `swoole`. Each has a reason
  and none is an omission: `random` is a PHP **8.2 core** extension and cannot exist in
  7.4; opcache is the patch-series floor above; static-php-cli guards opentelemetry and
  protobuf on PHP >= 8.0; modern swoole releases dropped 7.4. **Nothing here is "in
  progress"** — earlier notes said the set was narrower and widening, which stopped
  being true at build 6, the parity build.
- **PCRE JIT is compiled out** (`--without-pcre-jit`). 7.4 bundles PCRE2 10.35 (May
  2020), too old for Apple Silicon JIT — Composer died on `Allocation of JIT memory
  failed` until the flag went in. Regex throughput is therefore lower than the 8.x
  builds. Fixing it means building 7.4 against a newer external PCRE2, which is not
  worth it for a version nobody runs for speed.
Licences for PHP and every statically linked dependency ship in `licenses-<arch>.tar.gz`.
