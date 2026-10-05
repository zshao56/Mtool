# Releasing Mtool

Mtool ships as a single universal `Mtool.dmg`. The workflow at
`.github/workflows/build.yml` builds, tests and packages it on a macOS runner.

## What the workflow does

1. `xcodegen generate`
2. `xcodebuild test` (unit test suite: 151 tests)
3. `xcodebuild -configuration Release` for `x86_64 arm64`, **unsigned**
4. Ad-hoc signs the app (`codesign --sign -`)
5. Builds the DMG with `hdiutil`
6. Writes `Mtool.dmg.sha256`
7. Uploads both as a workflow artifact; on a `v*` tag it also publishes them to a
   GitHub Release.

There are **no upstream credentials** anywhere in the workflow. The restricted
`keychain-access-groups` entitlement from QDuo is gone, so no provisioning
profile is needed and AMFI will not kill the app at launch.

## Download and checksum

Every release lists `Mtool.dmg` and `Mtool.dmg.sha256`. Verify with:

```sh
shasum -a 256 -c Mtool.dmg.sha256
```

## Gatekeeper and unnotarized preview builds

Public builds and CI artifacts without Apple credentials are **unnotarized preview builds**
(未公证预览构建). On first launch macOS Gatekeeper will refuse to open the app directly.
The user must right-click `Mtool.app` (or right-click in `/Applications`) and choose **Open**,
then confirm. This must be stated in release notes; Mtool does not claim to be signed with
an Apple Developer ID certificate or notarized unless the repository owner supplies their own
secrets.

Automated CI build and unit test success confirms compilation and unit logic, but does
**not** substitute for real cross-application desktop acceptance ([acceptance checklist](ACCEPTANCE.md)).

### Verified preview build reference

The preview build from `main` commit `fbc200f` (GitHub Actions run `37259409559`, 2026-10-05) completed with:
- `xcodebuild test`: 151 tests, 0 failures.
- Release build: succeeded (universal `x86_64 arm64` binary).
- DMG artifact: `Mtool.dmg` containing `Mtool.app` and `/Applications` shortcut.
- SHA-256: `992b520b6165f1954b2fdbec9742d5ee30e5116fd68c545723542d779cb57444`.
- Local verification: `shasum -a 256 -c` passed, `hdiutil verify` valid, and `codesign --verify --deep --strict` passed.

That hash identifies the earlier `main` workflow artifact only. A tag build creates
a new DMG; verify a release download with the `.sha256` attached to **that release**.

## Optional: Developer ID signing and notarization

If you have your **own** Apple Developer account, you can sign and notarize
without changing the source. Add these repository secrets (none are required):

| Secret | Purpose |
| --- | --- |
| `MTOOL_CERT_P12_BASE64` | base64 of your Developer ID Application `.p12` |
| `MTOOL_CERT_P12_PASSWORD` | password for that `.p12` |
| `MTOOL_APPLE_ID` | Apple ID for notarization |
| `MTOOL_APPLE_TEAM_ID` | your team id |
| `MTOOL_APPLE_PASSWORD` | an app-specific password |

When `MTOOL_CERT_P12_BASE64` and its password are present the workflow imports
the certificate and signs with `Developer ID Application`; when the Apple ID
secrets are present it also notarizes and staples the DMG. Without them, the
unsigned path runs and the build still succeeds.

**Never** use another project's certificate, profile or keys. Never commit
signing material to the repository (`.gitignore` already excludes `*.p12`,
`*.provisionprofile`, `*.mobileprovision`, `.env`).

## Cutting a release

```sh
# bump MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml, create
# docs/releases/<tag>.md with installation and verification notes, and commit, then:
git tag v1.0.0
git push origin v1.0.0
```

The tag push runs the workflow and publishes the DMG plus checksum to the GitHub
Release for that tag.
