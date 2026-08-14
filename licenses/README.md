# Licences

`PHP-3.01.txt` is PHP's own licence, taken from `php/php-src` at the `PHP-7.4.33`
tag. It ships in every release.

The licences of the **statically linked dependencies** are not kept here. They are
collected by `scripts/build-php74.sh` from the sources static-php-cli actually
downloaded during the build, and published as `licenses-<arch>.tar.gz` in the
release beside the binaries.

That is deliberate. A checked-in list would describe the extension set as it was
the day somebody wrote it, and the set is exactly the thing that changes. The
generated one is produced by the same run that produced the bytes, so it cannot
describe a different build. A dependency with no discoverable licence file raises
a build warning naming it, rather than being quietly omitted.
