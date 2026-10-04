# Releasing FrankLuma

FrankLuma is a native macOS 14+ app with a checked-in Xcode project. Open `FrankLuma.xcodeproj`, select the **FrankLuma** scheme and **My Mac**, then Run or Test. No project generator or third-party dependencies are required. The Swift package remains available for command-line development; the Xcode project is the canonical distributable app.

## Identity and build settings

- App and executable: `FrankLuma`
- Bundle ID: `com.sam.frankluma`
- Version / build: `1.0.0` / `7`, in `Configuration/Base.xcconfig`
- Team: `PLQG3PMFP8`, matching the existing TonePebble project and installed signing identities
- Deployment target: macOS 14.0
- Release architectures: Apple silicon and Intel (`arm64`, `x86_64`)
- Shared schemes: **FrankLuma**, **FrankLuma Developer ID**, **FrankLuma App Store**

The bundle identifier has a valid Mac App Store provisioning profile, confirmed by the build 3 export. An App Store Connect app record still needs to be created/confirmed in the developer account. A machine-specific `Configuration/Local.xcconfig` can override the development team. Keep export-options team IDs in sync when changing teams. Never put passwords or private keys in these files.

## Local build and tests

The current Store archive and remaining account steps are documented in `docs/app-store/HANDOFF.md`. `scripts/archive-app.sh app-store` verifies the archive against the current source version and prepared assets before attempting export.

The current local build is **1.0.0 (build 7)**. The marketing version is the public release version; increment the build number for each new App Store Connect upload. Use 1.0.1 for a subsequent bug-fix release and 1.1.0 for a subsequent feature release. Both fields feed the app's Info.plist and standard About panel from `Configuration/Base.xcconfig`.

```sh
zsh scripts/build-app.sh
open dist/local/FrankLuma.app
xcodebuild -project FrankLuma.xcodeproj -scheme FrankLuma \
  -destination 'platform=macOS' test
```

The build script deliberately uses ad-hoc signing and writes `dist/local/FrankLuma.app`, preserving the signed distribution app. It enables the same App Sandbox and Hardened Runtime as the release app, but it is **not** a Developer ID/notarised distribution build. Use a normal Terminal session: restricted agent shells can block Xcode macros, asset-catalog services and native media rendering.

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

Use the **FrankLuma App Store** scheme to Archive, then choose App Store Connect in Organizer. Alternatively, `zsh scripts/archive-app.sh app-store --allow-provisioning-updates` lets Xcode resolve provisioning, then archives and exports locally using `Configuration/AppStoreExportOptions.plist`; it does not upload. Xcode needs an Apple Development identity for the archive, an Apple Distribution identity and appropriate App Store provisioning for distribution. Configure the account in Xcode → Settings → Accounts and resolve any signing requirements in Signing & Capabilities. Developer ID signing is for distribution outside the App Store, not an App Store submission identity.

Before submission, confirm the App Store Connect record, version/build, support URL, published privacy-policy URL, screenshots, description, pricing and age rating; inspect Organizer's privacy report and validate the archive. Build 3 archive/export and provisioning have succeeded; App Store Connect listing, upload, availability and review remain pending.

The supplied privacy-policy URL is https://broadframestudio.com/frankluma/privacy/index.html. It is linked from the Help menu and Help window. Live verification on 4 October 2026 now returns HTTP 200 after a redirect to https://broadframestudio.com/frankluma/privacy/. The published policy is recorded in `docs/PRIVACY.md`; use the canonical URL in App Store Connect. Complete the App Privacy questionnaire to match the actual local-only, no-collection behaviour. Confirm export-compliance answers and applicable agreements, tax/banking details and regional trader disclosures in the developer account. TestFlight is an optional beta-distribution step, not a submission requirement. Separate Developer ID notarisation is not required for Mac App Store distribution.

## Permissions and privacy

`Resources/FrankLuma.entitlements` grants only:

- `com.apple.security.app-sandbox`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.files.bookmarks.app-scope` (persistent access to the user-selected source video)

The user grants file access through macOS Open/Save panels, drag-and-drop or Open With. Security-scoped access is retained for playback, analysis, preview and export and released after those operations finish. The source is read only by the app; the read/write entitlement is needed for user-chosen output files. Exports stage in Foundation's item-replacement directory and commit only after encoding succeeds. Failed/cancelled exports leave the existing destination intact. Diagnostics also use a Save panel.

FrankLuma does not record audio/video, access the Photos library, contact network services, use analytics, or request broad folder/Full Disk Access. There are no camera, microphone, Photos, network, automation, executable-memory or library-validation exceptions. Source audio is read from the selected movie; this does not require microphone permission. Projects and recovery checkpoints retain read-only security-scoped bookmarks for the selected source video. They do not grant access to arbitrary folders. Project files are retained under the Open/Save panel access for subsequent saves.

`Resources/PrivacyInfo.xcprivacy` declares no tracking or collected data. File timestamp access is declared with reasons `3B52.1` for user-selected source metadata and `C617.1` for recovery files inside the app container. Timestamps support source-change detection and recovery ordering. Revisit the manifest whenever adding preferences, disk-space checks, third-party SDKs or telemetry. A privacy manifest does not replace the public privacy policy or App Store privacy questionnaire. `docs/PRIVACY.md` records the published privacy policy.

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
- This early verification preceded the later build 2 notarisation described below. App Store submission has not been performed.

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
5. Export to a user-chosen file. Output is SDR H.264/HEVC in MP4 or QuickTime, or ProRes 422 in QuickTime. QuickTime preserves compatible source audio; MP4 preserves AAC and converts other audio to AAC (multichannel audio becomes stereo). The demo is intentionally silent.

The demo is original, procedurally generated geometric footage; its generator is `scripts/generate-demo.swift`. It contains no third-party artwork or licensed audio. HDR (PQ/HLG), protected media and dimensions above 4096 pixels on either side are rejected with instructions to make an SDR copy. Codec decoding depends on macOS. Do not advertise lossless export, general white-balance correction or HDR support.

Analysed sessions can be saved as `.frankluma` projects. Opening another video/project, closing the main window or quitting offers Save, Discard or Cancel for unsaved edits. Unsaved edits also have local recovery checkpoints; deliberate discard/closure clears the active checkpoint. Exports are saved videos, not editable projects. While a task is running, close/quit asks the user to wait or cancel from the main window first.

Remaining device/account checks: optionally beta-test the App Store build with TestFlight; exercise actual HDR/iPhone samples, hour-long/high-frame-rate footage, external and removable volumes, real disk-full/permission failures, macOS 14, and Intel hardware. The local automated tests do not replace those checks. The public support email is support@broadframestudio.com and is linked in Help. The support URL is https://broadframestudio.com/frankluma/help/index.html. Both support and privacy URLs are now verified live (HTTP 200 after index.html redirects).


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


### Format release checks

Exercise all five export choices with real H.264, SDR HEVC and SDR ProRes sources on macOS 14, Intel and Apple silicon. Verify variable frame timing, rotation, colour, AAC passthrough, PCM-to-AAC conversion, multichannel downmix and audio tails. Verify ProRes gradients retain more than 8-bit precision. HEVC availability is checked by the writer; unsupported exports should report an error without replacing the destination. HDR remains unsupported.

### Project release checks

Verify Save/Open/Save As projects in the sandboxed app, Finder opening, project drag-and-drop, source access across app restarts, bookmark tracking after moving the source, relinking a byte-identical copy, and rejection of a different source. Close/quit must offer Save/Discard/Cancel only for unsaved changes; cancelled saves and failed opens must preserve the session. Force-quit after edits and verify the recovery prompt restores cuts, per-scene reference regions, settings and export preferences. Keep one recovery for later, edit another session, and confirm the earlier recovery survives. Exercise disk-full/permission failures and autosave error reporting.

Local verification for project support: the command-line suite ran 63 tests with 62 passing and the hosted bundled-demo test skipped. A separate sandboxed app (`com.sam.frankluma.projectcheck`) opened a disposable source through the native Open panel, saved an 1,800-byte project, quit and reopened it with source-bookmark access, and restored 55% strength. Editing to 65%, cancelling the close confirmation, then saving retained the edits. Renaming the disposable source and using Relink Source Video preserved the settings and saved the new source location. Recovery reconstruction and independent checkpoint cleanup were exercised by the model integration tests; force-quit recovery and Finder/drop opening still need release-device checks. The production universal sandboxed app builds and its signature verifies.


## Build 3 submission preparation — 4 October 2026

- Version 1.0.0 (3), universal arm64/x86_64, macOS 14 minimum.
- Added Privacy Policy links to Help menu and Help window. Declared file timestamp reasons C617.1 and 3B52.1 for recovery files and user-selected source metadata. No tracking or collected data is declared.
- Fixed startup recovery presentation: check after the editor appears and attach the recovery alert as a sheet to the editor window. Force-quit/relaunch in the isolated sandboxed release-check app showed the automatic recovery sheet; Recover Session restored the unsaved 65% strength setting.
- Final hosted suite: 63 tests passed, zero failures or skips. Evidence: `.build/release-tests/Logs/Test/Test-FrankLuma-2026.10.04_21-09-12-+1100.xcresult`.
- Final archive: `.release/app-store-build-3-final/FrankLuma.xcarchive`. Export: `.release/app-store-build-3-final/export/FrankLuma.pkg`. Automatic provisioning succeeded. The export summary reports Apple Distribution signing, a Mac Team Store profile, both architectures, and the intended sandbox/bookmark entitlements.
- Listing copy, review guidance and A$19.99 one-time Australian launch price are prepared in `docs/app-store/LISTING.md`; four native-capture screenshots use the required 2560×1600 canvas.
- Website source already includes the privacy policy and help/support page; local links/assets and `npm run build` passed. Publication is deferred at the user’s request. Neither public URL is currently verified live.
- App Store Connect opened only its header in Safari, so app-record configuration, pricing, questionnaires and upload could not be completed in this session. No upload or submission occurred.

See `docs/app-store/STATUS.md` for remaining account and device work. Intel hardware validation has been waived by the user; the universal build still contains Intel support. TestFlight is recommended only as optional beta testing. The earlier notarised build 2 DMG does not include later export/project/release changes.


### Live website verification — 4 October 2026

The previously missing pages are now live: https://broadframestudio.com/frankluma/privacy/ and https://broadframestudio.com/frankluma/help/ return HTTP 200 over HTTPS. Their index.html URLs return HTTP 308 redirects to those canonical URLs, so the existing in-app privacy link works. The live policy matches local processing, project/bookmark metadata and recovery storage, and both pages provide the correct support email. All 26 linked pages/assets checked with curl returned HTTP 200. This supersedes the earlier website-publication blocker; no website source or deployment changes were made during verification. Mailbox delivery was not tested.


### Performance and real-footage verification — 4 October 2026

Settings previously recalculated every scene synchronously on the UI thread. Correction now runs off the main actor, coalesces slider changes for 120 ms, cancels superseded work and installs only the latest generation. The UI reports updating correction; movie/diagnostic export waits for a current curve. Project changes and recovery settings are recorded immediately. Unchanged scene results and existing frame registrations are reused; moving a boundary invalidates the affected range. Closing/replacing a session prevents an old calculation from repopulating it.

Spatial estimation finds at most six local neighbours without scanning the whole scene for each frame. Derived luminance/gradient arrays are retained only for the current frame and neighbours. Long shots use up to six worker tasks, processing 120-frame chunks with six-frame halos. Tests confirm the same correction values and reference indices as serial processing, including reuse across chunk boundaries. This bounds temporary per-worker frame preparation; stored thumbnails and correction fields still grow with video length.

Local optimized-engine stress measurements used distinct 96×56 thumbnails from the supplied footage, repeated into one 12 fps shot. Decoding/export time is excluded. The serial comparison already includes bounded neighbour/frame preparation; the parallel timing measures the additional multi-core improvement. These timings are observations on this Mac under concurrent test load, not product performance guarantees.

| Analysis workload | Serial initial | Parallel initial | Serial radius edit | Parallel radius edit | Serial mode edit | Parallel mode edit |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 minute / 720 frames | 4.75 s | 1.13 s | 3.35 s | 0.84 s | 3.31 s | 0.81 s |
| 20 minutes / 14,400 frames | 96.62 s | 22.07 s | 70.77 s | 17.34 s | 68.41 s | 16.67 s |

`My_Stop_Motion_Movie(22).mov` in Downloads is 3840×2160, 12 fps, 17.667 seconds, 212 frames. The original detector returned 16 cuts, including six spurious cuts during the rotating Hulk close-up. Two-frame lookahead now suppresses structural-only candidates surrounded by continuing motion while preserving the checked camera cuts, including frame 85. Ten boundaries remain: 10, 21, 45, 66, 75, 85, 107, 157, 174, 180. Only five small appearance descriptors are retained during detection. Very rapid same-colour edits during movement can remain ambiguous; reviewed/manual boundaries remain authoritative.

The moving close-up at 13.083–14.5 seconds still has insufficient stable background for global correction, and many of its spatial registrations fail. The inspector now explains insufficient global support and directs the user to a static reference or scene review. Do not claim this footage is completely corrected. A fresh analysis uses the revised detector; saved/reviewed project boundaries are preserved. The performance-only optimization produced exactly identical spatial diagnostics to the previous engine on all 17 original scene slices.

All 69 hosted tests passed, including project reference restoration, export codecs/timing/audio, latest-setting installation, cache invalidation and parallel/serial equivalence. Evidence: `.build/release-tests/Logs/Test/Test-FrankLuma-2026.10.04_22-04-52-+1100.xcresult`. The actual clip was exported to an ignored review MP4 and reanalysed: 3840×2160, 17.667 seconds, 212 frames. An optimized app builds successfully at `.build/performance-release/Build/Products/Release/FrankLuma.app`. User footage, generated frames, measurements and review movies remain in ignored `.build/performance/` and are not committed.

A real 10–20 minute 4K decode/export test, manual UI checks in the updated sandboxed build, macOS 14 checks and a new numbered Store archive remain release work. Full-resolution decode has not been optimized in this change; thumbnail/proxy decoding and further caching are candidates if that phase remains slow.


### Independent regional lighting targets — 4 October 2026

The frame-187–189 investigation found that the spatial estimator used neighbours after global exposure correction as local brightness targets. A gain appropriate to the blue background overcorrected the floor in some references, producing a subsequent floor pulse even though the global graph was nearly flat.

For stationary, colour-consistent patches, the estimator now derives targets from original linear-light samples. Steady scene uses a patch-specific shot median; Smooth flicker uses a robust temporal target that retains slow trends. Changes in patch colour exclude moving objects from these histories. Local gain/offset fits are normalised together to the same independent mean target, keeping contrast estimates consistent. Camera translation retains registered-reference consensus instead of applying a fixed-coordinate baseline. The spatial pass receives full-strength global stops and scales its residual once, preserving partial-strength behaviour. Reliable-anchor coverage controls unsupported-area fading without applying the anchor-confidence penalty twice; supported exposure residuals may reach 0.9 EV, with existing rendering/highlight safeguards retained.

The actual 4K source was rendered with both the previous and updated engines in Steady scene, using the original reviewed scene boundaries. Fixed blue-background and floor rectangles were measured from the full-resolution rendered images in linear light. Over displayed frames 187–189, squared adjacent EV-change energy fell by approximately 86% in the blue rectangle and 81% in the floor rectangle. The old floor brightening from frame 188 to 189 was +6.9%; the updated change is −2.8%. This is a regional, three-frame measurement, not a guarantee of whole-movie flicker removal. A roughly 5% floor change from frame 186 to 187 remains, so the supplied scene is improved but not completely stabilised.

The new regression covers independent blue/green lighting changes, the frame after a flash, both modes and 50% strength. Existing tests protect motion, translation, affine contrast, parallel chunk boundaries, codec exports and alternating flicker. All 70 hosted tests passed without relaxing their thresholds: `.build/release-tests/Logs/Test/Test-FrankLuma-2026.10.04_22-47-04-+1100.xcresult`. An optimized Release app builds successfully. The 14,400-frame correction stress test remains about 22.54 seconds initially, 17.76 seconds after a radius edit and 16.04 seconds after a mode edit; it excludes full-resolution decoding/export.

Ignored comparison images and the Steady scene review movie remain under `.build/performance/`. No user images or thumbnail data were committed. The prepared build 3 Store archive still predates these fixes and must be replaced with a new numbered archive before submission. No additional manual controls were added.


### Subject flash verification — 4 October 2026

Frame-by-frame review of the user's Smooth flicker previews exposed a limitation of the earlier background-only measurements: Iron Man's face and dark printed chest still pulsed. Matching patch texture now establishes correspondence independently of gain/offset, so supported lighting changes are not rejected merely because they change contrast or chromaticity. Only strongly correlated, non-flat texture permits the wider photometric fit and reduced usable-pixel threshold. Occlusions still require colour/structure and multi-neighbour support. Motion erosion now weakens uncertain boundary patches without discarding a well-matched surface simply because something beside it moves. The exposure-only field uses a less restrictive bending penalty and robust residual threshold to preserve a supported concentrated flash. Coarse fields, scene/radius limits, bounded neighbour counts, highlight protection and saturated/shadow rendering protections remain.

Verification reproduced Smooth flicker, 0.5-second radius, 100% strength/spatial correction, and a scene covering displayed frames 181–193. Actual 4K rendered previews were measured in linear light after downsampling each image to 96×56; face (x 44–50, y 18–22) and chest (x 44–51, y 27–33) rectangles were evaluated as well as the backdrop and floor. Comparing the previous algorithm with this revision, the sampled face's frame-187→188 change goes from +19.5% to −3.8%; the chest's change goes from +68.8% to +21.8%. The chest still visibly pulses. These are selected-region measurements, not whole-image accuracy or a claim of complete correction. The stronger alternative field fit was rejected because it over-darkened the face.

All 71 hosted tests passed, including a new dark textured subject flash beside a moving foreground region, both correction modes, existing camera translation and occlusion tests, serial/parallel equivalence, and native exports. Evidence: `.build/release-tests/Logs/Test/Test-FrankLuma-2026.10.04_23-17-10-+1100.xcresult`. The optimized Release app builds successfully. The new ignored Smooth flicker review MP4 preserves 3840×2160, 17.667 seconds and all 212 frames. Source footage and generated images remain uncommitted under `.build/performance/`.

The final optimized correction stress run took 1.34/1.01/0.91 seconds for initial/radius/mode calculations on 720 frames, and 24.60/20.32/18.36 seconds on 14,400 frames. These synthetic repeated-thumbnail workloads exclude decoding/export and are local observations under concurrent load. The additional texture checks cost some CPU time; main-thread responsiveness and bounded worker preparation are retained.


### Material-aware patch tone correction — 5 October 2026

The user's playback review confirmed that the previous correction was insufficient. Investigation found two additional limits: saturated/dark texture bypassed the fitted affine contrast map, and a coarse gain/offset map could match average brightness without matching the texture's actual contrast. A new rendered-pixel regression exposed that mismatch; increasing coarse contrast weighting was rejected because it failed both the new regression and an existing spatial test.

The default algorithm keeps matched affine estimates, original-frame chromaticity and measured within-patch colour spread on the 24×14 patch grid. Confidence-weighted interpolation excludes unsupported/occluded cells. Source-colour guidance limits spill across materials. Uniform matched surfaces use their direct patch targets; mixed dark printed regions blend towards the shared contrast fit, while heterogeneous bright regions retain more of the conservative map. Near-black and near-clipped pixels fade the new path, RGB is still multiplied by a common gain, and highlights remain bounded. No source pixels from other frames are blended. The existing coarse map remains the fallback. Camera/scene/radius restrictions and bounded workers remain in place; the new stored patch descriptors increase memory and CPU costs.

Five actual 4K previews (displayed frames 186–190) were measured using the user's Smooth flicker mode, 0.5-second radius, full strength/spatial correction and scene 181–193. The table shows each fixed rectangle's max/min linear-light brightness variation across those five frames, comparing main's `aaa3c75` with this preview. It is not a whole-image or playback quality score.

| Sampled area | Previous variation | Preview variation |
| --- | ---: | ---: |
| Blue background | 2.69% | 2.69% |
| Floor | 2.43% | 1.69% |
| Iron Man face | 4.34% | 6.00% |
| Iron Man chest | 21.75% | 7.20% |
| Hulk | 8.48% | 3.15% |
| Thor | 7.16% | 5.66% |
| Black Widow | 5.69% | 7.06% |
| Hawkeye | 9.41% | 6.55% |

The user reviewed the corrected movie on 5 October and approved this algorithm as the default. It improves the chest, Hulk and some background areas; face regions remain imperfect, so these measurements do not imply complete flicker removal. The algorithm has been promoted to main for build 4. Private footage, rendered images, measurement scripts and review movies remain ignored under `.build/performance/`.

The final hosted suite passes all 73 tests, including native black/colour/highlight protection, a rendered-pixel contrast regression, cached/parallel patch equivalence, and codec/audio/timing exports. Evidence: `.build/release-tests/Logs/Test/Test-FrankLuma-2026.10.05_00-26-19-+1100.xcresult`. The optimized preview build succeeds.

The final corrected-only preview movie preserves 3840×2160, 17.667 seconds and all 212 frames. Native live composition uses 1/12-second frames for this 12 fps source, so an accidental 30 fps preview cadence is not the cause. The optimized correction-only stress run took 1.40/1.13/1.03 seconds for initial/radius/mode calculations on 720 frames, and 27.53/22.71/20.79 seconds on 14,400 frames. This repeated-thumbnail benchmark excludes decoding/export; the extra patch descriptors add processing and stored memory, while the UI-thread and bounded-worker protections remain.


### Default Developer ID build 4 — 5 October 2026

The accepted patch-tone algorithm is on main. Version 1.0.0 build 4 archived and exported successfully using the Developer ID scheme. Export: `.release/developer-id-20261005-004624/export/FrankLuma.app`; default distribution copy: `dist/FrankLuma.app`. The universal binary has a valid Developer ID Application signature, Hardened Runtime and secure timestamp. All 73 hosted algorithm tests passed before promotion; no algorithm code changed during promotion.

Apple accepted the build 4 app notarisation using the user-supplied `TonepebbleNotary` profile: submission `9ccf84f0-d3d5-45bf-b221-9a7c63f609d1`, evidence `.release/notarisation-NCyS7t/result.json`. The app ticket is stapled and validated; Gatekeeper accepts the exported app and `dist/FrankLuma.app` as Notarized Developer ID.

The signed DMG was also accepted: submission `92b9e601-2c54-4ef2-851c-96569f0a0517`, evidence `.release/dmg-Kb2Dzo/notarisation.json`. Distribution installer: `dist/FrankLuma-1.0.0-build-4.dmg`, with adjacent SHA-256 checksum. Its ticket, signature, Gatekeeper assessment and disk-image integrity pass. The packaged app was additionally checked from a read-only mounted DMG: signature, ticket and Gatekeeper all pass. This is the current Developer ID release; App Store submission still requires a new Store archive.


## Submission review — 5 October 2026, build 5

Reviewed against Apple's current [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) and [common review issues](https://developer.apple.com/app-store/review/). The relevant checks are app completeness (2.1), truthful metadata/screenshots (2.3), Mac sandbox/packaging (2.4.5), privacy (5.1.1), and third-party content rights (5.2). No demonstrated policy violation was found in the sandbox, public links, local-only privacy behaviour, original review demo or native tool functionality. Approval remains Apple's decision.

Fixed a real completeness issue: cancelling an operation during a pending correction could mark an older curve ready for export. Cancellation now schedules/retains the current settings calculation in the background and keeps export gated. All 74 hosted tests pass, including the new cancellation regression; no skips/failures. Evidence: `.build/release-tests/Logs/Test/Test-FrankLuma-2026.10.05_01-06-45-+1100.xcresult`. The local build script also stages/verifies a fresh app at `dist/local/FrankLuma.app`, preserving the signed distribution app.

New Store archive: `.release/app-store-20261005-010856/FrankLuma.xcarchive`. Its app identity/version/deployment target, signature, intended sandbox entitlements, bundled demo and privacy manifest validate. Xcode export and a later retry fail with **No Accounts** and a missing **Mac Installer Distribution** certificate for team PLQG3PMFP8. Restore the Xcode account/signing before re-exporting; never upload the older build 3 package for these changes. Account record, price, agreements, questionnaires, review contact, upload and Apple's server validation remain outstanding. See `docs/app-store/STATUS.md` for the concrete handoff.

Developer ID build 5 exports at `.release/developer-id-20261005-011250/export/FrankLuma.app`; notarisation currently cannot find the previously working TonepebbleNotary profile. Build 4 remains the signed/notarised distribution in dist. Build 5 was launched, but native capture could not locate its window; no new interactive acceptance check is asserted.

Both canonical privacy/support URLs return HTTPS HTTP 200. Published retention/deletion text matches selected-file projects, local staging and recovery behaviour. No website edits/deployment occurred. Prepared screenshots use original geometric footage; practice media stays outside the app. The English listing limits claims to reducing SDR exposure flicker and accurately describes formats, motion/highlight limits, no accounts and local processing.

### Practice and long-video verification

Downloaded two CC BY 3.0 stop-motion clips into `PracticeFootage/`, with sources/attributions in `PracticeFootage/README.md`. Added clearly labelled synthetic whole-frame pulses and local contrast/exposure flashes without changing originals. The native audit verifies all four short sources through analysis, corrected preview, export and reanalysis. It also verifies a 600-second repeated-source 640×360/25 fps movie with exactly 15,000 frames through the complete decode/correct/export/reanalyse pipeline. Analysis plus correction is 37.66 seconds on this Mac. This includes decoding but excludes exporting; it does not demonstrate 4K long-video throughput. The corrected output is `.build/practice/10min/corrected.mp4`.

Extreme added flicker exposes extra auto-cuts in near-black credit fades (297, 298, 314), while the source has boundaries 293 and 396. This is recorded as a detection limitation with manual boundary refinement, not hidden by a global flicker score. Native audit source and generators are in `scripts/validation/`; build with `scripts/build-practice-audit.sh`. Research datasets are linked for further evaluation, with media licensing/access still to confirm. No research model, private video, licensed media or generated test movie is committed or bundled.


### Same-background scene detection and final build 6

The group-to-single-figure transition at zero-based frame 193 (displayed frame 194) was missed because most background pixels did not change. Whole-frame median structure and colour population diluted the subject replacement. Added a coarse 3×3 regional palette comparison using exposure-normalised RGB, sufficient usable colour samples, a settled preceding region and three following frames confirming the new palette. Only six tiny appearance descriptors are retained; whole-frame detection and its ongoing-motion suppression remain. Brief regional colour/exposure flashes and translation are covered by regressions. This is conservative subject/camera-change detection, not semantic object recognition or detection of every edit.

Native 4K verification now finds boundaries `[10, 21, 45, 66, 75, 85, 107, 129, 143, 154, 157, 174, 180, 193]`: all original accepted cuts plus four independently inspected camera/subject changes, including the requested cut. No additional cuts appear during continuous Hulk motion. The corrected export preserves all 212 frames, 3840×2160 and 17.667 seconds; evidence `.build/practice/lego-finalcuts.log`. The three-frame local-flash practice clip returns to zero cuts and retains all 596 frames through export/reanalysis; evidence `.build/practice/local-finalcuts.log`. Near-black credit fades in the deliberately extreme whole-frame flicker variant remain a known editable-boundary limitation.

Reanalysis previously preserved every old cut even when it was untouched automatic output. It now refreshes automatic boundaries and inherits each resulting shot's existing settings. A manually altered boundary set remains authoritative. In the new app, Analyse again updates untouched automatic cuts; use Reset cuts after reanalysis to explicitly replace a manually reviewed set. Project opening still restores saved cuts.

Final Store archive: `.release/app-store-20261005-101753/FrankLuma.xcarchive`, version 1.0.0 build 6. Archive succeeds; export still fails with No Accounts and missing Mac Installer Distribution signing. No build 6 package/upload is claimed. The testable optimized app is `dist/local/FrankLuma.app`; local builds preserve the notarised build 4 distribution. All 77 hosted tests pass with zero failures/skips. Final test evidence: `.build/release-tests/Logs/Test/Test-FrankLuma-2026.10.05_10-17-51-+1100.xcresult`.

Build 7 adds selected-scene playback looping. The local app is ad-hoc signed; the latest App Store archive remains build 6 and the verified notarised distribution remains build 4.
