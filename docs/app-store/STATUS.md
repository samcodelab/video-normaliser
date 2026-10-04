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

## Deferred website publication

The user requested leaving the website alone for now. Existing source is in sibling `BroadFrameStudio.com`; its build and FrankLuma local links/assets pass. These URLs returned HTTP 404 and must work before submission:

- Privacy: https://broadframestudio.com/frankluma/privacy/index.html
- Support: https://broadframestudio.com/frankluma/help/index.html

No website source edits, commits, pushes or deployment were made by this release-preparation task.

## App Store Connect handoff

The account page did not load beyond its header in Safari. In App Store Connect:

1. Confirm/create the macOS FrankLuma app record for `com.sam.frankluma` and team `PLQG3PMFP8`.
2. Confirm applicable agreements and paid-app tax/banking information, and applicable regional trader disclosures. Account holder must accept any new binding agreement.
3. Set version 1.0.0, category Video, Australian price A$19.99 and intended countries/regions. Review Apple's generated prices elsewhere.
4. Enter LISTING.md copy, the verified live URLs, screenshots and required review contact details.
5. Complete App Privacy, current age-rating and export-compliance questionnaires against the shipped app.
6. Upload the signed package with Xcode Organizer or Transporter, validate Apple's processing results, and inspect the archive privacy report. A successful local export is not server validation or approval.
7. Test the processed build through TestFlight, then submit when website and remaining device validation are complete.

## Remaining device and footage checks

- macOS 14 and Intel: launch, analyse, preview, save/reopen and export all five formats.
- Finder project opening and project drag-and-drop in the production-signed app.
- External/removable volumes and real disk-full/permission failures.
- Hour-long/high-frame-rate footage, real HDR/iPhone rejection, multichannel downmix and visual checks on varied production footage.
- Final Store build on a second Mac through TestFlight, including crash recovery and source bookmarks across restarts.

The automated suite includes native codec/timing/audio conversion and a one-minute video, but does not establish completion of the physical-device checks above. HDR remains intentionally unsupported.
