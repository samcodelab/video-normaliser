# Submission status — 1.0.0 (3)

## Prepared and verified

- Privacy-policy links inside the app.
- Privacy manifest: no tracking/collection; file timestamp reasons for selected files and app-container recovery metadata.
- Universal sandboxed archive and App Store-signed package; provisioning resolved.
- All 63 hosted tests pass, including actual export choices and the bundled demo.
- Native force-quit recovery: startup sheet appears and restores unsaved settings.
- English listing, review guidance, privacy/compliance guidance and A$19.99 Australian one-time launch price in LISTING.md.
- Four 2560×1600 screenshots in screenshots/.

Package: `.release/app-store-build-3-final/export/FrankLuma.pkg` (ignored build artifact, on this Mac). No upload, TestFlight distribution or review submission has occurred.

## Performance changes after the build 3 archive

The current source includes original-frame regional brightness targets, motion/colour support checks, background/debounced correction, reuse of unchanged scenes and registrations, bounded local frame preparation, parallel correction on long shots, and motion-aware scene-cut confirmation. The hosted suite now passes 70 tests, including independent regional lighting targets for uneven flicker. The supplied 4K/12 fps clip was analysed, exported and reanalysed with all 212 frames and its original dimensions/duration preserved. An optimized local app is in `.build/performance-release/Build/Products/Release/FrankLuma.app`.

The existing Store package predates these changes. Create and validate a new numbered archive/export before uploading; do not use the old build 3 package as evidence for the updated source. Correction stress tests cover a 20-minute analysis workload, not decoding/exporting a real 20-minute 4K source. See the performance verification notes in `docs/RELEASING.md`.

## Live website verified — 4 October 2026

Both pages now return HTTP 200 over HTTPS. The index.html URLs redirect with HTTP 308 to the canonical trailing-slash URLs. The privacy policy matches local processing, project/bookmark metadata and recovery storage; both pages provide support@broadframestudio.com. Use these canonical URLs in App Store Connect:

- Privacy: https://broadframestudio.com/frankluma/privacy/
- Support: https://broadframestudio.com/frankluma/help/

No website source edits or deployment were made during this verification. The in-app privacy link uses index.html and works through the redirect. All 26 linked pages/assets checked with curl returned HTTP 200. Mailbox delivery was not tested.

## App Store Connect handoff

The account page did not load beyond its header in Safari. In App Store Connect:

1. Confirm/create the macOS FrankLuma app record for `com.sam.frankluma` and team `PLQG3PMFP8`.
2. Confirm applicable agreements and paid-app tax/banking information, and applicable regional trader disclosures. Account holder must accept any new binding agreement.
3. Set version 1.0.0, category Video, Australian price A$19.99 and intended countries/regions. Review Apple's generated prices elsewhere.
4. Enter LISTING.md copy, the verified live URLs, screenshots and required review contact details.
5. Complete App Privacy, current age-rating and export-compliance questionnaires against the shipped app.
6. Upload the signed package with Xcode Organizer or Transporter, validate Apple's processing results, and inspect the archive privacy report. A successful local export is not server validation or approval.
7. Submit when website and final release checks are complete. TestFlight is optional, not an Apple submission requirement; a small beta test remains a useful additional check.

## Remaining device and footage checks

- macOS 14 on Apple silicon: launch, analyse, preview, save/reopen and export all five formats. Intel device validation is waived at the user’s request; the current universal binary still contains Intel support.
- Finder project opening and project drag-and-drop in the production-signed app.
- External/removable volumes and real disk-full/permission failures.
- Hour-long/high-frame-rate footage, real HDR/iPhone rejection, multichannel downmix and visual checks on varied production footage.
- Recommended additional check: final Store build on a second Apple-silicon Mac, including crash recovery and source bookmarks across restarts. TestFlight can distribute it but is optional.

The automated suite includes native codec/timing/audio conversion and a one-minute video, but does not establish completion of the physical-device checks above. HDR remains intentionally unsupported.

[TestFlight is optional — Apple](https://developer.apple.com/help/glossary/testflight-beta-testing/)
