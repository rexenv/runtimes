# The PHP update manifest

**A new PHP patch is out and rexenv users should be offered it. Do this:**

> **Actions → “Publish PHP update manifest” → Run workflow.**
> Leave `dry_run` **on** for the first run, read the log, then run it again with
> `dry_run` off.

That is the whole job. It finds every patch upstream has published since rexenv's
pins, downloads and hashes all four artifacts for each, signs the document, verifies
its own signature, and replaces the `manifest` release. There is nothing to build.

Same thing from a laptop, if you would rather:

```sh
./scripts/publish-manifest.sh --dry-run    # discover, hash, sign — publish nothing
./scripts/publish-manifest.sh              # then publish
```

Both run the identical script. The workflow just supplies the key from a secret.

You will be told when it is worth doing — see [§2.1](#21-the-daily-check).

---

## 1. What this actually does, and why it is not a build

rexenv ships a **checksum pin** for every binary it runs, compiled into the app.
That is not bookkeeping: it is the reason compromising a download host cannot reach
an installed user. Eight independent upstreams each face a separately compiled-in
digest, and a mismatch fails the download closed.

An in-app PHP update needs a digest for bytes the app was built **before**. So the
trust anchor has to move — and it moves exactly one step: from a `const` in the
binary to **a signed document whose public key is a `const` in the binary**. It
never moves to TLS. rexenv's digest check verifies bytes against *whoever supplied
the digest*, so an attacker-chosen URL paired with an attacker-chosen hash matches
perfectly and passes in silence. The signature is the only thing standing there.

For **8.x** the artifacts are static-php.dev's portable builds, so this repo does
not compile anything. What a new version needs is a digest somebody vouched for.

For **7.4** the artifacts are ours (`scripts/build-php74.sh`, `.github/workflows/php-74.yml`)
because nobody publishes a portable 7.4. It is deliberately skipped by discovery.

## 2. Adding support for new PHP patches

Discovery probes upward from each minor's pin until **two consecutive misses** —
two, not one, because upstream has skipped a patch number before and stopping at
the first 404 would hide everything after it.

To name versions yourself — for the one case discovery cannot serve, "upstream
published it but my probe cannot see it" — put them in the workflow's `versions`
input (space-separated), or pass them as arguments locally:

```sh
./scripts/publish-manifest.sh 8.3.32 8.4.24
```

Each is still validated: an argument that is not `x.y.z`, or whose minor rexenv
does not ship, is refused rather than probed.

**They are ADDED to discovery, not substituted for it.** This used to replace it,
which was a truncation bug rather than a preference: the manifest is a
REPLACEMENT document, so `publish-manifest.sh 8.3.32` wrote a manifest containing
only 8.3.32 and silently deleted every other version from it. A user already on
8.2.32 could then no longer resolve it — a fresh install or a cache repair fails,
and the app refuses an apply for a version nothing vouches for.

### Nothing that is published may disappear

Because the document is a replacement, every publish can delete. Discovery is a
live probe of somebody else's server, so "it answered yesterday and 404s today"
is a normal Tuesday — not a decision anyone made.

So between writing the document and signing it, the script asserts that every
`name`+`version`+`arch` the **published** manifest carries is still present. If
any is missing it refuses, naming them. If a version really is gone upstream and
you mean it, say so deliberately:

```sh
REXENV_MANIFEST_ALLOW_DROP=1 ./scripts/publish-manifest.sh
```

The check is skipped on a genuine first publish (there is nothing to preserve),
which is why telling "first run" apart from "could not read the release" matters
twice.

### 2.1 The daily check

`.github/workflows/discover-php.yml` runs at 06:17 UTC and on demand. It calls the
same script in a third mode:

```sh
./scripts/publish-manifest.sh --discover    # probe upstream, print what is new, touch nothing
```

`--discover` needs **no signing key** — the key check is skipped entirely in that
mode — so the daily workflow runs with `contents: read` and `issues: write`, cannot
reach the `manifest-signing` environment, and could not publish if it wanted to.
That separation is the design: discovery is a fact about upstream and can be
automated, while *signing* is a judgement about what every installed rexenv will be
told to download and run, and stays a decision a human makes and GitHub logs.

It prints matching versions to **stdout, one per line, and nothing else** — all the
progress chatter goes to stderr — so an empty stdout means "nothing to report" and
the workflow stays silent.

**It subtracts what the published manifest already lists.** Without that it would
file the same issue every morning: `PINS` are fixed floors and do not move when you
publish, so a patch that has shipped is still "newer than the pin" tomorrow.

That subtraction is **only** in `--discover`. It must never filter the publish path,
and the reason is worth stating plainly: the manifest is a **replacement** document,
not an accumulating one — each publish writes exactly the versions that run
discovered. Skip an already-published version there and the next publish silently
drops it from the document, putting those users back on the patch compiled into
their app.

One issue is kept, labelled `php-update`, with a `<!-- discovered: … -->` marker in
its body. Same set as yesterday → the run stays quiet; a changed set → the body is
rewritten and a comment notes what moved. Close the issue once you have published.

GitHub disables scheduled workflows after 60 days without repository activity. If
this goes quiet for a long stretch, check that the schedule is still enabled rather
than assuming upstream has been idle.

### "Nothing newer than the pins is published upstream"

The normal state, not a failure. static-php.dev rebuilds after each upstream
release and trails php.net by days or weeks — measured 17 days on 16 Aug 2026,
when php.net listed 8.4.24 and 8.5.9 while the newest portable builds were 8.4.23
and 8.5.8, exactly rexenv's pins. Re-run later.

This is also why rexenv's Settings row says a patch **exists** rather than
"update available", and why it only shows an Update button for versions THIS
manifest carries. Two different facts, two different fields — and the app hides
the "exists" chip once the button names the same version.

### A version published for only some arches

Dropped whole, and the script says so. rexenv resolves cli **and** fpm on
whichever arch the user has; a half-published version would offer an update that
works on one Mac and fails on another.

**The app enforces this itself** (`VersionCatalog::newer_than`) rather than
trusting this script to have got it right. That is deliberate: a manifest is
data, and data is exactly the thing that must not be assumed to have been
generated correctly. If you ever hand-edit a manifest and a version silently
stops being offered, this is why — count the artifacts.

## 2.2 Adminer rides the same manifest

rexenv's database console is Adminer, a single `.php` file pinned by hash like
everything else — and it is the **second family** in this document. Nothing extra
to run: the same command discovers and publishes both.

Adminer discovery is a **listing, not a probe**. PHP is walked upward because
static-php.dev publishes no index; Adminer's releases API is authoritative, and a
probe would be both slower and wrong at every track boundary — the pin is 5.4.2
and the newest is 6.0.1, which no upward-from-the-pin walk with a miss budget
would ever reach.

Two things about the listing are load-bearing and non-obvious:

- **`.draft == false`.** This script runs with `GH_TOKEN` in CI, so drafts ARE
  visible to it — and a draft's asset URL 404s for everyone else. Publishing one
  puts an entry in the manifest that no user can resolve.
- **`arch: "any"`.** One file, the same bytes on every machine. rexenv refuses a
  per-arch Adminer row outright (`Family::Adminer::arch_ok`), because two rows for
  one file is a fiction stated twice — and it would make a HALF-published Adminer
  version structurally legal, which is the failure the completeness rule exists
  for.

### `ADMINER_MAX_MAJOR` — a ceiling that is evidence

`ADMINER_PIN` and `ADMINER_MAX_MAJOR` are separate variables, never `PINS` rows:
Adminer has no minor track the way PHP does. The ceiling exists because rexenv's
controls for the database console — the passwordless-login **loopback gate**, the
frame-ancestors bound, the `X-Frame-Options` removal — live inside **Adminer's own
plugin API**. rexenv's wrapper subclasses `\Adminer\Adminer` and overrides
`login`/`loginForm`/`headers`/`csp`. A major bump is what may move those hooks,
and it would do it silently, with the console still serving.

`ADMINER_MAX_MAJOR` here must equal `updates::ADMINER_MAX_MAJOR` in the app, and
**both are evidence**: the app's number is the newest major whose plugin API has
actually been run against the wrapper. Raising it here without raising it there
publishes entries every installed app silently drops. Run rexenv's
`scripts/check-php-pins.sh` — it compares both sides and exits non-zero on a
ceiling mismatch.

To raise it: in the app repo, `cargo run --example adminer_check` against the new
major, then raise `updates::ADMINER_MAX_MAJOR`, ship a release, and only then
raise it here. The app also probes each candidate at APPLY time and refuses one
that no longer binds, so the ceiling is the structural half of a two-part answer.

To name Adminer versions by hand: `./scripts/publish-manifest.sh adminer:6.0.1`.
Prefixed rather than guessed from the number — `5.4.2` is a plausible Adminer
version and a plausible typo for a PHP one, and guessing wrong publishes an entry
every app drops.

## 3. The four limits the app enforces — respect them or entries are dropped

rexenv drops any entry that breaks these, silently and per-entry (one bad row must
not deny every other update). A signature failure is different: that rejects the
whole document, because it says the document is not ours.

| Limit | Why |
|---|---|
| `name` ∈ {`php`, `php-fpm`, `adminer`} | rexenv's resolver is name-generic, and `caddy` runs as a **root LaunchDaemon** on a user's machine. A manifest that can name a binary could name that one — so it names only declared FAMILIES, and each variant states what it grants. |
| `https://` from `dl.static-php.dev/` or `github.com/rexenv/` | There is no scheme or host constraint anywhere on rexenv's download path, because every URL is normally a compiled-in `format!`. A manifest makes `http://attacker/` expressible. |
| `version` is on a track the family accepts | **PHP**: a patch of a minor rexenv already ships — per-minor facts (the EOL date, Xdebug availability, the pool port) are compiled in, so a runtime-delivered new MINOR would render with no EOL date and Xdebug silently missing. **Adminer**: a major at or below `ADMINER_MAX_MAJOR`, the newest whose plugin API has been probed against rexenv's wrapper (§2.2). |
| `arch` is the one the family carries | PHP rows are `arm64`/`x86_64`; Adminer rows are `any`. A per-arch Adminer row is dropped. |
| lowercase 64-hex `sha256` | The form the existing digest gate compares. |

Plus a **monotonic `serial`**: the app refuses any document whose serial is not
higher than the highest it has ever accepted. Without it, a host that keeps serving
an older validly-signed manifest could hold a user on a known-CVE patch forever —
the signature alone does not stop that. The script reads the published serial and
increments. **Never hand-edit it downwards**; a lower serial is a manifest nobody
can install.

### The serial is read, not assumed — and a failed read REFUSES

The nastiest failure this repo can produce is not a bad manifest, it is a *good*
one nobody can install. Publishing with the serial reset to 1 deletes the tag,
republishes, and every rexenv that already accepted a higher serial rejects the
result **permanently**, with a correctly signed document and no error anywhere.

So the script tells two states apart that used to share a branch:

| State | What happens |
|---|---|
| No `manifest.json` on the branch | Genuine first publish. Serial 1. Says so. |
| It is there and will not read | **Refuses**, non-zero, naming the reason. Retry. |
| It is there and has no readable `serial` | **Refuses**, same reason. |

`REXENV_MANIFEST_SERIAL_FLOOR=N` forces the next serial above `N`. It exists for
one case: moving the manifest to a new home, where the read cannot see what the
OLD home had published. Installs remember the highest serial they ever accepted,
and a repeated serial is accepted as a no-op and never STORED — so without the
floor, every entry added since would be lost on the next launch. Set it once
during a move; leave it unset afterwards.

It was one `gh release view && gh release download` conditional, so one flaky
call landed in the "first run ever" branch. There is also a belt-and-braces check
before signing: serial 1 on a repo that already has the release is refused.

And the app keeps its **compiled-in pins as a floor**. A manifest can only ADD
versions or move a minor forward. It can never point a version the app already
pins at different bytes, and it can never move a user *below* the patch their app
ships.

## 4. The key

One ed25519 private key signs every manifest. It lives in **two** places, and they
are the same key:

| Where | Used by |
|---|---|
| `manifest-signing` **Environment** secret `REXENV_MANIFEST_KEY` | the workflow |
| `~/.rexenv/manifest-key.pem`, mode `0600` | a maintainer publishing locally |

Be clear-eyed about what it is worth: whoever holds it can run code as the user on
every machine that trusts it, and those machines have a locally-trusted CA whose
private key is readable by anything running as that user. **It is the most valuable
secret in the project** — it outranks the app signing identity, which does not exist
yet.

Which is why it is an **Environment** secret and not a repository secret. A repo
secret is readable by any workflow on any branch, so a single merged PR exfiltrates
it. An Environment with **required reviewers** means reading the key needs a human
approval that GitHub logs, and the publish workflow is `workflow_dispatch`-only.
Set that up once:

> Settings → Environments → **New environment** → `manifest-signing`
> → tick **Required reviewers**, add yourself
> → **Add environment secret** `REXENV_MANIFEST_KEY` = the full PEM.

Without the reviewer gate the Environment is decoration. With it, the honest
statement is: the key is as safe as *approving a run*, not as safe as *pushing a
commit*.

**The key never goes in an issue, a PR, a chat message, or an AI tool transcript.**
Paste it into the secret field and nowhere else.

- **Mint / rotate:** rexenv's `scripts/gen-release-key.sh`.
- **After rotating:** pin the new public half in rexenv's `src-tauri/src/core/updates.rs`
  and ship an app release. Old manifests stop verifying the moment users update —
  which is the property that makes a stolen key survivable, and the reason the
  public half is compiled in rather than fetched.
- **Order matters:** app release with the new pubkey **first**, then publish. The
  script refuses if the signing key is not the one the app pins, which is the check
  that catches a rotation done backwards.

If the key is lost, a new one plus an app release is the only path. Keep an
encrypted backup.

## 5. Keeping `PINS` honest

`scripts/publish-manifest.sh` carries a `PINS` list that must match `PHP_VERSIONS`
in rexenv's `src-tauri/src/core/binaries.rs`. It is duplicated because the app repo
is private and this one cannot read it, and a duplicated fact drifts.

```sh
./scripts/publish-manifest.sh --check-pins
```

The drift is **bounded rather than silent**: discovery starts *at* the pin, so a
stale entry can only make the script offer a patch the app already has, which the
app then filters out because it is not newer than its own pin. A stale pin costs a
wasted probe, never a wrong install.

**The one case that is not bounded** is a new MINOR. rexenv shipping 8.6 while this
list does not mention it means 8.6 gets no updates at all, silently — discovery
never probes a minor it has never heard of. So when rexenv adds a minor:

1. add `"8.6:8.6.0"` (the pin it ships) to `PINS`,
2. run with `--dry-run` and check the new minor appears in the discovery output,
3. publish.

## 6. Verifying what a user's app will see

```sh
curl -sL https://raw.githubusercontent.com/rexenv/runtimes/main/manifest.json
curl -sL https://raw.githubusercontent.com/rexenv/runtimes/main/manifest.json.sig
```

Those are the two URLs the app fetches: **files on the default branch**, updated by
a commit. Safe for the one reason everything here is safe — these bytes are trusted
for their SIGNATURE, never for their location.

`raw.githubusercontent.com` is CDN-cached for a few minutes, so a just-published
manifest takes a moment to appear. That is a freshness delay, not a correctness one:
a stale read is an older signed document, which the serial rule already handles, and
the app's check is best-effort by contract. **The publisher never reads raw** — it
reads the serial through the API, because a cached read there would REPEAT a serial,
and a repeated serial is a document every installed app refuses.

### It was a release, and that broke in production (18 Aug 2026)

Worth keeping, because the failure is not obvious and the fix is not a preference.
The publish used to delete the `manifest` release and recreate it on the same tag.
Two things went wrong in one run:

- GitHub's **immutable releases permanently burn a tag name** once a release on it
  is deleted. `release create` failed with `tag_name was used by an immutable
  release` — *after* the delete had succeeded. The URL 404'd and stayed 404'ing;
  deleting the git ref did not help, and a repository ruleset then refused to
  recreate it. The name is gone for good.
- Independently, **delete-then-create is an availability hole by construction**.
  Between the two calls the manifest does not exist, and every app checking in that
  window sees "couldn't check".

A commit is atomic and has neither problem, and it gains what a moved tag
deliberately destroyed: git keeps every manifest ever published, so "what was
signed, and when" is answerable after the fact.

To check a signature by hand:

```sh
curl -sL .../manifest.json > m.json
curl -sL .../manifest.json.sig | xxd -r -p > m.sig
openssl pkeyutl -verify -pubin -inkey <(openssl pkey -in ~/.rexenv/manifest-key.pem -pubout) \
  -rawin -in m.json -sigfile m.sig
```

rexenv's own end-to-end check is `cargo run --example php_update_check` in the app
repo: it fetches this manifest, verifies it against the **compiled-in** key,
downloads a patch the build was never made with, runs the interpreter, and serves
FastCGI from it.

## 7. When something goes wrong

| What you see | What it means |
|---|---|
| `Nothing newer than the pins is published upstream` | Normal. static-php.dev has not built it yet. Re-run in a few days. |
| `REXENV_MANIFEST_KEY is not set` | The `manifest-signing` environment has no secret, or the run was approved against a different environment. §4. |
| `the signing key is not a readable PEM private key` | The secret is truncated, or was pasted without the `-----BEGIN`/`-----END` lines. Re-paste the whole file. |
| `our own signature does not verify — refusing to publish` | Nothing was published. The key and the openssl on the runner disagree; check the key is ed25519 (`openssl pkey -in … -text -noout`). |
| `the 'manifest' release EXISTS but manifest.json could not be downloaded` | A transient `gh`/network failure. Nothing was published, on purpose: continuing would have reset the serial and locked every installed app out of updates forever. Just re-run. |
| `serial would be 1 on a repo that already has a manifest` | The same failure caught by the second check. Same answer: re-run. |
| `REFUSING: the new manifest DROPS entries the published one carries` | Discovery no longer sees a version the published document lists — usually upstream removed or moved an asset. Nothing was published. Re-run; if it persists and you accept losing it, `REXENV_MANIFEST_ALLOW_DROP=1`. |
| `→ 8.4.24 is incomplete upstream; dropped entirely` | Only some of the four artifacts exist. Correct behaviour — re-run once upstream finishes. |
| A user's app shows no Update button after a publish | Three candidates, in order: their app's `RELEASE_PUBKEY` predates a key rotation; the published serial is not higher than one they already accepted; or their app's own pin is already ≥ the version offered. |
| `is not a patch of a minor rexenv ships` | Either a typo in an explicit version, or rexenv added a minor and `PINS` has not caught up. §5. |
