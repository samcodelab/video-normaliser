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

## Resume progress — 11 October 2026

User requested continuation. Expanded `NativeRegionalSurfaceAudit` to retain
all-seed rejection diagnostics and source-only tracked brightness histories;
added `report_source_footprints.py` for residual-directed inspection with an
explicit proximity limit and different-support caveat. See the new section in
`LEGO_NATIVE_REFINEMENT_REVIEW.md` for native event-187/event-188 results and
verification. Evidence is `.build/review-v39/source-footprints`, with the useful
HTML report under `report-v2/report.html`.

The brighter source peak at 187 was checked explicitly and did not recover
trustworthy support. Geometry, near-clipping and held photometric nonuniformity
remain the main observed rejection classes near the strongest encoded residuals.
No prototype was promoted. Next work is native material/geometry inspection and
matching-termination diagnosis, rather than another unsupported field fit.

### Further progress on continuation

The follow-up pass extracted native frames and traced reciprocal rejection checks.
It found a contrast-driven 13×13/5×5 descriptor-size switch near the strongest
residual. A diagnostic-only fixed wider support reduces LEGO geometry rejections
415→199 and clean-motion rejections 258→9, with existing photometric checks intact.
A deterministic regression reproduces the size switch; 52 correspondence tests
pass. Automatic correction defaults are unchanged. Recovered dark printed support
still lacks valid photometry; wider tracking is not a proven encoded improvement.

See the latest section in `LEGO_NATIVE_REFINEMENT_REVIEW.md` and evidence under
`.build/review-v40`, especially `matcher-report/report.html` and
`wide-report/report.html`. Next verify fixed-support native geometry and dark
brightness estimation independently before any automatic integration. No new
export or correction control matrix was run in this follow-up.

### Independent native verification of the proposed next steps

User authorized the four-stage verification/correction plan. Added
`scripts/validation/NativeDisjointSupportAudit.swift`: disjoint native geometry
rings and central radiance tiles, source PTS checks, nonoverlapping complete
moving support envelopes, contributor clipping checks before interpolation,
held photometric tests and explicit geometry eligibility. Self-tests include
fractional clipping, zero-weight contributors and geometry controls.

Final evidence is `.build/review-v41/report-verified.html`,
`{lego,clean,ramp}-verified.json`, `verification-verified.json` and
`frozen-verified/`. Earlier `report.html`/`*-final.json` are provisional before
contributor-level clipping validation, not the final comparison.

43 disjoint LEGO probes retain 99/304 accepted adjacent native edge checks, but
all 74 central fits at main events 187/188 fail existing validity/held gates.
Only one fit qualifies at 185, outside the main flash; it is not authorization
for correction. Clean moving and intended-ramp targets give <0.002 EV excursions
on one retained region each, so control coverage is sparse.

No bounded correction, candidate export, Fox correction regression, partial
slider matrix or app integration was performed because the prerequisite source
fit failed. These remain pending. Next establish geometry from broader stable
printed landmarks/object structure and independently quantify dark measurement
uncertainty. Do not loosen local native gates or resume field fitting merely
because coarse wider tracks recover more frames. See the latest native review
section for detailed counts, coordinates, qualifications and reproduction.

V42 continuation: rejected doubled-radius native edge geometry. On the same159
LEGO pairs it loses15 accepted narrow matches and recovers3; 23 disjoint broad
regions supply zero qualified fits. Original-radius replay reproduces V41.
Added source-only spatial deletion/±3pixel meter sensitivity, **not calibrated
noise uncertainty or temporal error**. Printed(431,303) location brightness range
is0.47–0.74EV at186–188, while clean/ramp controls also have nonzero spatial
sensitivity with qualified temporal excursions below0.002EV. Do not use spatial
range alone to reject temporal metering or relax dark limits. Review/provenance
`.build/review-v42/review.json`, frozen sources/binary and four native JSONs;
details in LEGO_NATIVE_REFINEMENT_REVIEW.md. Builds/self-tests pass. No candidate,
app default change or encoded improvement. Next: coherent separately identified
printed landmarks with held geometry; temporal position sensitivity and calibrated
repeat/known-noise evidence for dark surfaces remain unresolved.

V43 continuation: added source-only spatially held similarity transforms
(NativeLandmarkTransformAudit.py), denser disjoint native landmarks and actual
three-frame position sensitivity (NativeDisjointSupportAudit.swift). Dense edge
geometry retains 80 regions but only 1/2 landmarks on main adjacent transitions;
luminance-shape geometry increases those counts to 4/4, still insufficient for
two independently spread three-landmark folds. Luminance coverage on clean ramp
is poor (4/94 versus clean motion 70/94), unresolved and not promoted. Neither
variant has a jointly geometry/photometry-qualified main fit. Two later fits at
189/190 do not authorize filling missing main-event evidence. Dark (431,303)
position-induced temporal excursion changes reach 0.196/0.276 EV at 187/188;
brighter (495,303) changes are about 0.037 EV. This is a stress test, not allowed
geometry uncertainty or noise confidence bounds. Original clean/ramp checks have
changes below 0.005 EV and repeat prior near-zero qualified excursions.
Final evidence .build/review-v43/*-final.json, *-landmarks-verified.json,
review-verified.json and frozen/; earlier unsuffixed runs are exploratory.
Exact V41 original checks/pulses reproduce; all envelopes, builds/self-tests and
project/diff checks pass. No correction/default change, output candidate or
encoded improvement. Next inspect native printed identity/contrast at 186→187
and why the ramp loses luminance-shape coverage; density alone is exhausted.
Calibrated dark-noise evidence and lighting-model support remain unresolved.
V43 final control diagnosis: stationary-ramp-review.json verifies from retained
synthetic foreground masks that (39,39)'s full native support columns have no
moving foreground at28–33. Clean native luminance scores are approximately1; intended-ramp
scores0.976–0.991 falsely reject the same stationary structure. This is a specific
encoded/decoded appearance calibration failure, not established sensor noise or
permission to lower0.995. audit_stationary_ramp_geometry.py uses masks solely for
control verification. Next geometry work should explain/correct this known
failure before its thresholds or descriptors are trusted on dark LEGO prints.

### V48/V49 measured improvement milestone

The current best measured main-flash LEGO research export is
`dist/Benchmarks/review-v48-native-flux/lego-exposure-8/corrected.mp4`:
187→188 median absolute EV is **44.2% lower**, maximum **37.1% lower** than the
retained V33 baseline. Independent phase-7 encoded footprints show **33.0% lower
median**, **14.4% lower maximum**. All surrounding retained-phase medians/maxima
improve; shifted quiet variations are below 0.001 EV. Supported whole-clip
transition-median RMS improves 4.2%, so do not equate the main-event gain with a
44% whole-video improvement. Individual footprint regressions are retained in
the report.

The working hypothesis is native integrated regional radiance with four
leave-query-out donors corroborating timing/sign, then bounded smooth neutral
exposure fitting through the actual renderer. It allows nonuniform illumination
within a patch without relaxing the rejected uniform-response validator.
Geometry remains source-only, contributor clipping stays strict, and native
support envelopes are disjoint. Source controls with full quorum give zero
activations (19–27 meters for upscaled clean motion; eight for the independently
tracked upscaled clean fade). Upscaled controls are derived diagnostics, not
sensor-noise calibration. Original clean-motion fields and decoded target
scores are exactly unchanged.

A scaled half-strength full candidate gives intermediate main median/max
0.091875/0.492347. Do not use the independently refitted half candidate as the
slider route. All accepted-review media have preserved frame count/timestamps,
dimensions/durations and LEGO audio payloads. Exports must remain sequential.

A dense-protection LEGO alternative and Fox research candidate are also
retained. Fox dense fitting reduces its main flash median/max 31.2%/36.0%, but
one quiet maximum increases by 0.00194 EV. It is not accepted for automatic
shipping. A 0.0001-EV renderer guard admits no positive Fox step, pointing to the
coarse-RGB guard Jacobian/native precision as the next issue. Dense source
protection overlaps phase-6 audit locations; phase 7 is the separate spatial
check. No frozen encoded residuals are loaded by the fitter.

Automatic app correction remains unchanged. Before a production route, replace
the coarse-RGB guard Jacobian with measured native pixel/renderer response,
validate cross-clip quiet boundaries, and generalize the diagnostic ROI/window
sampling. Prefer neutral exposure to tone fitting based on these encoded
results. Retain the conservative old pixel-response gate and all rejected
experiments.

Full verified numbers and artifacts:
`dist/Benchmarks/review-v49-native-flux/report/index.html` and `report.json`.
Reproducible fitter/native source snapshots and binaries:
`.build/review-v48/frozen`; selected full fields were exactly reproduced by its
fitter. Commands use `NativeMeanFluxAudit.py`, `NativeMeanFieldFit.swift`,
`ExportRetainedFields.swift` and `report_native_mean_field.py`. Details and
limitations are appended to `docs/LEGO_NATIVE_REFINEMENT_REVIEW.md`.
