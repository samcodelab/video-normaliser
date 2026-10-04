# Releasing FrankLuma

FrankLuma is a native macOS 14+ app with a checked-in Xcode project. Open `FrankLuma.xcodeproj`, select the **FrankLuma** scheme and **My Mac**, then Run or Test. No project generator or third-party dependencies are required. The Swift package remains available for command-line development; the Xcode project is the canonical distributable app.

## Identity and build settings

- App and executable: `FrankLuma`
- Bundle ID: `com.sam.frankluma`
- Version / build: `1.0.0` / `2`, in `Configuration/Base.xcconfig`
- Team: `PLQG3PMFP8`, matching the existing TonePebble project and installed signing identities
- Deployment target: macOS 14.0
- Release architectures: Apple silicon and Intel (`arm64`, `x86_64`)
- Shared schemes: **FrankLuma**, **FrankLuma Developer ID**, **FrankLuma App Store**

The bundle identifier is configured locally; an App Store Connect record and associated identifier still need to be created/confirmed in the developer account. A machine-specific `Configuration/Local.xcconfig` can override the development team. Keep export-options team IDs in sync when changing teams. Never put passwords or private keys in these files.

## Local build and tests

The current release candidate is **1.0.0 (build 2)**. The marketing version is the public release version; increment the build number for each new App Store Connect upload. Use 1.0.1 for a subsequent bug-fix release and 1.1.0 for a subsequent feature release. Both fields feed the app's Info.plist and standard About panel from `Configuration/Base.xcconfig`.

```sh
zsh scripts/build-app.sh
open dist/FrankLuma.app
xcodebuild -project FrankLuma.xcodeproj -scheme FrankLuma \
  -destination 'platform=macOS' test
```

The build script deliberately uses ad-hoc signing and writes `dist/FrankLuma.app`. It enables the same App Sandbox and Hardened Runtime as the release app, but it is **not** a Developer ID/notarised distribution build. Use a normal Terminal session: restricted agent shells can block Xcode macros, asset-catalog services and native media rendering.

The test target is hosted by the app and includes the actual fixture resources. It covers lighting, preview timing, native export, rendering and staged file replacement/abandonment. `swift test --disable-sandbox` also uses the renamed FrankLuma module and the same tests.

## Developer ID distribution

```sh
zsh scripts/archive-app.sh developer-id
```

This makes a universal archive and Developer ID export under a timestamped `.release/developer-id-*` directory. The **DeveloperID** configuration uses the installed **Developer ID Application** identity, Hardened Runtime and a secure timestamp. The script does not upload anything. In Xcode, the equivalent path is the **FrankLuma Developer ID** scheme → Product → Archive → Distribute App → Developer ID.

After reviewing the exported app, use an existing notarytool Keychain profile or create one interactively in Terminal:

```sh
xcrun notarytool store-credentials FrankLuma-notary
zsh scripts/notarise-app.sh /absolute/path/to/export/FrankLuma.app FrankLuma-notary
```

The notarisation script checks the signature, Hardened Runtime, timestamp, sandbox and absence of the debug entitlement. It submits a ZIP, waits for **Accepted**, staples and validates the ticket, checks Gatekeeper, then creates a new ZIP from the stapled app. Keep its JSON result and submission ID. If Apple rejects it, retrieve the log using `xcrun notarytool log SUBMISSION_ID --keychain-profile FrankLuma-notary`, fix the issue, and rebuild. A successful local build or Developer ID signature alone does not mean the app is notarised.

Credentials stay in Keychain; no credentials are stored in this repository. Notarisation and any Keychain access prompts are explicit release operations.

## DMG packaging

After the app is notarised and stapled:

```sh
zsh scripts/package-dmg.sh /absolute/path/to/export/FrankLuma.app KEYCHAIN_PROFILE
```

This creates a compressed disk image with FrankLuma, an Applications shortcut and installation instructions. It signs the DMG with the app's Developer ID identity, submits the DMG for notarisation, staples the accepted ticket and verifies Gatekeeper and image integrity. Only a verified DMG is copied to `dist/FrankLuma-VERSION-build-BUILD.dmg`, alongside its SHA-256 checksum. Credentials remain in Keychain.

## App Store distribution

Use the **FrankLuma App Store** scheme to Archive, then choose App Store Connect in Organizer. Alternatively, `zsh scripts/archive-app.sh app-store` archives and exports locally using `Configuration/AppStoreExportOptions.plist`; it does not upload. Xcode needs an Apple Development identity for the archive, an Apple Distribution identity and appropriate App Store provisioning for distribution. Configure the account in Xcode → Settings → Accounts and resolve any signing requirements in Signing & Capabilities. Developer ID signing is for distribution outside the App Store, not an App Store submission identity.

Before submission, confirm the App Store Connect record, version/build, support URL, published privacy-policy URL, screenshots, description, pricing and age rating; inspect Organizer's privacy report and validate the archive. App Store availability/review and account provisioning have not been completed by this setup.

The privacy policy is currently a draft only. Publish it with a support contact and add an easily accessible link inside the app as well as in App Store Connect (App Review guideline 5.1.1). The in-app link is not yet implemented because no public policy URL has been supplied. Complete the App Privacy questionnaire to match the actual local-only, no-collection behaviour. Confirm export-compliance answers and applicable agreements, tax/banking details and regional trader disclosures in the developer account. Test the App Store-signed build through TestFlight before submission. Separate Developer ID notarisation is not required for Mac App Store distribution.

## Permissions and privacy

`Resources/FrankLuma.entitlements` grants only:

- `com.apple.security.app-sandbox`
- `com.apple.security.files.user-selected.read-write`

The user grants file access through macOS Open/Save panels, drag-and-drop or Open With. Security-scoped access is retained for playback, analysis, preview and export and released after those operations finish. The source is read only by the app; the read/write entitlement is needed for user-chosen output files. Exports stage in Foundation's item-replacement directory and commit only after encoding succeeds. Failed/cancelled exports leave the existing destination intact. Diagnostics also use a Save panel.

FrankLuma does not record audio/video, access the Photos library, contact network services, use analytics, or request broad folder/Full Disk Access. There are no camera, microphone, Photos, network, automation, executable-memory or library-validation exceptions. Source audio is read from the selected movie; this does not require microphone permission. No persistent security-scoped bookmarks are needed because projects/recent-file restoration are not implemented.

`Resources/PrivacyInfo.xcprivacy` declares no tracking or collected data. The current source does not directly use required-reason API categories; revisit the manifest whenever adding preferences, file timestamps, disk-space checks, third-party SDKs or telemetry. A privacy manifest does not replace the public privacy policy or App Store privacy questionnaire. `docs/PRIVACY.md` supplies a factual policy draft for publication.

## Icon

`Resources/AppIcon-Master.png` is the exact user-supplied FrankLuma artwork (stacked landscape frames with a before/after divider, without text). `Resources/FrankLuma.icon` is the native Icon Composer source used by Xcode; its artwork layer has glass effects disabled to preserve the supplied design. Native icon compilation provides the system mask and avoids the pale backing macOS can add to legacy icons. `Resources/Assets.xcassets/AppIcon.appiconset` contains all ten macOS raster representations, including 1024 × 1024. Repackage without changing the artwork:

```sh
swift scripts/generate-app-icon.swift Resources/AppIcon-Master.png \
  Resources/Assets.xcassets/AppIcon.appiconset
```

## Verification on 4 October 2026

- Xcode's hosted test suite passed all 45 tests with zero failures.
- The universal Developer ID archive/export succeeded. macOS verified its signature, secure timestamp, Hardened Runtime and the two intended sandbox entitlements.
- The exported signed app opened the selected 4K movie through the native Open panel, analysed it, and successfully exported `FrankLuma Sandbox Check.mov` through the native Save panel while sandboxed.
- Notarisation, App Store provisioning and submission have not been performed.

## Apple references

- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Safe file replacement](https://developer.apple.com/documentation/foundation/filemanager/replaceitemat(_:withitemat:backupitemname:options:))
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Distribute outside the Mac App Store](https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html)
- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)


## App Review notes for 1.0

FrankLuma is an offline SDR exposure-flicker correction tool. No account, network service or additional hardware is needed. To evaluate it without supplying media:

1. Choose Help → Open Demo Video (or Try the included demo in the empty window).
2. Choose Detect scenes & analyse.
3. Select Side by side and play the clip. The original geometric animation intentionally has alternating exposure. The right-hand preview applies correction.
4. Zoom with Command-scroll or a trackpad pinch. Select a frame slice and use Split at playhead; scene controls let you adjust boundaries and correction strength.
5. Export to a user-chosen file. Output is SDR H.264 in a QuickTime `.mov` container, with compatible source audio preserved. The demo is intentionally silent.

The demo is original, procedurally generated geometric footage; its generator is `scripts/generate-demo.swift`. It contains no third-party artwork or licensed audio. HDR (PQ/HLG), protected media and dimensions above 4096 pixels on either side are rejected with instructions to make an SDR copy. Codec decoding depends on macOS. Do not advertise lossless export, general white-balance correction or HDR support.

Analysed sessions are held in memory. Opening another video, closing the main window or quitting asks before discarding settings. Exports are saved videos, not editable projects. While a task is running, close/quit asks the user to wait or cancel from the main window first.

Remaining device/account checks: run the App Store-signed build through TestFlight; exercise actual HDR/iPhone samples, hour-long/high-frame-rate footage, external and removable volumes, real disk-full/permission failures, macOS 14, and Intel hardware. The local automated tests do not replace those checks. The public support email is support@broadframestudio.com and is linked in Help. A live support-page URL for the store listing and published privacy-policy URL still need to be provided before submission.


### Build 2 validation

The hosted Xcode suite passes 55 tests. Added coverage includes HEVC input with rotation and variable presentation times, a 1,440-frame / one-minute SDR analysis and export, malformed input, cancellation preserving an existing destination, HDR/oversize rejection policy, and wrapped disk-full error recovery messaging. The bundled original demo passes an encoded-output check for at least 50% reduction in adjacent-frame exposure variation. Interactive checks confirmed demo opening/analysis, Close and Quit confirmations with Keep Editing retaining the session, and the Help window with the support email. These checks ran on the current Apple-silicon Mac; no claim is made of completed Intel/macOS 14 or physical external-drive/disk-full validation.


## Notarised distribution — 4 October 2026

FrankLuma 1.0.0 (build 2) was signed with Developer ID Application, submitted to Apple and accepted. Both the app and its final DMG have stapled tickets. Gatekeeper accepted the DMG and the app mounted read-only from that DMG; disk-image integrity verification passed.

- Final package: `dist/FrankLuma-1.0.0-build-2.dmg`
- Checksum: `dist/FrankLuma-1.0.0-build-2.dmg.sha256`
- App submission: `8e4b81c0-a618-4043-9b15-4a3d9c00cbc3`
- DMG submission: `f7825114-fe3c-4e98-aab9-dcc1e3ea703f`
- Evidence: `.release/notarisation-32deLg/result.json`, `.release/dmg-9RdmlN/notarisation.json`

The disk image contains FrankLuma.app, an Applications shortcut, and Install.txt. This completes direct-distribution signing/notarisation; it is not a Mac App Store submission or approval.
