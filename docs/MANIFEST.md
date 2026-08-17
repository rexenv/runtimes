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

To name versions yourself and skip discovery, put them in the workflow's
`versions` input (space-separated), or pass them as arguments locally:

```sh
./scripts/publish-manifest.sh 8.3.32 8.4.24
```

Each is still validated: an argument that is not `x.y.z`, or whose minor rexenv
does not ship, is refused rather than probed.

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

## 3. The four limits the app enforces — respect them or entries are dropped

rexenv drops any entry that breaks these, silently and per-entry (one bad row must
not deny every other update). A signature failure is different: that rejects the
whole document, because it says the document is not ours.

| Limit | Why |
|---|---|
| `name` ∈ {`php`, `php-fpm`} | rexenv's resolver is name-generic, and `caddy` runs as a **root LaunchDaemon** on a user's machine. A manifest that can name a binary could name that one. |
| `https://` from `dl.static-php.dev/` or `github.com/rexenv/` | There is no scheme or host constraint anywhere on rexenv's download path, because every URL is normally a compiled-in `format!`. A manifest makes `http://attacker/` expressible. |
| `version` is a patch of a minor rexenv **already ships** | Per-minor facts — the EOL date, whether Xdebug is available, the pool port — are compiled into the app. A new MINOR arriving this way would render with no EOL date and Xdebug silently missing. |
| lowercase 64-hex `sha256` | The form the existing digest gate compares. |

Plus a **monotonic `serial`**: the app refuses any document whose serial is not
higher than the highest it has ever accepted. Without it, a host that keeps serving
an older validly-signed manifest could hold a user on a known-CVE patch forever —
the signature alone does not stop that. The script reads the published serial and
increments. **Never hand-edit it downwards**; a lower serial is a manifest nobody
can install.

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
curl -sL https://github.com/rexenv/runtimes/releases/download/manifest/manifest.json
curl -sL https://github.com/rexenv/runtimes/releases/download/manifest/manifest.json.sig
```

Those are the two URLs the app fetches. Nothing else about the release matters to it
— not the title, not the notes, not the tag's commit. The tag is **moved** on every
publish, which is safe here and nowhere else in rexenv: these bytes are trusted for
their signature, not their location. The workflow re-fetches both over the public
URL after publishing and fails if they are not the bytes it signed.

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
| `→ 8.4.24 is incomplete upstream; dropped entirely` | Only some of the four artifacts exist. Correct behaviour — re-run once upstream finishes. |
| A user's app shows no Update button after a publish | Three candidates, in order: their app's `RELEASE_PUBKEY` predates a key rotation; the published serial is not higher than one they already accepted; or their app's own pin is already ≥ the version offered. |
| `is not a patch of a minor rexenv ships` | Either a typo in an explicit version, or rexenv added a minor and `PINS` has not caught up. §5. |
