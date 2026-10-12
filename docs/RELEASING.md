# Releasing Fen

This walks you through publishing a signed, notarized `Fen.app` to the GitHub [Releases](https://github.com/zoharbabin/fen/releases) page — even if you don't do this every day.

There are two ways to release:

1. **Automatic (recommended):** push a version tag and GitHub Actions builds, signs, notarizes, and uploads the app for you.
2. **Manual:** run the build script on your own Mac.

---

## One-time setup (signing)

You need an **Apple Developer account** ($99/year). You already have one.

### 1. Create a "Developer ID Application" certificate

1. Open **Xcode → Settings → Accounts**, sign in with your Apple ID.
2. Select your team → **Manage Certificates…** → **+** → **Developer ID Application**.
3. This installs the certificate into your login Keychain.

Find its exact name (you'll need it):

```sh
security find-identity -v -p codesigning
```

Look for a line like `Developer ID Application: Your Name (ABCDE12345)`. The 10-character code in parentheses is your **Team ID**.

### 2. Create an app-specific password (for notarization)

1. Go to <https://appleid.apple.com> → **Sign-In and Security** → **App-Specific Passwords**.
2. Create one named e.g. `fen-notary` and copy the generated password.

---

## Option A — Release via GitHub Actions (recommended)

### Add repository secrets (one time)

This repo has the six signing secrets configured (`gh secret list` shows them), and every release since v0.2.0 has published automatically through this path. The seventh, `SPARKLE_PRIVATE_KEY`, is needed for in-app updates (see [Sparkle key](#sparkle-key-in-app-updates)). Skip to [Cut a release](#cut-a-release) unless you're rotating credentials or setting up a fork.

In GitHub: **Settings → Secrets and variables → Actions → New repository secret**. Add all seven:

| Secret | Value |
|--------|-------|
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Your Name (ABCDE12345)` |
| `MACOS_CERTIFICATE` | base64 of your exported certificate (see below) |
| `MACOS_CERTIFICATE_PWD` | the password you set when exporting the `.p12` |
| `APPLE_ID` | your Apple ID email |
| `APPLE_APP_PASSWORD` | the app-specific password from step 2 |
| `APPLE_TEAM_ID` | the 10-character Team ID |
| `SPARKLE_PRIVATE_KEY` | the EdDSA private key for in-app updates (see below) |

To produce `MACOS_CERTIFICATE`: in **Keychain Access**, find your *Developer ID Application* certificate, right-click → **Export…**, save as a `.p12` with a password, then convert it to base64 text:

```sh
base64 -i Certificates.p12 | pbcopy   # now paste into the secret
```

### Sparkle key (in-app updates)

**Fen > Check for Updates…** installs a build only if its zip carries an EdDSA signature made with the private key that matches `SUPublicEDKey` in `macOS/Info.plist`. A tagged release fails at "Build appcast" without the secret, so a release can't ship without an appcast.

Create the key once on your Mac (Sparkle's `generate_keys` is in the [Sparkle release](https://github.com/sparkle-project/Sparkle/releases) and in `.build/artifacts/sparkle/Sparkle/bin` after `swift package resolve`). It stores the private key in your login Keychain and prints the public key for `Info.plist`.

Put the private key in the secret, then delete the exported file:

```sh
generate_keys -x sparkle_private_key          # writes the key to a file
gh secret set SPARKLE_PRIVATE_KEY < sparkle_private_key
rm sparkle_private_key
```

Keep a backup of the key in a password manager. If you lose it, installed copies of Fen can't verify any future update, and everyone has to download a new build by hand. If it leaks, replace the key and `SUPublicEDKey` in one release, signed with the old key, before you revoke anything.

### Cut a release

```sh
git tag v0.1.0
git push origin v0.1.0
```

The **Release** workflow runs automatically: it tests, builds, signs, notarizes, staples, zips, signs the zip for Sparkle, and creates a GitHub Release with `Fen.app.zip` and `appcast.xml` attached.

> Skip the secrets and the workflow still runs, but it produces an **unsigned** build — fine for testing, though people will see a Gatekeeper warning.

### Write the release notes by hand

The workflow's `generate_release_notes: true` is a fallback, not the real changelog. This repo merges every change through a PR, so GitHub can generate a "What's Changed" list of merged PR titles — but that list doesn't match this repo's own format and skips the *why* behind each change, so treat it as a draft to replace, not a done release. (If a release ever lands with no merged PRs since the last tag, GitHub instead publishes a bare `**Full Changelog**: vX...vY` line with no content — same rule applies: unfinished, not done.)

```sh
gh release view v0.1.0 --json body -q .body
```

If it's just the compare link, write real notes and replace them:

```sh
gh release edit v0.1.0 --notes-file notes.md
```

Match the format every release since v0.2.6 has used — `## Added` / `## Fixed` / `## Changed` / `## Testing` / `## Docs` sections (only the ones that apply), each bullet leading with what a user or contributor would notice, followed by the *why*. End with the same `**Full Changelog**: vX...vY` link the workflow would have generated on its own. Read a recent release (e.g. `gh release view v0.2.10 --json body -q .body`) for the pattern before writing a new one.

---

## Option B — Build & release manually on your Mac

`./scripts/build-app.sh` needs `xcodegen` on your `PATH` (`brew install xcodegen`) to build the `FenQuickLook` Quick Look extension via the Xcode project it generates from `project.yml` — SwiftPM has no app-extension concept, so that part can't come from `swift build` alone. It **auto-detects** your "Developer ID Application" certificate and signs with it — no `SIGN_IDENTITY` needed for a signed local build. To also notarize (required before others can run it without warnings):

```sh
# 1. Store notary credentials once (creates a keychain profile)
xcrun notarytool store-credentials fen-notary \
  --apple-id "you@example.com" \
  --team-id "ABCDE12345" \
  --password "your-app-specific-password"

# 2. Build, sign, and notarize
SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)" \
NOTARY_PROFILE="fen-notary" \
./scripts/build-app.sh

# 3. Zip and upload to a GitHub release
cd dist
ditto -c -k --keepParent "Fen.app" "Fen.app.zip"
gh release create v0.1.0 Fen.app.zip --generate-notes
```

---

## Update the Homebrew cask

`Casks/fen.rb` installs the zip from a release. After you publish a release, point the cask at it and open a PR:

```sh
scripts/update-cask.sh v0.1.0   # sets version and sha256, refuses a build that isn't notarized
brew style Casks/fen.rb
```

CI checks the cask's style and that its sha256 matches the published zip. `master` is protected, so the workflow can't push the change for you. Until the PR merges, `brew upgrade` still installs the previous release.

We don't submit to the official `homebrew-cask` repo. Users tap this repo (see [README](../README.md#install)).

---

## Versioning

The marketing version comes from the git tag (e.g. tag `v0.1.0` → version `0.1.0`). The build number is the commit count. Without a tag, the version is `0.0.0-dev`.

The landing page's JSON-LD `softwareVersion` follows the same tag automatically: `site/index.html` carries a `__FEN_LATEST_VERSION__` placeholder, and `.github/workflows/pages.yml` substitutes in the latest release tag at deploy time (via `git describe --tags`), into a deploy-only copy of `site/` — never into the tracked file. `release.yml` dispatches `pages.yml` directly after a successful publish (via `gh workflow run pages.yml`), so cutting a release redeploys the page even when nothing under `site/` changed — a plain `release: { types: [published] }` trigger on `pages.yml` wouldn't work here, since a release published by the workflow's own `GITHUB_TOKEN` can't cascade-trigger another workflow's `release` event (GitHub Actions only exempts `workflow_dispatch`/`repository_dispatch` from that anti-recursion safeguard).

## Verifying a build

```sh
codesign --verify --deep --strict --verbose=2 dist/Fen.app
spctl --assess --type execute --verbose dist/Fen.app   # should say "accepted"
xcrun stapler validate dist/Fen.app                    # notarization ticket
```
