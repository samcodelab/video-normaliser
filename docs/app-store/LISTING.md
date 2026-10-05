# FrankLuma 1.0 App Store listing

Prepared for version 1.0.0, build 9. Copy is ready for review; account settings and upload remain pending; privacy/support URLs are verified live.

## App information

Name: FrankLuma

Subtitle: Reduce stop-motion flicker

Primary category: Video

Keywords: stop motion,flicker,exposure,animation,deflicker,lighting,video correction

Privacy policy URL: https://broadframestudio.com/frankluma/privacy/

Support URL: https://broadframestudio.com/frankluma/help/ (verified live, includes support contact)

Price: A$19.99, one-time purchase in the Australian storefront. Select this price in App Store Connect and review automatic prices in other regions. No subscriptions or in-app purchases are implemented.

Copyright: © 2026 Broad Frame Studio

## Description

Uneven lighting can distract from carefully crafted stop-motion animation. FrankLuma helps reduce exposure flicker in SDR video, with processing performed locally on your Mac.

Open a clip, detect scenes and analyse the lighting. Compare your original and corrected footage side by side, then adjust the correction strength for each scene. Select a stable reference area when moving subjects make whole-frame measurements less useful.

• Compare original and corrected previews before exporting.
• Loop a selected scene to review correction over time.
• Detect and refine scene boundaries with a zoomable timeline.
• Choose Smooth flicker to retain gradual lighting changes, or Steady scene for more consistent exposure.
• Save editable projects and reopen them later with your original source video.
• Recover unsaved edits from local autosave checkpoints.
• Export H.264 or HEVC in MP4 or QuickTime, or ProRes 422 in QuickTime.
• Follow the searchable offline handbook and try the included demo.

Your source videos remain untouched. FrankLuma has no accounts, advertising or third-party analytics, and does not upload your footage.

Requires macOS 14 or later. Supports SDR video readable by macOS, up to 4096 pixels on either side. Codec availability depends on your Mac and macOS. HDR and protected media are not supported. Export re-encodes video; correction cannot restore clipped highlights, and strong motion or too little stable background can limit results.

## Promotional text

Reduce exposure flicker, compare corrections side by side, and save editable projects—all locally on your Mac.

## Review notes

FrankLuma processes SDR video locally. No login, network service or additional hardware is needed.

1. Choose Help → Open Demo Video, or Try the included demo in the empty window. The silent geometric demo is original footage included for review.
2. Choose Detect scenes & analyse. Select Side by side and press Play to compare the alternating exposure with the corrected preview.
3. Select a timeline frame and choose Split at playhead to create a scene. Enable Loop scene to repeat the selected scene. Pause playback and adjust correction strength in the inspector.
4. Choose Save Project to save editable settings. Projects reference the selected source video; they do not embed it.
5. Choose Export corrected video and select an output file in the macOS Save panel. H.264 and HEVC support MP4 and QuickTime; ProRes 422 supports QuickTime. The source is not changed.

The app uses App Sandbox with user-selected file access and read-only source bookmarks. It has no accounts, advertising, tracking, analytics or in-app purchases. The privacy policy is available from Help → Privacy Policy.

HDR, protected media and dimensions above 4096 pixels on either side are intentionally rejected with an explanation. Export re-encodes SDR video; codec availability depends on macOS. The demo is silent, so no audio is expected from that demo.

## Privacy and compliance answers to confirm in App Store Connect

- App Privacy: Data Not Collected. Source videos, projects and recovery metadata stay local; voluntary support emails are initiated by the user outside the app.
- Tracking: none. Advertising and third-party analytics: none.
- Encryption: Info.plist declares ITSAppUsesNonExemptEncryption = false. Confirm Apple's questionnaire against the shipped binary; the app implements no custom encryption.
- Age-rating answers should reflect the included geometric demo and application functionality, rather than user-selected private videos. Complete the current questionnaire; do not invent a rating in advance.
- Confirm agreements, paid-app banking/tax if charging, availability regions and applicable trader disclosures in the developer account.
- Review contact details must be supplied in App Store Connect. The public support email is not a substitute for those required fields.

## Screenshot capture brief

Capture the real release app using the included original demo. Use one consistent 16:10 canvas: 1280×800, 1440×900, 2560×1600 or 2880×1800 pixels. Avoid private filenames and dialogs covering the main interface.

1. Main editor after analysis, Side by side selected, with an obvious exposure difference.
2. Zoomed timeline with scene boundaries and per-scene correction controls.
3. Stable reference region and correction settings visible in the editor.
4. Export choices visible, showing the available formats.

Only describe behavior visible in the screenshots. Do not claim HDR, lossless output or universal codec support. Four screenshots are captured, framed at 2560×1600 and visually checked in `screenshots/`. Screenshot 3 shows the reference-selection controls; no selected region is claimed. Screenshot 4 shows the H.264 Save panel, while the caption accurately describes the other supported formats. See `screenshots/README.md` for provenance.

Apple references: [Product page](https://developer.apple.com/app-store/product-page/), [Mac screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/), [App Review](https://developer.apple.com/app-store/review/).
