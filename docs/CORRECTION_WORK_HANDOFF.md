# FrankLuma correction work handoff

Saved 10 October 2026. Work stopped at the user's request. Resume only when requested. The existing long-running goal is already paused; the LEGO flash-reduction objective is **not complete**.

## Resume here

Read this file and `docs/LEGO_NATIVE_REFINEMENT_REVIEW.md` first. Preserve the working tree and review evidence. The latest experiments do **not** justify enabling a new automatic correction path. We are not yet satisfied with the LEGO flash reduction.

The direction is to establish reliable source measurements on the surfaces that still flash, then fit a bounded correction and verify the actual encoded output. Do not keep tuning a solver against its own selected patches: its residual can improve greatly while the visible flash barely improves. Distinguishing changing reflections or appearance from changing illumination remains the main unresolved model question.

## User requirements

- Reduce visible flashes on LEGO and Fox without introducing morphing, bright overcorrection or new flashes.
- Generalize across videos; demo-specific regions and thresholds are diagnostic probes, not shipping rules.
- Preserve intended gradual lighting changes and clean motion.
- Keep meaningful Strength, Smoothing radius and Spatial correction controls, including partial settings. Document when and why to use them.
- Support manual per-source-frame EV adjustment and large neighboring-frame comparison in the main preview. These were introduced earlier; this latest pass focused on the correction model.
- Control scene brightness without eliminating legitimate lighting changes. A fixed endpoint alone does not preserve the scene mean.
- Keep the Xcode project organized and preserve a path toward sharing core code with iPhone/iPad apps. No iOS target was delivered by this correction pass.

## Workspace and project structure

Repository: `/Users/sam/Documents/Development/FrankLuma`.

The working tree contains extensive earlier changes and untracked code, documents and scripts. No commit or reset was made. Many root-level Swift files show as deleted because they were moved into folders. Do not interpret this as accidental deletion or discard the work.

Application source now follows:

- `Sources/FrankLuma/App`: app entry point and AppModel.
- `UI`, `Documents`, `Platform`: timeline, document persistence and file access.
- `Core/Analysis`: Exposure, PatchExposure and CommonIllumination.
- `Core/Correction`: Scenes, SpatialLighting, PulseReconstruction and QuietColourContinuity.
- `Core/Rendering`: SpatialRenderer.
- `Core/Media`: VideoEngine, VideoExporter and VideoGeometry.

Tests have corresponding Correction, Media, Documents, Platform, UI and Support groups. Xcode groups match physical folders. The app remains one Swift module. `scripts/correction-sources.sh` centralizes the 11 core audit sources. `scripts/validate-project.py` checks Xcode membership against disk: 16 app and 22 test Swift files, no missing references. See `docs/PROJECT_STRUCTURE.md` and the earlier iOS architecture report.

## Inputs and baseline evidence

LEGO source: `/Users/sam/Downloads/My_Stop_Motion_Movie(22).mov`.
212 frames, 12 fps, 3840×2160, audio, duration about 17.667 seconds. Frame indices in audits are zero-based. Main flash review is around frames 186–190; the relevant scene covers 180–192 inclusive. Retained automatic cut indices: 10, 21, 45, 66, 75, 85, 107, 129, 143, 154, 157, 174, 180, 193.

Fox source: `/Users/sam/Downloads/FrankLuma-Fox-60s-Three-Scenes-v2.mp4`.
600 frames, 10 fps, 1600×1000, no audio; cuts 200 and 400. A difficult event reviewed earlier is around frame 559.

Retained real-video baseline fields:
`dist/Benchmarks/review-v33-joint-field-fit-v62/{lego,fox}`.

Retained control baseline fields:
`dist/Benchmarks/review-v33-feasible-joint-field-v63/controls/{local-moving,local-moving-half,local-moving-spatial-half,no-flicker-motion,intentional-ramp}`.

Synthetic source/target cases:
`dist/Benchmarks/motion-v2-development/cases/{local-moving,no-flicker-motion,intentional-ramp}`.
These contain input.mov, target.mov and foreground-rle.json. They have 72 frames at 12 fps and 320×192. Intentional-ramp includes flicker superimposed on a deliberate ramp; some detected pulse evidence is expected. Evaluate against its target.

The baseline LEGO matched audit is `.build/review-v33/joint-field-fit-v62/lego-matched-luma.json`. It has 161 source-supported transitions with at least 12 footprints each. RMS 0.0351504442 EV; 187→188 median 0.1187682443 EV and maximum footprint 0.6056471120 EV. These are measured proxies, not a guarantee of perceptual quality.

## Recent code changes

`Core/Analysis/CommonIllumination.swift`:

- Added `stepPixels` using the existing reciprocal held pulse checks for source RGB step evidence. This is evidence, not a declaration that a flash is unwanted.
- Added explicit `LinearReference` choices for `pulseLinearLuminancePixels`: geometricExposure remains the default; arithmeticRadiance is an experimental additive-light temporal reference.
- Arithmetic radiance preserves an additive ramp under actual uneven timing. Gain-plus-offset evidence still requires texture variation, bounded gain and offset, held prediction agreement, unclipped RGB and valid interior predictions.

`Core/Correction/SpatialLighting.swift`:

- Added `SurfaceTracking.trajectoryThrough` to track forward and backward from an event anchor with separate termination at cuts or uncertain matches. It never warps output.
- `SurfaceLighting.Map` now has optional `toneEV: [Float]?`, one neutral slope per map node. Nil retains the original renderer behavior and legacy Codable compatibility. **No automatic app pipeline generates toneEV.**

`Core/Rendering/SpatialRenderer.swift`:

- Experimental bounded neutral tone-dependent gain in both native Core Image and scalar prediction.
- Tone feature is log2 of source luminance relative to 0.18, bounded to −3…2. Slope is bounded to −0.5…0.5.
- The shared tone delta respects the existing −2…2 EV channel bounds and preserves the existing RGB gain ratios. Highlight protection remains in place.
- Invalid tone array shape uses zero tone; nonfinite sampled slopes are sanitized to zero.
- `surfaceGainJacobian` has optional `toneDerivative`, default false. The prototype remeasures actual response after each proposal. Boundary behavior is not fully certified by the finite-difference test, which covers an interior transported footprint.

Review harnesses added or extended:

- `PersistentRGBEventAudit.swift`: anchored correspondence and pulse/step RGB evidence.
- `NativeRegionalSurfaceAudit.swift`: bounded full-raster ROI extraction, arithmetic affine and spatial-plane evidence, optional linear-Y geometry and exact area-resampling diagnostics.
- `NativeFineLightingAudit.swift`: experimental exposure/tone field fitting, quiet-patch guards, bounded proposals, actual source PTS preflight and export. Research-only, no app call site.
- `ExportRetainedFields.swift`: repeat export with source timing and decoded-frame checks.

## Results and rejected approaches

Latest valid encoded comparison:

| Candidate | Matched RMS EV | 187→188 median EV | Maximum footprint EV | 188→189 maximum EV |
|---|---:|---:|---:|---:|
| V62 baseline | 0.0351504 | 0.118768 | 0.605647 | 0.107667 |
| V36 exposure refinement spacing 4 | 0.0349738 | 0.110291 | 0.592578 | 0.100018 |
| V37 neutral tone refinement spacing 4 | 0.0347672 | 0.107612 | 0.563924 | 0.140251 |

The tone candidate improves the main median by about 9.4%, but worsens the next transition's maximum error. Its active fitting-patch maximum residual falls from 1.16925 to 0.15182 EV, demonstrating why in-fit improvement alone is misleading. **Do not promote it.**

Steady-scene reference export also gives only a modest improvement (RMS 0.0340361; 187→188 median 0.110716, maximum 0.607227). Sliders do not solve the remaining local flash.

V38 source diagnosis at frame 188, analysis width 768, ROI (40,16,24,40) in 96×56 top-left bitmap coordinates:

- Original log-RGB geometry: 672/897 seeds rejected; four arithmetic affine patches accepted, outside the main error region.
- Linear-Y diagnostic geometry: 387/897 rejected; nine affine patches accepted. Linear-Y correspondence discards colour identity, so extra coverage is not automatically correct correspondence.
- Lanczos data contain negative RGB in 191 tracked patches; near-clipped RGB in 59. Do not silently clamp or loosen validity to make them pass.
- Exact radiance area average removes all negative-RGB patches. Geometry rejects 415/897; five affine and 45 luminance pulse patches pass. It does not solve the evidence gap.
- Smooth spatial-plane response accepts zero patches with held checks; most retained patches fail held prediction or gradient bounds.
- Clean moving control has near-identity affine measurements with both downsampling paths. This is a measurement check, not a full correction regression test.

Earlier rejected hypotheses include broad global/half-spatial adjustment, narrower physical footprints, stronger spatial priors, more solver iterations, projection variants, broad source filtering, finite kernels, spectral rank-aware fitting, low-texture anchors and joint field fits. High-resolution analysis with the same physical footprints did not qualify the worst region. The older affine pulse probe used a geometric reference; the new arithmetic probe is a distinct hypothesis. Consult `docs/PERSISTENT_SUPPORT_REVIEW.md` before repeating prior experiments.

QuietColourContinuity is an earlier experimental prototype, default off. It did not resolve these real-video errors; some variants regressed controls. Do not enable it as a shortcut.

## Evidence integrity and known pitfalls

Early V36 ROI reports had a crop-coordinate error. They and their fit results cannot be attributed to the stated positions and are discarded. Corrected tools render the whole scaled bitmap once and copy top-left row-indexed ROI pixels. Native/scalar parity is covered by asymmetric vertical bands.

Three simultaneous 4K review exports each lost four consecutive video frames even though the exporter reported success. Audio was unchanged. Their 208-frame files must not be scored against the 212-frame source. Sequential re-exports pass. The production exporter cause is **not fixed**: serialize native review exports and verify every file before evaluating correction.

The fine-fit tool's amount argument blends the extra refinement; it is **not** the complete user Strength control. It fits an explicitly chosen ROI and interval. Overlapping tracks/pixels are not independent donor evidence. Same-sign source pulses do not prove unwanted flicker. Fixed endpoints do not preserve scene mean brightness. These are unresolved deployment requirements, not UI features.

Older frozen binaries ignore newly added toneEV. Recompile tools with current core sources before assessing tone fields. In particular, native counterfactual image tools may reconstruct a Map and drop toneEV; preserve the field when preparing new ablations. Current app map-rebuilding paths have not been audited for tone persistence because automatic correction never generates it.

## Evidence locations

- `.build/review-v36/steady-reference`: steady reference and matched/media results.
- `.build/review-v36/fine-region/lego-raster-{1,4,8}`: corrected ROI exposure fits. Use only their `corrected-sequential.mp4` files and associated sequential media/matched reports.
- `.build/review-v37/tone-field/source`: frozen tone prototype sources and source hashes.
- `.build/review-v37/tone-field/lego-4`: tone candidate fields, review.json and corrected.mp4. Corresponding media and matched JSONs are in its parent.
- `.build/review-v38/radiance-reference`: arithmetic, linear geometry, area average and plane JSONs; frozen final core/tool sources and SHA256 manifest.
- `/tmp/frank-radiance-suite.log`, `/tmp/frank-v38-renderer-suite.log`, `/tmp/frank-v38-xcode.log`, `/tmp/frank-v38-fit-typecheck.log`: latest validation logs. Temporary logs may disappear; durable conclusions are in the review document.

Build artifacts under .build and dist may be ignored by Git. Preserve them locally; do not assume a clean clone contains retained fields, binaries or generated comparison videos.

## Validation at stop

- 46 CommonIlluminationTests pass.
- 28 SpatialRendererTests pass, including tone native/scalar parity, colour ratios, legacy maps and finite-difference Jacobian.
- Earlier 50 SurfaceTrackingTests passed after bidirectional anchored tracking was added.
- Xcode Debug build succeeds at `.build/review-v38/xcode`.
- NativeFineLightingAudit typechecks after adding source timing preflight.
- Project validator and git diff --check pass.
- This is not a whole-suite pass. An earlier full Xcode test run was stopped during the expensive bundled-demo test.
- No latest tone correction control matrix or Fox export regression was completed. These are required before promotion.

## Suggested next work

1. Inspect the actual worst-error source footprints and native output across frames 186–190. Separate geometric correspondence error, reflection/appearance change, clipping and true light change. Derive a testable model from those observations before adding more parameters. Existing source-qualified patches miss much of the visible problem.
2. Verify correspondence and photometry on disjoint native supports, including bright reflection and dark printed material. Improve geometry without accepting occlusions or identical-looking repeated texture. Linear-Y and area averaging are experiments, not certified replacements.
3. If a model gains trustworthy coverage, fit it with scene brightness constraints, temporal quiet guards and proper Strength/Spatial targets. Keep tone optional until justified. Avoid unmeasured chroma recovery from clipped highlights.
4. Export sequentially, verify timing/audio/count, and compare encoded output on independent footprints and visually at useful scale. Reject neighboring regressions even if the main flash improves.
5. Run clean motion, local moving light, intentional ramp, half Strength and half Spatial controls; then Fox and additional legitimate test material. Integrate only after those pass. Update slider guidance around the behavior actually delivered.
6. Investigate the concurrent export frame-loss issue separately. Do not hide it by scoring only successfully decoded frames.

The correction direction is still under review. There is no validated model yet that makes the remaining LEGO flashes invisible, and no promise that every reflection or clipped frame is fully recoverable.

## Useful commands

Run from the repository root. Native builds/runs may require the existing sandbox escalation mechanism. Never run several full-resolution video exports concurrently.

```sh
python3 scripts/validate-project.py
swift test --scratch-path .build/project-layout-package --filter CommonIlluminationTests
swift test --scratch-path .build/project-layout-package --filter SpatialRendererTests
xcodebuild -project FrankLuma.xcodeproj -scheme FrankLuma -configuration Debug -derivedDataPath .build/review-v38/xcode build CODE_SIGN_IDENTITY=-
```

Compile a review harness with the shared core list:

```sh
zsh -c 'source scripts/correction-sources.sh; swiftc -parse-as-library -O "${CORRECTION_SOURCES[@]}" scripts/validation/NativeRegionalSurfaceAudit.swift -o /tmp/frank-native-region'
```

Example diagnostic, using a **fresh** output path:

```sh
FRANKLUMA_SURFACE_SUBPIXEL=1 FRANKLUMA_AFFINE_GEOMETRY_PROBE=1 FRANKLUMA_AREA_RESAMPLING_PROBE=1 /tmp/frank-native-region '/Users/sam/Downloads/My_Stop_Motion_Movie(22).mov' 184 193 188 768 40 16 24 40 /tmp/frank-lego-region-new.json
```

Encoded validation utilities:

```sh
python3 scripts/validation/verify_review_media.py SOURCE CANDIDATE FRESH_MEDIA_JSON
.build/review-v32/matched-luma-runner/audit SOURCE CANDIDATE all adjacent FRESH_MATCHED_JSON
.build/review-v33/local-pulse-control-audit-v28b/runner/partial-audit CASE_FOLDER BASELINE_MP4 CANDIDATE_MP4 STRENGTH FRESH_TARGET_JSON
```

The frozen matched/target evaluators remain useful independent comparators; retain their provenance and do not silently replace their matching definitions between candidate comparisons.

## Earlier reports and research

- `docs/LEGO_NATIVE_REFINEMENT_REVIEW.md`: latest results and qualifications.
- `docs/EVENT_CORRESPONDENCE_REVIEW.md` and `docs/REGIONAL_RESPONSE_DIAGNOSIS.md`: correspondence and regional model diagnosis.
- `docs/PERSISTENT_SUPPORT_REVIEW.md`: extensive earlier experiments and rejection reasons.
- `docs/FOCUSED_MODEL_REVIEW.html`, `docs/NATIVE_EVENT_REVIEW.html`, `docs/RGB_MODEL_REVIEW.html`: earlier visual/model reviews.
- `docs/IOS_ARCHITECTURE_REVIEW.md`: earlier iOS/shared-core findings.
- Primary research previously consulted: BlazeBVD, ECCV 2024 (`https://www.ecva.net/papers/eccv_2024/papers_ECCV/papers/02526.pdf`), and Blind Video Deflickering by Neural Filtering With a Flawed Atlas, CVPR 2023 (`https://openaccess.thecvf.com/content/CVPR2023/html/Lei_Blind_Video_Deflickering_by_Neural_Filtering_With_a_Flawed_Atlas_CVPR_2023_paper.html`). No model weights or neural correction were integrated.

A useful next-session prompt is: “Read docs/CORRECTION_WORK_HANDOFF.md and continue the LEGO correction diagnosis. Preserve the existing work and evidence; do not enable a prototype until independent encoded and control checks justify it.”
