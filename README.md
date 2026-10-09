# FrankLuma

A native macOS app that reduces exposure flicker in stop-motion videos. Built with SwiftUI, AVKit, AVFoundation, and Core Image. No third-party dependencies or uploads.

Historical validation sections below retain the old Video Normaliser name and artifact filenames.

Correction work is paused. For the current implementation, experiment results and next steps, read the [correction work handoff](docs/CORRECTION_WORK_HANDOFF.md).

## Open the app

The signed distribution app is `dist/local/FrankLuma.app`; it can be copied to Applications. `scripts/build-app.sh` creates a separate ad-hoc development app at `dist/local/FrankLuma.app`, preserving signed releases. Both support Apple silicon and Intel and require macOS 14 or later. Developer ID and App Store release schemes are available in `FrankLuma.xcodeproj`.

1. Open or drop a video into the window, then click **Detect scenes & analyse**.
2. Click or drag on the exposure graph to scrub. The white playhead, frame number, preview, and selected scene stay in sync. Use **← / →** to step exactly one source frame and **Space** to play or pause. First/last-frame buttons are beside the transport controls.
3. Click a scene band or choose a scene in the inspector. Orange cut handles snap to source frames as you drag them. Start/end frame steppers in the inspector provide precise boundary edits. Neighbouring boundaries cannot cross, and every scene retains at least one frame.
4. Use **Split at playhead** to make the current frame the first frame of a new scene. The new scene inherits its parent's settings. **Merge previous** keeps the earlier scene's settings. **Reset cuts** restores automatic cut positions and maps existing settings to the new scenes.
5. Adjust the selected scene's **strength**, **smoothing radius**, **spatial correction**, **colour correction**, and **mode**. **Smooth flicker** retains gradual lighting changes; **Steady scene** uses one median exposure target within that scene and also reduces intentional fades. Set strength to zero to disable automatic correction for a scene; manual frame adjustments still apply.
6. For an individual problem frame, scrub or step to it and use **Frame adjustment** to add −2 to +2 EV on that source frame only. The slider pauses playback, updates the preview without re-analysis, and retains the adjustment when scene settings or boundaries change. Purple diamonds mark edited frames; click one or use the previous/next adjusted-frame buttons to return to it. **Reset this frame** removes its manual adjustment. Enable **Show nearby frames** to compare one or two frames on either side, with the current frame highlighted in the centre. The comparison fills the main preview: previous frames on the left, the current frame in the centre, and next frames on the right. Switch between Original and Corrected, and click a frame to select it. Neighbours across a scene boundary carry a scene label. Positive EV brightens and negative EV darkens, with highlight protection. Frame edits are saved in projects and recovery checkpoints.
7. Optionally choose **Select reference area** and drag over a static background in the preview. This measures a separate reference for the selected scene without changing scene boundaries or other scenes' settings. A reference is cached across the full clip so subsequent boundary adjustments remain valid. **Use whole frame** removes that scene's custom reference.
8. **Apply these settings to all scenes** copies the selected scene's mode, radius, strength, and reference area to every scene. Otherwise, each scene's settings remain independent.
9. Switch **Original / Corrected / Side by side** to compare, then **Export** to choose H.264 or HEVC in MP4/QuickTime, or ProRes 422 in QuickTime. Choose Standard or High quality for H.264/HEVC. QuickTime preserves compatible original audio; MP4 preserves AAC and converts other audio to AAC (multichannel audio becomes stereo). Cancellation does not replace an existing destination. The source stays untouched.

The exposure graph shows a **dashed cyan original** line and a **solid green corrected** line on one EV scale. Both use the same original median baseline within each scene and that scene's selected reference measurement. Original exposure is the median change across the selected stable patches. The corrected line is the predicted original exposure plus the automatic global correction and manual frame exposure; local corrections appear in the diagnostic preview. It is not a second measurement of the encoded export. Lines break at scene boundaries.

**Timeline zoom:** hold **⌘** and use the mouse wheel, or pinch on the trackpad, to zoom around the pointer (matching TonePebble). Scroll to pan, or use the range slider. The magnifier buttons also zoom; **Fit** restores the whole clip. At close zoom, alternating vertical slices mark actual source frames, with frame numbers when space permits. Click within a slice to select that frame; orange cuts still snap to frame boundaries.

**This frame** shows the correction at the playhead in exposure stops: positive brightens and negative darkens. Automatic and manual values are shown separately. These are the whole-frame exposure components used for preview and export; spatial correction adds a position-dependent adjustment. Many frames need only small adjustments. For a constant exposure target, choose **Steady scene**; Smooth flicker deliberately preserves gradual changes.

**Side by side** displays original on the left and corrected on the right, rendered from the same source frame in one player. Scrubbing, frame stepping, and playback share a single timeline and audio track. Select reference areas on the left image. Export always produces a single corrected video at the original dimensions, regardless of the comparison view.

Re-analysis preserves manual boundaries and settings when the source frame timestamps are unchanged. A 0.5-second radius is a starting point; larger radii smooth slower fluctuations. Save Project (⌘S) stores scene cuts, correction settings, reference areas, export options and the current frame in a small `.frankluma` file. Open Project (⇧⌘O), Finder opening and drag-and-drop restore these edits after reanalysing the source. Projects link to the original video; keep it available. A security-scoped bookmark follows moved files where macOS permits it; Relink Source Video accepts an identical copy when the source cannot be located. SHA-256 identity checks prevent applying edits to a different video. Opening another clip, closing or quitting offers Save Project, Discard Changes or Cancel when there are unsaved edits. Help → FrankLuma Help explains supported formats and controls; Help → Open Demo Video loads an original built-in sample. SDR only, up to 4096 pixels per side; HDR and protected sources must be converted first. Exports are re-encoded, not lossless copies. ProRes export uses half-float RGBA decoding, half-float Core Image processing and 16-bit RGB encoder input to avoid an 8-bit export intermediate. Input decoding uses AVFoundation; H.264, SDR HEVC and SDR ProRes are the primary supported codecs in MOV/MP4 where the container permits them. Actual decoding also depends on the macOS codecs available; HDR remains unsupported.

## Projects and recovery

Save Project As (⇧⌘S) creates a separately named project and makes it the active save destination. Exporting a movie does not save the editable project. Saved projects contain settings, source identity and a source-access bookmark; they contain neither the video nor cached frame analysis. Opening therefore repeats analysis and reference measurements before replacing the current session. Invalid projects, mismatched videos and cancelled analysis leave the current session intact. Changing the source video requires a fresh session; a relinked file must be byte-identical to the original.

Unsaved edits create a debounced recovery checkpoint in the app's local Application Support directory, separate from the saved project. Each session has its own checkpoint so an unresolved recovery is not overwritten by another session. On launch, FrankLuma offers to recover, keep for later or discard a checkpoint. File → Recover Unsaved Session reopens the newest available checkpoint; additional checkpoints remain available afterward. A recovered session is unsaved and needs Save Project. Successful saves and deliberate session closure/discard remove that session's checkpoint. A recovery-write failure appears in the footer; use Save Project to keep your work.

## Build

Requires Xcode and its command-line tools. Run:

```sh
zsh scripts/build-app.sh
```

The script builds the universal sandboxed app through Xcode and copies it to `dist/local/FrankLuma.app` with an ad-hoc signature. Open `FrankLuma.xcodeproj` in Xcode to run, test or archive. See [release and signing instructions](docs/RELEASING.md) for Developer ID, notarisation and App Store distribution. `Package.swift` remains available for command-line development.

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

The global reference uses 336 linear-light patches and rejects clipped, dark and occluded observations. The default local pipeline follows surfaces on 96 × 56 linear-RGB thumbnails using exposure-invariant patch structure and forward/backward correspondence checks. Flat centres can use a wider silhouette for tracking while retaining a small central brightness measurement. A trajectory ends at a cut or uncertain match; it never inherits another object's lighting history.

Each surface has independent RGB lighting histories. **Smooth flicker** solves a robust gradual trend using the existing smoothing radius, preserving slow fades; **Steady scene** uses a robust constant target. Both solve within the scene. Correspondence removes planar lighting gradients so moving light bands do not masquerade as image motion. A dedicated row-lighting model requires independent observations across all four quarters of the image; it can bridge an isolated missing row but cannot extrapolate across unsupported edges or wider gaps.

Source-guided gain propagation and chromaticity-guided spatial regularisation suppress isolated gain islands. Stationary fallback requires wider texture identity, not colour agreement alone. Large brightness differences still separate neutral materials. During camera movement, matches must also agree with the surrounding RGB exposure change. Newly revealed surfaces build support gradually; weak or conflicting local estimates fade towards global exposure correction. These are confidence heuristics, not guarantees for arbitrary occlusion, lighting or camera motion. The new default uses multiplicative RGB gains to protect source texture; the older bounded exposure/tone path remains available for benchmark comparison. No neighbouring image frames are blended or warped, and no neural model or commercial plugin is required.

**Colour correction** controls the local RGB adjustment independently of Strength and Spatial correction. At 0%, the local gain is achromatic; reducing the amount preserves the estimated corrected linear luminance rather than weakening brightness stabilization. Existing projects default to 100%. Manual frame EV remains available for individual outliers.

**Preserve scene brightness** is enabled by default, including for older projects. With reliable stable-background measurements, it checks predicted rendered pixels, anchors typical scene brightness to the original scene median and applies a bounded residual adjustment per frame. Smooth retains the gradual exposure trend; Steady aims at a constant target. Manual frame EV remains separate and applies afterward. Automatic gains are limited to ±2 EV with highlight protection. Information already lost to clipping cannot be recovered reliably.

In **Steady scene**, stationary shots also check local rendered brightness against held source patches. Small residual errors receive bounded, achromatic adjustments with nearby support and material checks, scaled by Spatial correction. Camera-motion shots, row-lighting models and manual reference regions retain their existing correction path. Smooth flicker retains its gradual-lighting behavior. This improves supported local flashes without requiring another mode; uncertain or unsupported surfaces can still retain variation.

Paused corrected previews decode and correct at source resolution before resizing, so pixel-dependent guidance follows the same ordering as export. Live preview and export share the gain renderer. The timeline is explicitly a **global model + manual** estimate; local RGB gains and highlight protection can make actual rendered brightness differ. Use corrected comparison and field diagnostics to inspect those pixels. Export preserves source video sample presentation timestamps and durations, dimensions and orientation; audio packets pass through without re-encoding.

The real-video audit additionally measures twelve spatial regions using patches selected from the source. Regions without enough reliable support are excluded; camera movement can still confound these measurements. These checks expose local brightness jumps that a whole-scene median can hide, and complement encoded-frame review.

The latest signed review build is `dist/review-v33/FrankLuma.app`; the running `dist/local/FrankLuma.app` was preserved. See [the confidence review](dist/Benchmarks/general-review-v30/photometric-confidence-review.html) and [matched-luminance review](dist/Benchmarks/general-review-v30/matched-luminance-review.html) for current baseline evidence. Earlier reports below describe earlier revisions.

The subsequent [registered-camera correction](dist/Benchmarks/general-review-v30/registered-anchor-review.html) is enabled by default in source after all 450 paired slider cases and 146 native tests passed, plus an additional end-to-end anchor test. The production-default anchor test also passed. For diagnostics, `FRANKLUMA_REGISTERED_ANCHOR=0` disables this refinement. The separate signed universal build is `dist/review-v33/FrankLuma.app`; its signature, architectures and build number are verified. It was not launched, and the running local app was preserved. It checks corresponding textured source surfaces before reducing correction-induced brightness changes during camera movement. It adjusts exposure gains without warping or blending image pixels. On 161 supported LEGO transitions, matched-luminance RMS falls from 0.04042 to 0.03595 EV; the 168→169 step falls from 0.18646 to 0.04590 EV. Fox and the three licensed clips have unchanged matched-luminance results. These overlapping measurements have no clean lighting ground truth and cannot establish that every flash is invisible.

The correction also improves that LEGO step with reduced controls: Strength 75%, Spatial 50%, and the balanced 75%/50%/50% profile. Some other transitions worsen slightly, so the [paired real-slider report](dist/Benchmarks/general-review-v30/registered-anchor-real-sliders.json) retains those increases. The [450-case sweep report](dist/Benchmarks/general-review-v30/registered-anchor-slider-sweep.json) identifies completed and pending profiles explicitly.

For adjustment, start with Smooth flicker and compare corrected neighbouring frames at a troublesome point. Reduce **Strength** if the entire automatic result is too aggressive; reduce **Spatial correction** when different areas pump or acquire unwanted local gradients; reduce **Colour correction** for unstable colour changes while retaining brightness correction. Increase **Smoothing radius** when slower fluctuations remain, checking that intentional lighting changes still look right. Choose **Steady scene** only when a constant exposure target is appropriate; it can suppress intentional fades. Use a stable **Reference area** when subject movement makes automatic metering unreliable, avoiding moving objects, reflections and clipping. Reserve **Frame adjustment** for isolated residual errors after the scene settings are satisfactory. Strength zero disables automatic correction but retains manual edits; Spatial zero retains global correction.

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
- Export re-encodes video as H.264, HEVC or ProRes 422; it is not lossless. Image sequences and batch processing are not included in this version.


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

### Fox three-scene regression (5 October 2026)

The 60-second `FrankLuma-Fox-60s-Three-Scenes-v2.mp4` reproduces two missed same-palette camera cuts. Before this fix native analysis returned no cuts. Persistent, exposure-normalised structural changes between settled shots now detect frames 200 and 400 (20 and 40 seconds), without classifying the measured flashes at 349 and 559 as cuts. A software-decoded appearance fixture covers both boundaries and flashes; production native analysis independently confirmed exactly these two cuts across all 600 frames.

The material-guided patch rendering introduced in the recent update has been rolled back. Preview and export again use the smoothly interpolated coarse exposure/tone fields; per-patch colour-selected contrast changes are no longer applied. This mitigates a possible source of changing texture/subject appearance, but does not establish that every reported morphing artifact is resolved. Existing neutral-midtones tone correction remains, with exposure-only correction for dark/saturated colours. It can retain residual flicker and needs visual review.

The review export is `dist/Fox validation/corrected.mp4`; `comparison.png` pairs sampled original/corrected frames. Native validation preserves 600 frames, 1600 × 1000 dimensions, 10 fps and 60 seconds. In five fixed 24 × 14 analysis-grid cells per scene (column,row: 2,1; 12,1; 21,1; 2,12; 21,12), adjacent-frame log-luminance RMS falls by 72–79%. These are selected regional measurements, not a whole-image artifact or colour-fidelity guarantee. Source and exported linear-light cell measurements are in `dist/Fox validation/measured/`.

The universal development app is `dist/local/FrankLuma.app`. Signed distribution artifacts were preserved. SwiftPM verification: 77 tests passed, one demo-resource test skipped, and the native playback-loop test failed because `Bundle.main` lacks the bundled demo movie in the SwiftPM runner. Scene, spatial-estimator, renderer and real-video export tests passed. Full-resolution perceptual review remains required before release.

### Manual frame exposure (5 October 2026)

Frame adjustments are a separate source-frame-indexed layer, applied after automatic exposure/tone estimation and before highlight protection. Manual changes do not affect automatic targets, neighbouring frames, scene strengths or cached spatial estimates. Pending automatic calculations reapply the latest frame edits on completion. Reanalysis retains frame edits only when source fingerprint and frame timestamps match. Scene split/merge/reset and reference edits preserve them; opening a new source or closing a session clears them.

Projects now use format version 2 and store a validated sparse list of frame/EV pairs. Legacy version-1 projects open with no manual edits. New projects require the updated app; older app versions reject them rather than silently discarding frame edits.

Validation for manual exposure: 42 targeted native checks passed, including exact-frame variable-duration preview/export comparisons in H.264 and ProRes, source-texture preservation, highlight protection, pending-calculation/frame-edit isolation, and project compatibility/validation. The save/reopen/recovery test was additionally rerun with frame-edit assertions and passed. The GUI was exercised on the fox clip: frame 201 adjusted by −0.35 EV, frame 202 verified at zero manual EV, navigation returned to the edited frame, side-by-side preview showed the change, and Reset removed its marker. The reset session was preserved in `dist/Fox validation/Frame adjustment demo.frankluma`.

Native pixel checks also exposed pre-existing black ProRes exports through packed v210 decoding. ProRes-bound export now requests half-float RGBA decoding instead; it retains a high-precision processing path. Native pixel-content and timing regressions pass with the revised decoding format.

## Ground-truth baseline benchmark

Step-one validation lives in `scripts/validation/BenchmarkAudit.swift`. It generates ten deterministic 320 × 192, 72-frame, 12 fps clips, each with a clean target, corrupted input and an independently generated foreground mask. Cases cover global exposure flicker, moving subjects, background-only local flashes, camera translation, an intentional exposure ramp, colour-channel flicker, rolling bands, scene cuts, clipped highlights and movement without flicker. These are controlled diagnostic scenes, not a representative production-video dataset.

```sh
zsh scripts/build-benchmark-audit.sh
.build/benchmark/audit self-test
.build/benchmark/audit generate dist/Benchmarks/my-dataset
.build/benchmark/audit run dist/Benchmarks/my-dataset --label baseline-smooth
python3 scripts/validation/report_benchmark.py dist/Benchmarks/my-dataset baseline-smooth
.build/benchmark/audit run dist/Benchmarks/my-dataset --mode steady --label baseline-steady
python3 scripts/validation/report_benchmark.py dist/Benchmarks/my-dataset baseline-steady
python3 scripts/validation/run_real_benchmark.py dist/Benchmarks/my-real-baseline
python3 scripts/validation/test_benchmark_report.py
```

Use new dataset/output names: fixtures and successful baseline directories are not overwritten. Native AVFoundation generation, decoding and export require access to macOS video services. Python scripts use the standard library only. Each result includes the actual corrected movie, a clean-target no-correction export for the codec floor, per-case scores, and a contact sheet with corrupted input / clean target / corrected export. Reports record source, fixture and harness fingerprints plus the exact scene settings. Synthetic runs freeze their compiled runner, compiler/platform metadata and build-time source fingerprints before scoring, so later algorithm edits do not relabel an old baseline.

The pixel scorer measures foreground and background independently using saved masks, without selecting patches from the corrected output. EV metrics use region-mean linear luminance per frame; RGB, chromaticity and edge metrics measure spatial errors that can be hidden by a matching region mean. It reports median EV error, P95 and worst absolute EV error, adjacent-frame RMS of the error relative to the matching clean frame, linear-RGB RMSE, chromaticity error, edge-gradient error and clipped-pixel fraction. Known cuts are excluded from the adjacent metric; intended fades and movement are preserved in the clean reference. Timing, dimensions, frame counts and cut detection are checked separately. The scored regions retain their own failures; a stable background cannot hide a damaged subject.

Initial engineering targets above each region’s measured codec floor are: P95 EV error ≤ 0.10, residual adjacent EV RMS ≤ 0.03, linear RGB RMSE ≤ 0.025, chromaticity MAE ≤ 0.01, edge MAE ≤ 0.005 and extra clipped fraction ≤ 0.005. The no-flicker motion control has tighter EV/RGB targets. These preliminary tolerances are declared in `report_benchmark.py`; they are development targets, not perceptual guarantees. Clipped source information may be unrecoverable. Steady scene intentionally flattens fades, so its intentional-ramp failure must not be confused with a Smooth flicker regression.

The real-footage inventory is `scripts/validation/benchmark-real-cases.json`: fox, 4K LEGO, paper animation and outdoor pixilation. These have no verified clean target, so the real report provides native integrity checks and selected-frame review sheets rather than invented accuracy scores. Missing local inputs are reported explicitly. User-provided media is kept local; third-party attribution accompanies generated review artifacts. No commercial-tool output has been benchmarked yet. This baseline is intended to freeze current weaknesses before changing motion tracking or the lighting model.

### Motion and temporal stability validation

The current pipeline adds robust translation/rotation/zoom guidance, shared exposure anchors for lighting-coherent fragmented tracks, and direct attenuation of weak local gains at moving edges. Rendering still changes source-frame gains without warping image geometry. Existing correction controls remain available.

The ground-truth suite now includes 18 development clips and four separately generated holdout clips, evaluated after tuning was frozen. Smooth passes all development cases; both modes pass the holdout set. Steady remains outside strict unchanged-footage tolerances on stable zoom and rotation controls and intentionally flattens the exposure-ramp control. Real fox diagnostics are almost unchanged; LEGO regional EV RMS rises about 3%. See the linked report for exact measurements and exports rather than assuming every clip improves.

### Conservative camera correspondence fix

The latest revision preserves reliable local matches on repeated textures. Camera guidance now replaces a valid correspondence only when its texture error is weak and the guided match is substantially better. A regression test covers an incorrect camera prediction between repeated surfaces with different brightness.

Fresh LEGO Steady exports show about 7% lower regional EV RMS than v26 and about 4% lower than v22. The worst regional jump improves only slightly and remains above v22. A pre-fix 50% Spatial experiment left more residual variation overall. Fox metrics are effectively unchanged. All 123 native tests pass; Smooth passes all 18 development clips, and both modes pass the four separate regression clips. The Steady exposure-ramp and stable zoom/rotation limitations remain. See [the measured LEGO fix](dist/Benchmarks/lego-final-v28/report.html) for exports, encoded frame triplets, provenance and limitations.

### Using and validating the sliders

The inspector now explains when to reduce Strength, Spatial and Colour, how radius differs from Strength, and how to tune one scene using side-by-side playback and nearby frames. An expandable scene guide and the offline handbook explain the trade-offs. Colour is inactive when Strength or Spatial is zero, with an explanation; its stored value is retained.

The settings matrix measures 330 actual encoded combinations on 22 synthetic clips: ten Smooth profiles and five Steady profiles, including zero, partial and full amounts, global-only, brightness-only, mixed amounts, and 0.2/0.5/1.5-second radii. Native checks verify zero automatic correction against an independently encoded no-op, zero local gains at Spatial zero, and achromatic local gains at Colour zero. All combinations preserve frame timing, geometry and detected cuts; 123 native tests pass. Partial profiles intentionally leave some flicker and are not judged solely against full-strength suppression targets. The four separate clips are previously evaluated regression cases, not a new unseen holdout.

Lower Strength or Spatial helps stable zoom footage, while independently flickering backgrounds can require strong local correction to protect an unchanged foreground. Colour amounts change chromatic correction without being a second exposure-strength control. The correction mathematics remains the v28 algorithm, including remaining LEGO peak flashes and the Steady stable-camera/fade limitations. The [filterable settings report](dist/Benchmarks/slider-range-v29/report.html) links each encoded movie and comparison sheet. No profile is presented as universally best.


## General illumination review — candidate evidence

The [general correction review](dist/Benchmarks/general-review-v30/report.html) compares the candidate with the preceding engine using 450 encoded slider combinations on 30 synthetic clips and five real stop-motion clips. It includes a newly downloaded CC0 clay animation, attribution, source hashes, separately scored foreground/background errors, codec controls and worst-event measurements. Previously evaluated and tuned cases are described as regression evidence rather than untouched holdouts.

The candidate separates supported shared exposure from local illumination, connects agreeing fragment histories while preserving independently validated shared targets, and validates bounded rendered-gain refinement using separate source-pixel footprints after Colour projection. Fractional, curvature and colour-based correspondence experiments that regressed controls were not enabled for release. Rendering continues to use original source pixels.

The clearest measured gains are fox Smooth regional variation (about 10% lower average and 33% smaller peak), rolling-band foreground error (about 20% lower), and unchanged-foreground protection at partial Spatial: the background-flash case at 50% Spatial changes from 0.128 to 0.026 EV foreground RMS, while deliberately retaining more background variation. LEGO shows no clear default improvement; Steady regional RMS is about 3% higher, and independent-lighting foreground errors still exceed initial targets. The report preserves these failures and the intentional-fade limitations of Steady mode.

Strength, Spatial, Colour and temporal radius remain independently adjustable. All 450 synthetic combinations preserve frame timing, geometry and expected cuts; Strength zero is checked against a separate no-op encode, Spatial zero against zero local gains, and Colour zero against achromatic gains. Real-video measurements have no verified clean target and do not establish perceptual accuracy.

An additional self-generated MPEG-4 fixture tests a rounded MOV edit-list end with missing decoded frame durations. Export now includes the presentation-end timescale in its video media scale. Exact frame starts, source presentation holds and copied audio payloads are checked separately on both modes of all five real clips. The original running app and signed distribution artifacts are preserved while the candidate remains under review.

The subsequent [guarded Smooth patch validation](dist/Benchmarks/general-review-v30/smooth-patch-validation-v3.html) gives stable background patches their own gradual exposure targets. It checks contrast-normalised texture shape before treating fixed image positions as the same surface, so zooms and rotations do not automatically receive this correction. Compared with the candidate above, Fox Smooth regional variation falls another 21% and its largest step falls 42%; LEGO is essentially unchanged. All 450 paired slider cases pass integrity/control checks, and 143 native tests pass with the production default. Exact media checks pass on five real exports and three additional Fox slider trials. It is enabled in the separate signed universal `dist/review-v31/FrankLuma.app`; the running app was not replaced. Unsupported regional measurements on the paper and outdoor clips remain missing evidence, and residual flashes remain unresolved.

The subsequent geometry/photometry confidence revision keeps contrast-invariant correspondence separate from raw brightness confidence. Wider texture checks and longer camera-motion baselines prevent lighting changes from becoming false geometry or unjustified photometric evidence. All 450 paired encoded slider combinations preserve timing and cuts and pass native correction controls. Five real exports and three reduced-amount Fox exports pass exact media checks. Compared with retained app31 mathematics, Fox's supported regional RMS falls about 3% and its peak step about 26%; LEGO's peak is unchanged. Small highlight-stress trade-offs remain. The [confidence review](dist/Benchmarks/general-review-v30/photometric-confidence-review.html) records source provenance, slider evidence and limitations. This revision is enabled in source; see the report for the separate review app's build status. The existing running app is preserved.

Developer layout and target membership are described in [Project structure](docs/PROJECT_STRUCTURE.md).
