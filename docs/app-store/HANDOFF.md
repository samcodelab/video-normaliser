# FrankLuma submission handoff

Prepared 5 October 2026 for **1.0.0 (7)**, bundle ID `com.sam.frankluma`, team `PLQG3PMFP8`.

## Verified artifact

Archive: `.release/app-store-20261005-103102/FrankLuma.xcarchive`.

All 79 hosted tests pass, with zero failures/skips. Archive preflight passes signature, version, sandbox, privacy, demo, architectures and screenshot-size checks. This is not an exported Store package or Apple server validation. Export currently fails because Xcode has no signed-in account and cannot find a Mac Installer Distribution signing identity with its private key.

After restoring the Xcode account and Store signing, run these commands from the repository root in Terminal. The preflight deliberately rejects archives from older builds.

```sh
python3 scripts/verify-store-archive.py \
  .release/app-store-20261005-103102/FrankLuma.xcarchive
xcodebuild -exportArchive \
  -archivePath .release/app-store-20261005-103102/FrankLuma.xcarchive \
  -exportOptionsPlist Configuration/AppStoreExportOptions.plist \
  -exportPath .release/app-store-20261005-103102/export \
  -allowProvisioningUpdates
```

Upload the resulting package through Xcode Organizer or Transporter. Do not use the older build 3 package. Wait for Apple processing and resolve any reported errors before selecting build 7 for review. Developer ID notarisation is a separate direct-distribution process.

## App Store Connect fields

Use [LISTING.md](LISTING.md) for name, subtitle, keywords, description, promotional text and copy-ready review notes. Use Video as the primary category, version 1.0.0, and A$19.99 in Australia; review the automatically assigned prices for other regions.

- Privacy: `https://broadframestudio.com/frankluma/privacy/`
- Support: `https://broadframestudio.com/frankluma/help/`
- Public support email: `support@broadframestudio.com`
- Screenshots: upload `screenshots/01-comparison.png` through `04-export.png` in order, all 2560×1600. These genuine captures predate Loop scene; the pictured workflows remain available.
- App Privacy: Data Not Collected; no tracking. Confirm the current questionnaire against the shipped app.
- Encryption: the binary declares no non-exempt encryption; complete Apple's questionnaire consistently with that declaration.
- Age rating: answer for the video utility and original geometric demo; complete Apple's current questions before assigning a rating.

The account holder must confirm paid-app agreements, tax/banking, availability and applicable trader disclosures. Review contact name, email and phone must be entered separately. Do not infer these from the public support address. TestFlight is optional.

For the fastest final acceptance check, use the production-signed app to open the demo, analyse, compare, loop a scene, save/reopen a project, and export/play the result. A check on macOS 14 Apple silicon is still outstanding. See [STATUS.md](STATUS.md) for the remaining device/performance checks and known detection limitations.

[Apple upload instructions](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) · [Certificates](https://developer.apple.com/help/account/certificates/certificates-overview/)
