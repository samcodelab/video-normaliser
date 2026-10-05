# FrankLuma submission handoff

Prepared 5 October 2026 for **1.0.0 (10)**, bundle ID `com.broadframestudio.frankluma`, team `PLQG3PMFP8`.

## Verified artifact

Archive: `.release/app-store-20261005-115639/FrankLuma.xcarchive`.

All 79 hosted tests pass, with zero failures/skips. Archive preflight and Store export both succeed. The final package is `.release/app-store-20261005-115639/export/FrankLuma.pkg`. Its installer signature verifies; its embedded app has the expected Apple Distribution signature and sandbox entitlements. The packaged privacy manifest, original demo and build metadata match the reviewed source.

SHA-256: `a7a4b7829b029a17d013eeb12917b14660c50debee543672bde310c0bc02fe17`.

No upload or Apple server validation has been performed. To recheck/re-export this exact archive if needed, use the following commands from the repository root. The preflight rejects archives from older builds.

```sh
python3 scripts/verify-store-archive.py \
  .release/app-store-20261005-115639/FrankLuma.xcarchive
xcodebuild -exportArchive \
  -archivePath .release/app-store-20261005-115639/FrankLuma.xcarchive \
  -exportOptionsPlist Configuration/AppStoreExportOptions.plist \
  -exportPath .release/app-store-20261005-115639/export \
  -allowProvisioningUpdates
```

Upload the resulting package through Xcode Organizer or Transporter. Do not use older build 3, 7, 8 or 9 packages. Wait for Apple processing and resolve any reported errors before selecting build 10 for review. Developer ID notarisation is a separate direct-distribution process.

## App Store Connect fields

Use [LISTING.md](LISTING.md) for name, subtitle, keywords, description, promotional text and copy-ready review notes. Use Video as the primary category, version 1.0.0, and A$19.99 in Australia; review the automatically assigned prices for other regions.

- Privacy: `https://broadframestudio.com/frankluma/privacy/`
- Support: `https://broadframestudio.com/frankluma/help/`
- Public support email: `support@broadframestudio.com`
- Screenshots: upload `screenshots/01-comparison.png` through `04-export.png` in order, all 2560×1600. These genuine captures predate Loop scene; the pictured workflows remain available.
- App Privacy: Data Not Collected; no tracking. Confirm the current questionnaire against the shipped app.
- Encryption: the binary declares no non-exempt encryption; complete Apple's questionnaire consistently with that declaration.
- Age rating: answer for the video utility and original geometric demo; complete Apple's current questions before assigning a rating.

The searchable offline handbook is available from Help → FrankLuma Help, with workflow topics and links to the online handbook. About uses Broad Frame Studio branding and a clickable website link.

The account holder must confirm paid-app agreements, tax/banking, availability and applicable trader disclosures. Review contact name, email and phone must be entered separately. Do not infer these from the public support address. TestFlight is optional.

For the fastest final acceptance check, use the production-signed app to open the demo, analyse, compare, loop a scene, save/reopen a project, and export/play the result. A check on macOS 14 Apple silicon is still outstanding. See [STATUS.md](STATUS.md) for the remaining device/performance checks and known detection limitations.

[Apple upload instructions](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) · [Certificates](https://developer.apple.com/help/account/certificates/certificates-overview/)

The new app bundle ID uses a separate sandbox/recovery container. Save unsaved work in the old app as a project before switching. Project-file type/version identifiers are unchanged for compatibility. Select `com.broadframestudio.frankluma` in App Store Connect; previous-ID packages are not the current submission artifact.
