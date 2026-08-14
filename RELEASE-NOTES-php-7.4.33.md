Static PHP 7.4.33 for macOS — `php` (cli) and `php-fpm`, arm64 and x86_64.

Built by `.github/workflows/php-74.yml` from `shivammathur/php-src-backports@5a576d8`
(mirrored in this release as `php-src-backports-5a576d8eb53e.tar.gz`), via
static-php-cli 2.8.5, with `MACOSX_DEPLOYMENT_TARGET=11.0` asserted per artifact.

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
- The extension set is narrower than the 8.x builds rexenv ships. Widening it is
  in progress; the current `php -m` is authoritative.
Licences for PHP and every statically linked dependency ship in `licenses-<arch>.tar.gz`.
