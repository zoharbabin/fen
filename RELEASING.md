# Releasing MacDown

This explains how to publish a signed, notarized `MacDown.app` to the GitHub
[Releases](https://github.com/mfbergmann/macdown-swift/releases) page. It's
written to be followed even if you don't do this every day.

There are two ways to release:

1. **Automatic (recommended):** push a version tag and GitHub Actions builds,
   signs, notarizes, and uploads the app for you.
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

Look for a line like `Developer ID Application: Your Name (ABCDE12345)`.
The 10-character code in parentheses is your **Team ID**.

### 2. Create an app-specific password (for notarization)

1. Go to <https://appleid.apple.com> → **Sign-In and Security** → **App-Specific Passwords**.
2. Create one named e.g. `macdown-notary` and copy the generated password.

---

## Option A — Release via GitHub Actions (recommended)

### Add repository secrets (one time)

In GitHub: **Settings → Secrets and variables → Actions → New repository secret**.
Add all six:

| Secret | Value |
|--------|-------|
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Your Name (ABCDE12345)` |
| `MACOS_CERTIFICATE` | base64 of your exported certificate (see below) |
| `MACOS_CERTIFICATE_PWD` | the password you set when exporting the `.p12` |
| `APPLE_ID` | your Apple ID email |
| `APPLE_APP_PASSWORD` | the app-specific password from step 2 |
| `APPLE_TEAM_ID` | the 10-character Team ID |

To produce `MACOS_CERTIFICATE`: in **Keychain Access**, find your *Developer ID
Application* certificate, right-click → **Export…**, save as a `.p12` with a
password, then convert it to base64 text:

```sh
base64 -i Certificates.p12 | pbcopy   # now paste into the secret
```

### Cut a release

```sh
git tag v0.1.0
git push origin v0.1.0
```

The **Release** workflow runs automatically: it tests, builds, signs, notarizes,
staples, zips, and creates a GitHub Release with `MacDown.app.zip` attached.

> If you skip the secrets, the workflow still runs and produces an **unsigned**
> build — fine for testing, but users will see a Gatekeeper warning.

---

## Option B — Build & release manually on your Mac

`./scripts/build-app.sh` **auto-detects** your "Developer ID Application"
certificate and signs with it — no `SIGN_IDENTITY` needed for a signed local
build. To also notarize (required before others can run it without warnings):

```sh
# 1. Store notary credentials once (creates a keychain profile)
xcrun notarytool store-credentials macdown-notary \
  --apple-id "you@example.com" \
  --team-id "ABCDE12345" \
  --password "your-app-specific-password"

# 2. Build, sign, and notarize
SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)" \
NOTARY_PROFILE="macdown-notary" \
./scripts/build-app.sh

# 3. Zip and upload to a GitHub release
cd dist
ditto -c -k --keepParent "MacDown.app" "MacDown.app.zip"
gh release create v0.1.0 MacDown.app.zip --generate-notes
```

---

## Versioning

The marketing version comes from the git tag (e.g. tag `v0.1.0` → version `0.1.0`).
The build number is the commit count. Without a tag, the version is `0.0.0-dev`.

## Verifying a build

```sh
codesign --verify --deep --strict --verbose=2 dist/MacDown.app
spctl --assess --type execute --verbose dist/MacDown.app   # should say "accepted"
xcrun stapler validate dist/MacDown.app                    # notarization ticket
```
