# The app update manifest

**A rexenv release was just PUBLISHED on the tap. Do this:**

> **Actions → “Publish app update manifest” → Run workflow.**
> Leave `dry_run` **on** for the first run, read the log, then run it again with
> `dry_run` off.

That is the whole job. It reads the tap's latest published release, downloads the
`rexenv_<version>_universal.app.tar.gz` it carries, hashes what it downloaded,
signs a one-release descriptor, verifies its own signature, and commits
`app-manifest.json` + `.sig` to the default branch.

Same thing from a laptop:

```sh
./scripts/publish-app-manifest.sh --dry-run    # download, hash, sign — publish nothing
./scripts/publish-app-manifest.sh              # then publish
./scripts/publish-app-manifest.sh 0.6.1        # a specific version rather than the latest
```

---

## 1. The failure this is here to prevent

Publishing a rexenv release takes **two clicks in two repositories**, and only the
first one is obvious.

The tap release makes the dmg downloadable, bumps the cask, and updates the
website. It tells **not one installed rexenv** that a newer version exists. That is
this workflow's job, and until it runs every copy in the world keeps answering
“the version you are running is the newest there is”. Nothing fails. No log
anywhere records a problem. The self-update feature that shipped is simply off.

So the check belongs on the rexenv side, where the pinned key lives:

```sh
scripts/check-app-manifest.sh
```

It verifies the published descriptor against the public key compiled into that
source tree, warns when the tap is ahead of what the descriptor names, and
confirms the named asset really exists with the digest that was signed.

## 2. Why it is a second document rather than a field in `manifest.json`

`manifest.json` describes PHP and Adminer artifacts, which rexenv resolves through
its binary cache: downloaded, hashed, chmod-ed, spawned. An app bundle is none of
those. It is extracted into a staging directory beside the installed bundle and
swapped in by a platform trait, and the app then relaunches into it.

The grant is also larger, and keeping the documents apart keeps that visible.
Whoever can name a PHP tarball can run native code as the user. Whoever can name an
**app bundle** gets that, plus the binary that re-execs as the DNS agent, plus the
process that enforces rexenv's own agent-access dial.

Two documents, two serials, **one key**.

## 3. Where every fact comes from

Nothing in the descriptor is typed by hand except one number:

| Field | Source |
|---|---|
| `version` | the tap's latest non-draft, non-prerelease tag |
| `url` | that release's own asset URL |
| `sha256` | the asset **downloaded and hashed in this run**, cross-checked against GitHub's immutable per-asset digest |
| `sizeBytes` | the downloaded bytes |
| `publishedAt` | the release |
| `minimumSystemVersion` | `MIN_MACOS`, declared in the script — see below |

Trusting the API's digest alone would mean signing a hash nobody in the run ever
computed, so the asset is fetched and hashed, and the two are compared.

**A draft release is invisible here, by construction:** `releases/latest` excludes
drafts and prereleases. That is what makes rexenv's human §A sign-off protect
in-app updaters for free — a release nobody published has no assets anyone can
fetch, so nothing can be offered ahead of a person's decision.

`MIN_MACOS` is the one typed fact, because it lives in rexenv's `tauri.conf.json`
in a **private** repo this workflow cannot read. It is cross-checked from the other
side: rexenv's `scripts/check-app-manifest.sh` compares it against that file and
says so when the two drift. A number restated in two repos is exactly the shape
that goes stale — the cask's macOS floor did, for four releases — so it is checked
rather than remembered.

## 4. What the script refuses to publish

Each of these is a real failure mode that would otherwise land on a user as a
broken update, or as silence:

- **A key that is not the one shipped builds trust.** `EXPECTED_PUBKEY` pins the
  public half rexenv compiles in. A wrong key signs perfectly well and produces a
  document every install refuses **in silence** — indistinguishable, from the
  outside, from a forgery. Checked before a byte is downloaded.
- **A version that is not plain `x.y.z`.** rexenv cannot represent a prerelease, so
  one is not offerable by design.
- **An API digest that disagrees with the downloaded bytes.**
- **An archive whose first entry is not `rexenv.app/`.** The extractor strips
  exactly one leading component; any other shape installs a broken bundle.
- **A URL outside the `releases/download/` prefixes rexenv allows.** Otherwise the
  descriptor would be signed, valid, and refused by every install.
- **A signature that does not verify against its own key.**

## 5. The serial, and why publishing is a commit

The serial is read from the currently published document and incremented. rexenv
refuses any descriptor whose serial is not greater than the one it last accepted,
which is what makes a replayed older document a non-event.

Because it is read-then-incremented, the workflow takes a `concurrency` group of
its own: two runs at once would compute the same next serial, and the second would
publish a document every app refuses as a replay.

Publishing is a **commit on the default branch**, not a release. A moved release
tag broke this repo's PHP manifest in production on 18 August 2026 — GitHub burns a
tag name once an immutable release on it is deleted, and delete-then-create leaves
a window with no document at all. The app's descriptor URL is compiled into every
shipped build, so it must be a path that never moves.

## 6. The key

The **same** ed25519 key as the PHP manifest — see
[MANIFEST.md §4](MANIFEST.md#4-the-key) for where it lives, the reviewer-gated
environment, and rotation. The honest cost of one key is that a compromise takes
PHP, Adminer and the app together. Rotation order is the same and matters more
here: **ship an app release carrying the new public half first**, then update
`EXPECTED_PUBKEY` in both publishers, then publish.
