# FrankLuma

A native macOS app that reduces exposure flicker in stop-motion videos. Built with SwiftUI, AVKit, AVFoundation, and Core Image. No third-party dependencies or uploads.

Historical validation sections below retain the old Video Normaliser name and artifact filenames.

## Open the app

Open `dist/FrankLuma.app`. You can also copy that app to Applications. The local build supports Apple silicon and Intel, requires macOS 14 or later, and is ad-hoc signed for development. Developer ID and App Store release schemes are available in `FrankLuma.xcodeproj`.

1. Open or drop a video into the window, then click **Detect scenes & analyse**.
2. Click or drag on the exposure graph to scrub. The white playhead, frame number, preview, and selected scene stay in sync. Use **← / →** to step exactly one source frame and **Space** to play or pause. First/last-frame buttons are beside the transport controls.
3. Click a scene band or choose a scene in the inspector. Orange cut handles snap to source frames as you drag them. Start/end frame steppers in the inspector provide precise boundary edits. Neighbouring boundaries cannot cross, and every scene retains at least one frame.
4. Use **Split at playhead** to make the current frame the first frame of a new scene. The new scene inherits its parent's settings. **Merge previous** keeps the earlier scene's settings. **Reset cuts** restores automatic cut positions and maps existing settings to the new scenes.
5. Adjust the selected scene's **strength**, **smoothing radius**, **spatial correction**, and **mode**. **Smooth flicker** retains gradual lighting changes; **Steady scene** uses one median exposure target within that scene and also reduces intentional fades. Set strength to zero to leave a scene uncorrected.
6. Optionally choose **Select reference area** and drag over a static background in the preview. This measures a separate reference for the selected scene without changing scene boundaries or other scenes' settings. A reference is cached across the full clip so subsequent boundary adjustments remain valid. **Use whole frame** removes that scene's custom reference.
7. **Apply these settings to all scenes** copies the selected scene's mode, radius, strength, and reference area to every scene. Otherwise, each scene's settings remain independent.
8. Switch **Original / Corrected / Side by side** to compare, then **Export** to save a corrected QuickTime movie with the original asset's audio. Cancellation does not replace an existing destination. The source stays untouched.

The exposure graph shows a **dashed cyan original** line and a **solid green corrected** line on one EV scale. Both use the same original median baseline within each scene and that scene's selected reference measurement. Original exposure is the median change across the selected stable patches. The corrected line is the predicted original exposure plus the global correction; local corrections appear in the diagnostic preview. It is not a second measurement of the encoded export. Lines break at scene boundaries.

**Timeline zoom:** hold **⌘** and use the mouse wheel, or pinch on the trackpad, to zoom around the pointer (matching TonePebble). Scroll to pan, or use the range slider. The magnifier buttons also zoom; **Fit** restores the whole clip. At close zoom, alternating vertical slices mark actual source frames, with frame numbers when space permits. Click within a slice to select that frame; orange cuts still snap to frame boundaries.

**This frame** shows the correction at the playhead in exposure stops: positive brightens and negative darkens. This is the global component used for preview and export; spatial correction adds a position-dependent adjustment. Many frames need only small adjustments. For a constant exposure target, choose **Steady scene**; Smooth flicker deliberately preserves gradual changes.

**Side by side** displays original on the left and corrected on the right, rendered from the same source frame in one player. Scrubbing, frame stepping, and playback share a single timeline and audio track. Select reference areas on the left image. Export always produces a single corrected video at the original dimensions, regardless of the comparison view.

Re-analysis preserves manual boundaries and settings when the source frame timestamps are unchanged. A 0.5-second radius is a starting point; larger radii smooth slower fluctuations. Settings and boundaries are held in memory for the current session; project saving is not yet included. Opening another clip, closing or quitting prompts before discarding an analysed session. Help → FrankLuma Help explains supported formats and controls; Help → Open Demo Video loads an original built-in sample. SDR only, up to 4096 pixels per side; HDR and protected sources must be converted first. Exports are re-encoded H.264 QuickTime movies, not lossless copies.

## Build

Requires Xcode and its command-line tools. Run:

```sh
zsh scripts/build-app.sh
```

The script builds the universal sandboxed app through Xcode and copies it to `dist/FrankLuma.app` with an ad-hoc signature. Open `FrankLuma.xcodeproj` in Xcode to run, test or archive. See [release and signing instructions](docs/RELEASING.md) for Developer ID, notarisation and App Store distribution. `Package.swift` remains available for command-line development.

## Tests

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift test --disable-sandbox
```

The suite checks moving-subject rejection, smooth lighting ramps, colour and structural cuts, exposure flashes, independent scene baselines in both modes, manual split/merge, frame snapping with variable timestamps, boundary clamping, independent reference areas, clipped images, and per-frame correction lookup. The integration test creates a video with alternating brightness, analyses it, exports the correction, and checks that adjacent-frame exposure variation falls by at least 80%, with unchanged dimensions, duration, frame count, and frame rate.

The mathematical suite includes measured patch regressions for source frames 12–14, 40–44, and 79–85; constant-light moving subjects; nonuniform flashes; isolated outliers; and movie timescales that preserve audio sample ends. The fixture contains full-resolution linear-light tile averages, not video images. These tests check estimated corrections; actual encoded output is checked separately.

The AVFoundation integration test requires a normal Terminal/Xcode session. The restricted agent shell cannot access the video services, so native diagnostic apps perform export checks in this environment.

For just the mathematical tests in an environment without video services, append `--skip testRealVideoAnalysisAndExport` to the test command.

## How correction works

Scene detection uses whole-frame appearance independently of the selected reference area. It removes a global exposure step before comparing image structure and colour, helping distinguish flashes from cuts.

Exposure measurement uses filtered 192 × 112 floating-point linear-sRGB images, averaged into 336 patches. Within each scene, it rejects clipped/dark patches and patches whose temporal changes disagree with the common lighting change. Each frame is compared with scene-local patch baselines; estimates are not accumulated between frames. Manual boundaries and reference changes recompute patch selection.

**Smooth flicker** uses a trimmed moving mean within each patch, so isolated outliers have less influence on neighbouring targets. **Steady scene** uses a median target. Targets never cross scene boundaries. In shots with small exposure changes, correction uses the median across all consistent patches to avoid suppressing subtle flicker. As the scene exposure range increases from 0.15 to 0.25 EV, it blends towards the conservative edge of agreement from the closest-matching patches. A broader patch check then limits overshoot, allowing 0.015 EV measurement tolerance. These are heuristics, not universal quality thresholds. Correction is limited to ±2 EV, then multiplied by strength. Uneven lighting can still leave residual flicker. Fewer than 12 usable patches produces zero correction and an inspector notice.

Core Image applies one common linear RGB gain, `2^(globalEV + localEV)`, limited to ±2 EV. A per-pixel highlight safeguard reduces brightening before channels clip. Preview and export use the same assembled curve and spatial fields. Export reads and writes each source video sample with its presentation timestamp and duration, keeping the final video frame independent of a longer audio tail. Audio packets pass through without re-encoding. The movie timescale accommodates the video and audio clocks. Export uses H.264 with the source dimensions and orientation.

## Earlier global-only validation (historical)

A native diagnostic decoded all 86 frames of the supplied 4K clip and both exports. Fixed background tile means were measured from full-resolution sRGB pixels using 0.2126 R + 0.7152 G + 0.0722 B. The source and saved output use the same patch locations. This reproduced bright overshoot in the earlier export at frame 13 and near the end. The earlier whole-frame re-analysis did not expose that problem and should not be treated as a perceptual quality check.

The check used a wall rectangle at x = 3/24 … 21/24 and y = 1/14 … 4/14 of the displayed image. Adjacent-frame RMS luma change (0–255) was:

| Frames (zero-based) | Source | Earlier export | Revised export |
| --- | ---: | ---: | ---: |
| 0–10 | 1.883 | 0.697 | 1.544 |
| 11–17 | 14.170 | 5.273 | 1.086 |
| 25–37 | 1.159 | 1.044 | 0.955 |
| 38–49 | 3.091 | 0.824 | 1.719 |
| 50–85 | 3.069 | 0.668 | 0.619 |

The revised check used Smooth flicker, 100% strength, 0.5-second radius and automatic whole-frame patch selection, with boundaries 11/18/38/50. The earlier user export had its own settings, so the table is an output comparison, not an isolated algorithm benchmark. These are independently chosen patches, not the unknown coordinates from the external review.

All 86 output video timestamps and durations match the source, including the final 1/12-second sample. Video track duration is 7.166667 seconds, with 12 fps average. All 315 audio packet timestamps, durations and payload hashes match; the separate audio tail ends at 7.250023 seconds. A 48-frame variable-duration fixture (1/24, 2/24 and 3/24-second samples) also retains every timestamp and duration. A synthetic alternating-exposure export reduced adjacent-frame RMS from 1.029 to 0.063 EV (about 94%). All 27 mathematical tests pass, including opening-shot undercorrection and frame-13 validation regressions. The updated UI was checked for scene analysis, stable-patch count, side-by-side preview and frame stepping.

The revised export reduces that wall-patch overshoot. Improvements vary across patches; it does not remove every lighting fluctuation, and some patches retain more flicker than the previous, more aggressive correction. Camera-motion frames 18–24 are excluded from background-patch comparisons. That revision had no motion alignment; the spatial revision below adds bounded translation alignment.

## Opening-shot refinement and colour audit

The next revision removes the small-change deadband and checks large corrections against additional consistent patches. With the same 0.5-second radius and 100% strength, the neutral wall on the right of the opening shot (x = 20/24 … 23/24, y = 2/14 … 6/14) measures **3.419 source → 2.326 previous update → 0.631 refined update** in adjacent-frame RMS luma. This is a different, neutral patch from the earlier blue-background measurement. It is not the unknown patch used by the external reviewer.

In the original top-wall patch for scene 2, RMS falls from 1.086 to 0.254. Frames 12/13/14 measure 186.99/186.68/187.02 after export; frame 13 is no longer a bright outlier there. Frames 25–37, 38–49 and 50–85 have unchanged correction curves and decoded patch measurements compared with the previous update. Video sample timing and audio packet timing/content still match exactly.

`dist/Exposure validation.json` contains patch coordinates, per-frame brightness, RGB ratio measurements, timing results, and the opening shot's estimated error, agreement, requested/applied EV and gain, validation limit, and rejection reason. “Confidence” is the fraction of patches agreeing within 0.05 EV, not a calibrated probability. In this shot, requested corrections are now applied without the quantile suppression; frame 9 receives about +0.074 EV.

The colour audit compared a zero-correction export alongside both corrected exports. Decoded source and output buffers use matching Rec.709/HDTV colour-space and transfer attachments; the untagged source's colour metadata is inferred by VideoToolbox. The code applies a single exposure gain to linear RGB. Small colour differences also appear in the zero-correction export, confirming a contribution from the decode/render/encode path. Exposure correction can additionally affect ratios measured in nonlinear encoded RGB. This does not establish that every colour fluctuation is explained or fixed; no separate colour correction was introduced.

## Limits

- The spatial model corrects broad exposure changes. Sharp moving shadows, local specular changes and white-balance shifts remain difficult; it is not a relighting or colour-stabilisation model.
- Large moving objects, camera moves, and intentional abrupt lighting changes can confuse the estimate. Select a static reference area and inspect the preview.
- Clipped highlights and lost shadow detail cannot be recovered. Scenes with too little stable content receive no correction.
- Scene-cut detection is heuristic. Similar-looking cuts, fades, and large camera moves may need manual split/merge corrections.
- SDR footage is the initial target. HDR fidelity, unusual codecs, multi-video-track assets, and variable-frame-rate output need further validation.
- Export re-encodes video to H.264; it is not lossless. Image sequences, batch processing, and project saving are not included in this version.


## Spatial correction revision

The app retains global correction, then compares corresponding regions in nearby frames within each reviewed shot. It registers 96 × 56 linear-sRGB thumbnails using exposure-resistant gradients, checks local appearance and chroma, and rejects motion, occlusion, clipped pixels and unreliable dark samples. Integer translation alignment is bounded; rotation, parallax and large camera moves can fail and receive global correction only. Manual reference areas constrain eligible background samples.

A robust, regularised 9 × 6 grid fits the remaining log-exposure error. Median references use up to six nearby aligned frames; they are symmetric in time and exclude the frame being corrected. Regularisation, confidence fade, a ±0.6 EV local limit and adjacent-node limits constrain the field. No image from another frame is blended into the output. The spatial strength slider is independent per scene. Set it to zero for a global-only comparison.

The preview menu adds **Confidence mask**, **Motion mask** and **Correction field**, alongside Original, Corrected and Side by side. White confidence means stronger evidence; white motion means rejected or unsupported content, not a semantic segmentation of figures. Field colours show red for brightening, blue for darkening and green for zero. **Save diagnostics** records frame time, scene start, global gain, requested/fitted local EV, masks, alignment and predicted patch brightness. Alignment reference indices are relative to the scene start. Predicted values precede pixel-level highlight protection and encoding; they are not measurements of the exported video.

Analysis and export now convert orientation metadata explicitly between video and Core Image coordinates. The original display matrix is retained. Reviewed manual merges also replace automatic boundaries for spatial references.

The 35 mathematical tests pass, including uniform flicker, an isolated spatial flash with no temporal bleed, a moving subject under constant lighting, a camera cut, translation registration, manual cut merging and orientation conversion. The hardware-dependent integration test is run through a native diagnostic application in this restricted environment.

### Reproduce the clip audit

`scripts/validation/SpatialAudit.swift` is the native validation harness for the two supplied files. Its paths and fixed background rectangles are explicit in the source. It exports a separate candidate, decodes all 86 frames at full resolution, measures multiple regions per shot, and creates paired contact sheets. Build it with `zsh scripts/build-spatial-audit.sh`, then open `.build/Spatial Final Audit.app`; AVFoundation video services are unavailable in the restricted shell. After it completes, run `python3 scripts/validation/summarise_spatial.py` from this directory. This writes the named candidate and measurements below without modifying either supplied input.

The validation uses Smooth flicker, radius 0.5 s, global/spatial strength 100%, and reviewed boundaries 11/18/38/50. Automatic detection also proposes a boundary at frame 24 during camera movement; this needs manual review. The frame-13 flash is not classified as a cut. These independently chosen patches differ from the external review's unknown coordinates.

### Final spatial candidate results

Candidate: `dist/Video Normaliser — Spatial Candidate.mov`. Detailed coordinates, per-frame measurements, colour ratios and media checks: `dist/Spatial validation/Measurements.json`. Requested/fitted gains, masks, references and measured output regions: `dist/Spatial validation/Frame diagnostics.json`. Paired contact sheets cover all 86 frames. Contact sheets use the encoded landscape view for inspection; the movie preserves its supplied 90° display rotation.

The figures below average adjacent-frame RMS luma changes across four or five static regions per shot, in 0–255 sRGB luma. Each region has equal weight. This is a multi-region summary, not a whole-frame average. Two boxes visibly crossed by figures are excluded from the summary but retained and flagged in the JSON: right blue at 25–37 and lower-right wall at 50–85. Camera-movement frames 18–24 are excluded from static statistics.

| Frames | Source | Supplied normalised | Spatial candidate | Reduction vs source | Worst candidate adjacent jump |
| --- | ---: | ---: | ---: | ---: | --- |
| 0–10 | 2.27 | 1.40 | 0.90 | 60% | 1.95% · blue left · frame 10 |
| 11–17 | 19.03 | 6.71 | 1.33 | 93% | 4.78% · left floor · frame 13 |
| 25–37 | 1.20 | 0.67 | 0.52 | 56% | 1.55% · upper blue · frame 28 |
| 38–49 | 2.89 | 1.24 | 0.59 | 80% | 2.89% · upper blue · frame 44 |
| 50–85 | 2.87 | 0.85 | 0.65 | 77% | 10.79% · left blue · frame 80 |

Frame 13 compared with the mean of frames 12 and 14, using independently selected boxes:

| Region | Candidate frames 12 / 13 / 14 | Frame-13 deviation |
| --- | --- | ---: |
| upper wall | 193.42 / 192.31 / 193.29 | -0.54% |
| lower left wall | 160.42 / 158.69 / 161.33 | -1.35% |
| right wall | 175.62 / 176.15 / 175.71 | +0.27% |
| left floor | 182.55 / 174.03 / 178.06 | -3.48% |
| upper left wall | 175.42 / 175.04 / 175.12 | -0.13% |

**This is a useful improvement, not a complete acceptance pass.** All four wall boxes meet the provisional 2% neighbour-reference target at frame 13 simultaneously. The floor does not: its remaining dip is 3.48%, with a 4.78% jump from frame 12. The earlier preliminary 1.75% floor estimate used a coarser, different region and does not describe this precise floor box. Do not substitute that preliminary number for this result.

Remaining failures and limits:

- The opening wall improves, but the opening floor's RMS rises from 0.79 in the source to 1.22 in the candidate (the supplied output was 2.27). This is a real local regression despite the shot's improved average.
- At frames 38–49, the upper blue background retains a 2.89% adjacent jump at frame 44. Neutral wall regions are much steadier.
- At frame 80 the left blue background retains a 10.79% jump (5.10 luma levels). Its correction confidence is zero at that frame; the model falls back instead of extrapolating a strong gain. This remains visible variation, and excludes an all-patch 2% claim. The final shot's neutral wall and floor boxes remain below 1% adjacent jumps.
- Frames 18–26 lack enough aligned neighbours for local correction. The translation model cannot reliably handle this camera move and changing occlusions. The global-only fallback is intentional, but it does not solve those frames.
- Colour instability is not fixed. For example, upper-wall B/G adjacent RMS at 11–17 is 0.00253 source, 0.00269 supplied, 0.00406 candidate. The algorithm applies a common gain in linear RGB; nonlinear RGB ratios can nevertheless change, and encoding contributes. These measurements do not isolate the cause or establish colour fidelity.
- The logged `clippedFraction` means pixels with **any encoded channel ≥250**, a near-white diagnostic, not proof of hard clipping. In the frame-13 floor it rises from 0.7% source to 6.9% candidate. The highlight limiter prevents requesting a linear channel above 0.995 when brightening, but does not guarantee unchanged encoded highlight detail. Floor highlights and figure reflections need visual judgement.

All 86 source video PTS and sample durations match exactly; both video tracks are 7.166667 s at 12 fps. All 315 audio packet PTS, durations and compressed payload hashes match. The audio tail remains 7.250023 s. The complete display matrix matches, and SHA-256 checks confirm both supplied files are unchanged. The workspace input copies used for the final native audit are byte-identical to the supplied files.

Visual review: all 86 source/candidate frame pairs were inspected in contact sheets, with a larger frame-13 detail and additional inspection of the changed camera-move shot after the final merge fix. No obvious new seams, halos or duplicated poses were seen at those inspection sizes. This is not a full-resolution visual guarantee. The exported candidate was also started at normal playback speed in the app and observed through the end, but the computer-control interface provides intermittent still captures; continuous perceptual playback review remains incomplete. The tool subsequently failed with a native-pipe startup error. A human normal-speed review is still needed, particularly for the floor and blue-background residuals.

The final UI build also decodes paused source frames before applying the correction, avoiding video-composition cadence rounding during still comparison. This last preview-only change compiles; its GUI recheck was blocked by the app-control failure. It does not alter the exported candidate or its measurements. The app's confidence mask, field view, side-by-side mode, frame stepping and manual merge were exercised before that change.

### Preview frame-boundary correction

The screenshots of `My_Stop_Motion_Movie(16) 2.mov` show the preceding pose repeated at UI frame 14 (zero-based 13), with that frame's +0.38 EV correction applied. Paused previews now request a time inside the selected sample, using the next timestamp or final video end, and choose the correction from `AVAssetImageGenerator`'s returned actual timestamp. This prevents associating a requested frame's gain with a different decoded pose. Original and corrected stills share the same decoded image. The 37 mathematical tests pass, including 12 fps boundary and variable-duration cases. The app builds successfully.

The new source and supplied export have matching video timestamps and durations (86 frames, 12 fps). Their pixel-level comparison and the corrected preview's GUI recheck remain pending: shell AVFoundation decoding fails with -11821/-12911, and computer control fails with a native-pipe startup error. This preview correction does not change the export algorithm; do not treat it as verification that the reported exported flash is fixed.

### Matched-energy spatial correction (4 October 2026)

The spatial patch matcher now uses robustly weighted corresponding linear luminance totals instead of median pixel ratios. This reduces the influence of dark recesses on textured floors without increasing global strength. Existing motion rejection, alignment, shot boundaries and correction limits remain. A textured-background regression test reproduces the previous 3.33% overshoot and passes below 0.6% with the change.

The release app at `dist/Video Normaliser.app` was rebuilt and its signature verified. Test result: 38 passed; one native encode integration test failed with AVFoundation “Cannot Encode” in this environment. Native audit launch also failed, so native export and playback verification remain pending.

See [the regional audit](dist/Energy%20validation/report.html) for full results and limitations. In the controlled software replay, left-floor RMS at frames 11–17 falls from 3.22 to 1.68. The separately encoded estimator preview places all five frame-13 background boxes within 1.6% of the mean of frames 12 and 14. Remaining defects include a 2.04% floor step, a 6.71% blue-background jump near the end, and small regressions in several individual patches. This is not a complete acceptance pass.

`dist/Video Normaliser — Estimator Preview.mov` is a separately named software-rendered review artifact; it is not a native app export. Its 86 video timestamps/durations, 12 fps, orientation, and all 315 audio payloads/timestamps/durations match the landscape source. Inputs remain untouched. Software thumbnail resampling and colour conversion differ from Core Image, so these measurements must not be presented as verified native-output results.

Audit helpers in `scripts/validation/` decode through locally installed FFmpeg libraries using x86_64 Python, fit cached frames with the production Swift estimator, render a controlled CPU comparison and measure several regions per shot. `software_light.c` is audit-only code. Full source/output patch coordinates and measurements, fitted/requested gains and colour-ratio diagnostics are saved in `dist/Energy validation/`.

### Native tone correction audit (4 October 2026)

The user's UI frames 13–15 exposed a failure that region averages concealed. In the centre floor of the old native paused preview, frame 14's bright P90 was 248.5 while neighbouring frames were 227.8/225.6; its dark P10 was 125.8 versus 140.9/141.6. The average was already similar. Exposure-only correction cannot simultaneously match both ends of that distribution.

The spatial matcher now considers a constrained affine luminance fit when textured correspondences support a substantially better fit than scalar exposure. Gain and offset are fitted jointly over the spatial grid so each patch constrains both its mean and contrast. Deep shadows and strongly coloured pixels use an exposure-only field; neutral midtones receive the tone adjustment. RGB channels still share one multiplier. No white-balance estimator or independent RGB adjustment was added. Temporal correspondence, scene isolation and confidence fallback remain; this is not a whole-shot temporal optimisation or a claim that reference switching is solved.

The revised native paused preview's centre-floor P90 at frame 14 is 232.2 and P10 is 140.2. The diagnostic field now visualises effective per-pixel gain, including tone mapping and highlight protection, rather than just the fitted exposure component. The timeline remains explicitly global-only.

The native export is `dist/Video Normaliser — Tone Corrected.mov`. See [the full native audit](dist/Tone%20validation/report.html), including all 86 before/after frame pairs and full-resolution regional measurements. Both baseline and revised movies were exported through production AVFoundation/Core Image code, using the landscape source, Smooth flicker, 0.5 s, strengths 100%, and reviewed zero-based boundaries 11/18/38/50.

In scene 2, native exported floor P90 adjacent-frame RMS changes from **16.08 → 1.23** (left), **14.02 → 3.59** (centre), and **17.86 → 1.61** (right), in 0–255 sRGB luma. Dark P10 RMS improves from 12.03 → 2.33, 10.14 → 2.08 and 7.04 → 3.79 respectively. The left-floor mean RMS regresses **1.37 → 3.10**, and centre-floor mean RMS regresses 1.11 → 1.78. These remain real defects despite the reduced contrast pulse. Final-shot floor mean RMS also increases 0.53 → 0.71. Blue-background residuals and camera-move limitations remain. This is not a complete flicker-removal acceptance pass.

All 86 video packet timestamps and durations match the source; dimensions remain 3840 × 2160 at 12 fps. All 315 audio packet timestamps, durations and compressed payload hashes match. All frame pairs were inspected in contact sheets without obvious new seams or duplicated poses at that size. Full-resolution continuous perceptual playback needs human review.

42 tests pass in a native-service-enabled shell, including the real-video integration test, an additive-light/texture regression, and renderer tests for black preservation, saturated colours, linear chromaticity and highlight limits. The integration timing helper now ignores zero-sample compressed-reader markers and derives omitted media durations from presentation intervals; it asserts 48 actual video samples. Restricted shells cannot reliably run Core Image/AVFoundation tests.

Reproduction: `zsh scripts/build-consistency-audit.sh`, then `.build/consistency/audit <source.mov> <new-output-directory> --export`. This clip-specific harness uses the reviewed boundaries above. `.build/consistency/measure <movie> <output-directory>` decodes full-resolution native exports and records regional means, P10/P90, colour ratios and near-white fractions. `scripts/validation/check_consistency_media.py <source> <export>` independently checks packets with the locally installed ffprobe. The report generator consumes `dist/Tone validation/before.json` and `after.json`.
