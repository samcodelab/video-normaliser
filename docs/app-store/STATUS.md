# Submission status — 1.0.0 (10)

## Current result — 5 October 2026

The reviewed build 10 source passes all 79 hosted tests. Xcode account access is restored: the final universal App Store archive and package export both succeed. The package and embedded app signatures verify; the app uses Apple Distribution and the installer uses the team's Mac Developer Installer certificate. No upload, Apple server validation or review submission has been performed.

Archive: `.release/app-store-20261005-115639/FrankLuma.xcarchive`.
Package: `.release/app-store-20261005-115639/export/FrankLuma.pkg`.
SHA-256: `a7a4b7829b029a17d013eeb12917b14660c50debee543672bde310c0bc02fe17`.

The packaged app has bundle ID `com.broadframestudio.frankluma`, version 1.0.0 (10), macOS 14 minimum, both architectures, sandbox/bookmark/user-selected-file entitlements, and no debug entitlement. Its privacy manifest and original demo match the reviewed source. Do not upload older build 3, 7, 8 or 9 packages.

Build 10 is available for local testing at `dist/local/FrankLuma.app`; it is ad-hoc signed. The verified Developer ID/notarised build 4 remains at `dist/FrankLuma.app` and `dist/FrankLuma-1.0.0-build-4.dmg`; it predates subsequent fixes/features. Store signing is complete, while a new Developer ID notarisation is a separate task.

## Issues addressed

- Changed the app bundle ID to `com.broadframestudio.frankluma`, including the hosted-test ID and archive verification. Xcode automatic provisioning/export succeeds for the new ID. The separate project-document type remains `com.sam.frankluma.project` so existing files stay compatible. The new app ID has separate sandbox/recovery storage; save unsaved sessions in the previous app before switching.

- Cancelling during correction could clear the pending flag while retaining a curve from older settings, allowing stale output to be exported. Cancel now retains/recalculates the current correction in the background; export stays disabled until it is current. A native model regression covers this.
- Local development builds previously overwrote the signed default app and merged bundles in place. `scripts/build-app.sh` now verifies a fresh staged bundle and publishes only to `dist/local/FrankLuma.app`, preserving distribution artifacts.
- Added region-based, exposure-normalised palette comparison with a settled prior shot and three-frame confirmation. The supplied 4K clip now automatically splits the group/single-figure transition at zero-based frame 193 (displayed frame 194), plus three other genuine camera changes. No new cuts were added during continuous Hulk movement.
- Reanalysis now refreshes untouched automatic cuts, inherits scene settings, and preserves manually reviewed boundaries.
- Release/listing documentation now identifies build 10 rather than implying the old Store package contains the accepted algorithm.
- Replaced the small Help text window with a searchable, offline nine-topic handbook, including detailed workflows, troubleshooting and browser links to the online handbook/privacy policy. Native UI checks verified layout, topic search, demo opening, analysis and a Save-panel H.264 export. These interactive checks use an isolated ad-hoc sandboxed app.
- About now displays Broad Frame Studio, its copyright and a clickable website link; verified in the running build 9 app (unchanged in build 10).
- Added Loop scene playback with real native player regression coverage: repeating the selected scene and pausing pending rewinds.
- Added an archive preflight that verifies the current version, signing team, release architectures, sandbox, privacy manifest, original demo and four screenshot sizes; verified that it rejects the older build 6 archive. Store archive creation now runs it before export.

## Ready locally

- Local-only app with no account, network service, advertising, third-party analytics or in-app purchases. A$19.99 Australian one-time launch price is prepared.
- Privacy-policy links in Help; sandbox access only to selected files, scoped bookmarks and app-container recovery storage. Privacy manifest declares no collection/tracking and the intended file timestamp reasons.
- Original silent demo lets App Review analyse, preview and export without supplying private footage.
- Editable projects, save/discard protection, staged exports, recovery, native codec/timing/audio tests and rendered-pixel regressions.
- English listing/review instructions in LISTING.md; four genuine 2560×1600 screenshots in screenshots/. Product controls/features shown remain present.
- Live privacy and support URLs rechecked: HTTPS HTTP 200 on 5 October. Policy describes local storage, retention, recovery and voluntary support emails. Website source/deployment unchanged.

Use https://broadframestudio.com/frankluma/privacy/ and https://broadframestudio.com/frankluma/help/ in App Store Connect. Support is support@broadframestudio.com; mailbox delivery has not been tested.

See HANDOFF.md for the exact archive/export commands and the prepared listing/review material.

## Remaining submission steps

1. Store signing/export is complete. Upload the verified build 10 package with Organizer/Transporter once the app record is ready; no credential restoration or new archive is needed for this source.
2. Confirm/create the macOS FrankLuma record for `com.broadframestudio.frankluma`. Enter required review contact name, email and phone.
3. Confirm applicable paid-app agreements, tax/banking and regional trader disclosures. The account holder must accept binding agreements.
4. Enter version 1.0.0, Video category, A$19.99 Australian price, intended regions, LISTING.md copy, live URLs and screenshots.
5. Complete current App Privacy, age-rating and encryption/export-compliance questionnaires against the shipped app. Prepared guidance is not a completed questionnaire.
6. Inspect Apple's processing/privacy validation, resolve any errors, and select build 10 for review. No Apple server validation has been performed here.

TestFlight is optional. Developer ID notarisation is for direct distribution and does not replace Store signing or block an otherwise valid Store submission.

## Validation and remaining risks

All 79 hosted tests pass, zero failures/skips: `.build/release-tests/Logs/Test/Test-FrankLuma-2026.10.05_11-56-46-+1100.xcresult`. Four licensed/derived short practice inputs successfully analyse, preview, export and reanalyse, preserving source frames/dimensions/duration. A real ten-minute 640×360/25 fps file completes decoding, correction, export and reanalysis with all 15,000 frames and 600 seconds preserved. Analysis plus correction takes 37.66 seconds on this Mac; export is excluded from that timing. It repeats one clip and does not establish 4K production-footage performance.

The final 4K verification detects 14 automatic cuts / 15 scenes and preserves all 212 frames, 3840×2160 dimensions and 17.667-second duration through export/reanalysis. The three-frame local-flash practice clip remains one scene; its 596 frames are preserved. The deliberately extreme whole-frame exposure variant adds false cuts in the near-black credit transition (297, 298, 314); the paper-animation portion retains its original boundary at 293. Automatic cuts are editable; this remains a detection limitation, not a claim of complete correction. See `../../PracticeFootage/README.md` for attributions, severity labels and reproducible audit tools. Practice files are not bundled in the app or screenshots.

Physical checks still recommended before pressing Submit: macOS 14 Apple silicon, production-signed Finder/project opening across restarts, actual external-volume and disk-full failures, and varied real 4K/10–20-minute footage. Intel device testing is waived; the universal binary retains Intel support. Native UI capture now works. Help/search/About and demo analysis/export were checked in isolated sandboxed local apps; a fresh production-signed Finder/project-opening check across restarts remains outstanding. HDR remains intentionally unsupported and must not be advertised.

This local review found no demonstrated sandbox/privacy/third-party-content policy violation. It does not predict or guarantee Apple's approval.

[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) · [Common review issues](https://developer.apple.com/app-store/review/) · [Signing identities](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)
