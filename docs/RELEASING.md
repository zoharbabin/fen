# Releasing Fen

This page shows you how to publish a signed, notarized `Fen.app` to the GitHub [Releases](https://github.com/zoharbabin/fen/releases) page. There are two ways:

| Way | Use it when |
|---|---|
| [Automatic](#option-a-release-with-github-actions-recommended) | Normal releases. Push a version tag and GitHub Actions does the rest. |
| [Manual](#option-b-build-and-release-on-your-mac) | CI is down, or you're testing a signed build locally. |

## One-time setup (signing)

You need an Apple Developer account.

### Create a Developer ID Application certificate

1. Open **Xcode → Settings → Accounts** and sign in with your Apple ID.
2. Select your team, choose **Manage Certificates…**, click **+**, then pick **Developer ID Application**. Xcode installs the certificate in your login Keychain.
3. Find its exact name:

```sh
security find-identity -v -p codesigning
```

Look for `Developer ID Application: Your Name (ABCDE12345)`. The 10-character code in parentheses is your Team ID.

### Create an app-specific password (for notarization)

1. Go to <https://appleid.apple.com> and open **Sign-In and Security → App-Specific Passwords**.
2. Create one (for example `fen-notary`) and copy it.

## Option A: release with GitHub Actions (recommended)

### Repository secrets

`.github/workflows/release.yml` reads seven secrets. `gh secret list` shows which ones this repo has. Skip this section unless you're rotating credentials or setting up a fork.

Add them under **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|---|---|
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Your Name (ABCDE12345)` |
| `MACOS_CERTIFICATE` | Base64 of your exported `.p12` certificate (see below) |
| `MACOS_CERTIFICATE_PWD` | The password you set when exporting the `.p12` |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_APP_PASSWORD` | The app-specific password from above |
| `APPLE_TEAM_ID` | The 10-character Team ID |
| `SPARKLE_PRIVATE_KEY` | The EdDSA private key for in-app updates (see [Sparkle key](#sparkle-key-in-app-updates)) |

To make `MACOS_CERTIFICATE`: in **Keychain Access**, right-click your Developer ID Application certificate, choose **Export…**, and save a `.p12` with a password. Then convert it to base64:

```sh
base64 -i Certificates.p12 | pbcopy   # paste into the secret
```

### Sparkle key (in-app updates)

**Fen > Check for Updates…** installs a build only if its zip carries an EdDSA signature that matches `SUPublicEDKey` in `macOS/Info.plist`. A tagged release fails at "Build appcast" without the secret, so no release ships without an appcast.

Create the key once on your Mac. Sparkle's `generate_keys` is in the [Sparkle release](https://github.com/sparkle-project/Sparkle/releases) and in `.build/artifacts/sparkle/Sparkle/bin` after `swift package resolve`. It stores the private key in your login Keychain and prints the public key for `Info.plist`.

Copy the private key into the secret, then delete the exported file:

```sh
generate_keys -x sparkle_private_key          # writes the key to a file
gh secret set SPARKLE_PRIVATE_KEY < sparkle_private_key
rm sparkle_private_key
```

Back the key up in a password manager. If you lose it, installed copies of Fen can't verify any later update, and everyone has to download a new build by hand. If it leaks, ship one release that replaces both the key and `SUPublicEDKey`, signed with the old key, before you revoke anything.

### Cut a release

```sh
git tag v0.1.0
git push origin v0.1.0
```

The **Release** workflow tests, builds, signs, notarizes and staples the app (retrying if Apple's ticket service drops the connection). Then it zips the app, signs the zip for Sparkle, publishes a GitHub Release with `Fen.app.zip` and `appcast.xml`, and redeploys the landing page.

Without the signing secrets the workflow still builds and tests, but it only uploads an unsigned `Fen-app` workflow artifact. It publishes no release.

### Write the release notes by hand

The workflow sets `generate_release_notes: true` as a fallback. GitHub's list of merged PR titles skips the why behind each change and doesn't match our format. A release with only that list, or with only a bare `**Full Changelog**: vX...vY` link, isn't done.

Check the notes:

```sh
gh release view v0.1.0 --json body -q .body
```

Replace them with real notes:

```sh
gh release edit v0.1.0 --notes-file notes.md
```

Use these sections, keeping only the ones that apply: `## Added`, `## Fixed`, `## Changed`, `## Testing`, `## Docs`. Each bullet leads with what a user or contributor notices, then gives the why. End with the `**Full Changelog**: vX...vY` link. Read a recent release first, for example `gh release view v0.7.1 --json body -q .body`.

## Option B: build and release on your Mac

`./scripts/build-app.sh` needs `xcodegen` on your `PATH` (`brew install xcodegen`). It builds the `FenQuickLook` extension through the Xcode project generated from `project.yml`, because SwiftPM can't build app extensions. The script auto-detects your Developer ID Application certificate and signs with it. To also notarize, which others need to run the app without warnings:

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

# 3. Zip it
cd dist
ditto -c -k --keepParent "Fen.app" "Fen.app.zip"

# 4. Sign the zip for Sparkle and publish both files
SPARKLE_PRIVATE_KEY="$(cat /path/to/sparkle_private_key)" \
../scripts/make-appcast.sh Fen.app.zip 0.1.0 "$BUILD" appcast.xml
gh release create v0.1.0 Fen.app.zip appcast.xml --generate-notes
```

`$BUILD` is the app's `CFBundleVersion` (the commit count). Read it with `/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Fen.app/Contents/Info.plist`. Without `appcast.xml`, **Check for Updates…** can't find the release. Then [write the notes](#write-the-release-notes-by-hand).

## Update the Homebrew cask

`Casks/fen.rb` installs the zip from a release. After you publish a release, point the cask at it and open a PR:

```sh
scripts/update-cask.sh v0.1.0   # sets version and sha256, refuses a build that isn't notarized
brew style Casks/fen.rb
```

CI checks the cask's style and that its sha256 matches the published zip. `master` is protected, so the workflow can't push the change for you. Until the PR merges, `brew upgrade` still installs the previous release.

The cask sets `auto_updates true` because Fen updates itself through Sparkle. A plain `brew upgrade` skips Fen. `brew upgrade --cask fen` and `brew upgrade --greedy` still upgrade it.

We don't submit to the official `homebrew-cask` repo. Users tap this repo (see the [README](../README.md#install)).

## Versioning

| Value | Source |
|---|---|
| Marketing version | The git tag without the `v` (tag `v0.1.0` gives `0.1.0`). Without a tag it's `0.0.0-dev`. |
| Build number | The commit count. |
| Landing page `softwareVersion` | The latest release tag, stamped in at deploy time. |

`site/index.html` carries a `__FEN_LATEST_VERSION__` placeholder. `.github/workflows/pages.yml` replaces it with the latest tag (`git describe --tags`) in a deploy-only copy of `site/`, never in the tracked file.

`release.yml` ends by running `gh workflow run pages.yml`, so every release redeploys the page. A `release: published` trigger on `pages.yml` wouldn't fire. A release created with `GITHUB_TOKEN` can't trigger other workflows, except through `workflow_dispatch`.

## Milestones match releases

Every milestone is named exactly like a release tag (`v0.7.0`, nothing more), and every release has one. A milestone is the release it ships in, not a theme.

| When | Do |
|---|---|
| You file or plan an issue | Put it in the next release's milestone. If the work has no date, use `Backlog`. |
| The next release grows a user-visible change | A new feature bumps the minor number. A fix only bumps the patch. Rename the milestone if the number changes. |
| You cut the release | Move any open issue to the next milestone, then close the milestone. It must have 0 open issues. |
| You close an issue in a PR | The issue's milestone is the release that PR ships in. |

Don't create milestones for themes, epics or ordering ("Foundations", "Phase 2"). Use the issue body or a label.

## Verifying a build

```sh
codesign --verify --deep --strict --verbose=2 dist/Fen.app
spctl --assess --type execute --verbose dist/Fen.app   # should say "accepted"
xcrun stapler validate dist/Fen.app                    # notarization ticket
```
