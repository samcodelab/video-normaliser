# Submission status — 1.0.0 (6)

## Current result — 5 October 2026

The reviewed source passes all 77 hosted tests. The final universal App Store archive builds successfully, but export is blocked by Xcode reporting **No Accounts** and **No signing certificate “Mac Installer Distribution” found** for team `PLQG3PMFP8`. The final build 6 export attempt gives the same result. No build 6 Store package, upload or review submission exists. The old build 3 package must not be uploaded for this source.

Archive: `.release/app-store-20261005-101753/FrankLuma.xcarchive`. The archived app has bundle ID `com.sam.frankluma`, version 1.0.0 (6), macOS 14 minimum, both architectures, sandbox/bookmark/user-selected-file entitlements, and no debug entitlement. Its signature verifies; the original demo and privacy manifest are present.

Developer ID build 5 also archives and exports successfully at `.release/developer-id-20261005-011250/export/FrankLuma.app`. Its notarisation attempt cannot find the previously working `TonepebbleNotary` profile in the current Keychain context. The verified notarised build 4 remains at `dist/FrankLuma.app` and `dist/FrankLuma-1.0.0-build-4.dmg`; it predates the cancellation fix. Build 6 is available for local testing at `dist/local/FrankLuma.app`; it is ad-hoc signed, not a notarised release.

## Issues addressed

- Cancelling during correction could clear the pending flag while retaining a curve from older settings, allowing stale output to be exported. Cancel now retains/recalculates the current correction in the background; export stays disabled until it is current. A native model regression covers this.
- Local development builds previously overwrote the signed default app and merged bundles in place. `scripts/build-app.sh` now verifies a fresh staged bundle and publishes only to `dist/local/FrankLuma.app`, preserving distribution artifacts.
- Added region-based, exposure-normalised palette comparison with a settled prior shot and three-frame confirmation. The supplied 4K clip now automatically splits the group/single-figure transition at zero-based frame 193 (displayed frame 194), plus three other genuine camera changes. No new cuts were added during continuous Hulk movement.
- Reanalysis now refreshes untouched automatic cuts, inherits scene settings, and preserves manually reviewed boundaries.
- Release/listing documentation now identifies build 6 rather than implying the old Store package contains the accepted algorithm.

## Ready locally

- Local-only app with no account, network service, advertising, third-party analytics or in-app purchases. A$19.99 Australian one-time launch price is prepared.
- Privacy-policy links in Help; sandbox access only to selected files, scoped bookmarks and app-container recovery storage. Privacy manifest declares no collection/tracking and the intended file timestamp reasons.
- Original silent demo lets App Review analyse, preview and export without supplying private footage.
- Editable projects, save/discard protection, staged exports, recovery, native codec/timing/audio tests and rendered-pixel regressions.
- English listing/review instructions in LISTING.md; four genuine 2560×1600 screenshots in screenshots/. Product controls/features shown remain present.
- Live privacy and support URLs rechecked: HTTPS HTTP 200 on 5 October. Policy describes local storage, retention, recovery and voluntary support emails. Website source/deployment unchanged.

Use https://broadframestudio.com/frankluma/privacy/ and https://broadframestudio.com/frankluma/help/ in App Store Connect. Support is support@broadframestudio.com; mailbox delivery has not been tested.

## Account steps that currently block submission

1. Sign into the developer account in Xcode → Settings → Accounts, select team `PLQG3PMFP8`, and resolve the Store installer signing certificate/cloud signing. Re-export the existing build 5 archive; no new archive is needed solely to restore credentials.
2. Confirm/create the macOS FrankLuma record for `com.sam.frankluma`. Enter required review contact name, email and phone.
3. Confirm applicable paid-app agreements, tax/banking and regional trader disclosures. The account holder must accept binding agreements.
4. Enter version 1.0.0, Video category, A$19.99 Australian price, intended regions, LISTING.md copy, live URLs and screenshots.
5. Complete current App Privacy, age-rating and encryption/export-compliance questionnaires against the shipped app. Prepared guidance is not a completed questionnaire.
6. Upload the current Store package with Organizer/Transporter, inspect Apple's processing/privacy validation and select the build for review. No Apple server validation has been performed here.

TestFlight is optional. Developer ID notarisation is for direct distribution and does not replace Store signing or block an otherwise valid Store submission.

## Validation and remaining risks

All 77 hosted tests pass, zero failures/skips: `.build/release-tests/Logs/Test/.build/release-tests/Logs/Test/Test-FrankLuma-2026.10.05_10-17-51-+1100.xcresult`. Four licensed/derived short practice inputs successfully analyse, preview, export and reanalyse, preserving source frames/dimensions/duration. A real ten-minute 640×360/25 fps file completes decoding, correction, export and reanalysis with all 15,000 frames and 600 seconds preserved. Analysis plus correction takes 37.66 seconds on this Mac; export is excluded from that timing. It repeats one clip and does not establish 4K production-footage performance.

The final 4K verification detects 14 automatic cuts / 15 scenes and preserves all 212 frames, 3840×2160 dimensions and 17.667-second duration through export/reanalysis. The three-frame local-flash practice clip remains one scene; its 596 frames are preserved. The deliberately extreme whole-frame exposure variant adds false cuts in the near-black credit transition (297, 298, 314); the paper-animation portion retains its original boundary at 293. Automatic cuts are editable; this remains a detection limitation, not a claim of complete correction. See `../../PracticeFootage/README.md` for attributions, severity labels and reproducible audit tools. Practice files are not bundled in the app or screenshots.

Physical checks still recommended before pressing Submit: macOS 14 Apple silicon, production-signed Finder/project opening across restarts, actual external-volume and disk-full failures, and varied real 4K/10–20-minute footage. Intel device testing is waived; the universal binary retains Intel support. Build 5 was launched as a native process, but this session's UI capture reports `cgWindowNotFound`, so no fresh interactive UI/Finder acceptance check is claimed. HDR remains intentionally unsupported and must not be advertised.

This local review found no demonstrated sandbox/privacy/third-party-content policy violation. It does not predict or guarantee Apple's approval.

[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) · [Common review issues](https://developer.apple.com/app-store/review/) · [Signing identities](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)
