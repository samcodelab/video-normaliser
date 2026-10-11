# LEGO native refinement review — 10 October 2026

Status: unresolved. No experimental correction is enabled automatically.

## Encoded output, rather than fit residual

The retained V62 LEGO correction remains the comparison baseline. The source-supported matched audit uses 161 transitions with at least 12 footprints per transition.

| Candidate | Matched RMS EV | 187→188 median EV | 187→188 maximum footprint EV | 188→189 maximum footprint EV |
|---|---:|---:|---:|---:|
| V62 baseline | 0.0351504 | 0.118768 | 0.605647 | 0.107667 |
| V36 exposure refinement, spacing 4 | 0.0349738 | 0.110291 | 0.592578 | 0.100018 |
| V37 neutral tone refinement, spacing 4 | 0.0347672 | 0.107612 | 0.563924 | 0.140251 |

The tone fit reduces its own active-patch residual dramatically (maximum 1.16925 to 0.15182 EV), while the independently measured encoded flash improves only modestly and the next transition has a worse tail. This is a coverage/model failure, not grounds for promotion. No claim of invisible flicker is justified.

All three sequential V36 re-exports and the V37 tone export pass exact frame-count, presentation-time, duration and audio checks. Three simultaneous V36 4K exports each lost four frames despite reporting success; these are excluded. The production export cause is not yet isolated. Serialize review exports and verify media before scoring.

## Source measurement diagnosis

New arithmetic-radiance affine evidence is explicit and diagnostic only. The established geometric exposure reference remains the default. A synthetic additive VFR ramp is measured as quiet; a held interior content change is rejected. Scene motion and intentional-light classification remain separate requirements.

At LEGO event 188, width 768, ROI (40,16,24,40) in the 96×56 analysis coordinates:

| Measurement | Geometry rejections / 897 seeds | Accepted affine patches | Accepted luminance pulse patches | Negative-RGB patches |
|---|---:|---:|---:|---:|
| Existing log RGB tracking, Lanczos | 672 | 4 | 37 | not counted |
| Diagnostic linear-Y tracking, Lanczos | 387 | 9 | 39 | 191 |
| Diagnostic linear-Y tracking, exact area average | 415 | 5 | 45 | 0 |

Linear-Y tracking uses a surrogate only for correspondence; all lighting evidence uses original decoded RGB. It does not warp output. It loses colour identity information and is not enabled in the shipping tracker. Its improved coverage is not independent proof of correct correspondence.

Area averaging uses nonnegative normalized overlap weights on a full native linear RGB raster, with no RGB clamping. It removes the negative values introduced by the ringing downsample, but does not by itself produce adequate affine support. Near-clipped, dark, nonuniform and unidentifiable observations remain rejected. On the no-flicker moving control, accepted affine responses remain close to identity (Lanczos: maximum gain deviation 0.000267, offset 0.0000962); this is a measurement check, not a correction regression pass.

Evidence lives under `.build/review-v38/radiance-reference`; tone output and frozen source are under `.build/review-v37/tone-field`. The ROI is deliberately selected for diagnosis. Automatic region selection, native support independence, scene brightness constraints and slider contracts must be addressed before deployment.

The smooth spatial-plane response probe accepts **zero** patches at event 188 under the same held-prediction safeguards. Of 482 geometrically retained patches, 286 fail held-plane prediction, 48 fail the gradient bound and 7 give inconsistent predictions; 89 are dark and 52 near-clipped. A broader light model without better source evidence is not justified by this probe.

The next model review should separate reflection/appearance change from illuminant change on the actual strong-error footprints. A correction fitted to nearby valid patches cannot safely recover an unmeasured printed surface. Preserve encoded-output scoring and source-qualified held tests; do not substitute a lower in-fit residual or remove validity gates to declare success.

## Evidence corrections

Early V36 cropped-raster reports used an inconsistent crop origin. Those reports and their fits cannot attribute measurements to their stated image positions and are discarded. Later `lego-raster-*` reports extract by full-raster bitmap rows. Only their separately verified `corrected-sequential.mp4` exports may be scored. Native and scalar rendering parity is tested with asymmetric vertical colour and gain bands.

## Verification

- 46 illumination tests pass, including arithmetic radiance, additive pulse and held interior rejection.
- 28 renderer tests pass, including native/scalar parity, neutral colour ratios, legacy map decoding and a finite-difference tone Jacobian.
- Xcode Debug build succeeds; project source membership matches disk.
- Fine-field harness typechecks with an added source PTS preflight: decoded ROI ordinals must match the compressed source timing before fitting/exporting.

No whole-suite pass or generalized flicker solution is claimed.

## Resumed source-footprint diagnosis — 11 October 2026

The regional source audit now retains diagnostic rows for every seed, including
geometry failures and photometrically rejected tracks. Retained tracks expose
actual PTS, transported positions, geometry confidence, mean RGB, mean/P10/P90
linear luminance and raw RGB extrema. The previous accepted-evidence `rows`
remain unchanged. `scripts/validation/report_source_footprints.py` connects
residual-ranked matched footprints to nearby source probes for inspection only;
probes farther than one eight-pixel seed spacing are reported as unsupported.
Different footprint sizes and overlapping support remain explicit limitations.

Fresh native area-average / linear-Y diagnostic runs use the same source ROI and
interval as V38. At event 188, all 897 seeds are accounted for. All previously
accepted row values and retained rejection counts match V38 exactly. The same
check passes on the clean-motion control (299 seeds). The tool compiles, Python
syntax verification passes, project membership is valid and `git diff --check`
passes. This validates diagnostic preservation, not a new correction algorithm.

The strongest encoded 187→188 residual remains the matched footprint at (54,38)
with −0.605647 EV. Its nearest fine-scale source probe fails geometry. The nearby
probe for (54,30) fails near-clipped RGB validity; its maximum channel value at
187 is 0.9740, above the existing 0.95 validity bound. Its tracked mean linear Y
changes 0.1640 → 0.3077 → 0.2164 → 0.1806 over frames 186–189. The probe near
(62,30) fails held photometric uniformity despite lower brightness. These are
nearby, smaller source supports, not remeasurements of the matched footprint.
They do not establish that clipping or reflection explains the entire flash.

A second audit anchored at the brighter frame 187 tests whether the earlier
focus on 188 missed a qualifiable pulse. It does not recover the needed support:
546/897 seeds fail geometry; one arithmetic affine patch and 15 luminance pulse
patches qualify, versus 415 geometry failures, five affine patches and 45
luminance pulse patches at 188. The nearby worst supports retain the same
geometry, clipping and held-uniformity rejection classes. A single-frame pulse
model is still inadequate evidence for these multi-frame source fluctuations.

Evidence: `.build/review-v39/source-footprints/{lego187,lego188,clean-motion}.json`
and `report-v2/report.html`, with the compiled `native-region` diagnostic. The
report ranks encoded residuals only to direct human inspection; it must not be
used to choose shipping donors or loosen source validity gates. No automatic
correction behavior changed and no new encoded improvement is claimed.

Next: inspect the native material/texture supports around the geometry failures,
and diagnose which reciprocal matching condition terminates them. Source peak
selection alone did not solve the support gap; avoid another tone-field fit until
there is independently verified geometry and usable photometry on that region.

## Native inspection and descriptor-support experiment — 11 October 2026

Native 3840×2160 source frames 186–190 and top-left ROI crops were extracted with
AVFoundation/Core Image into `.build/review-v40/native-frames-output`. Inspection
of frames 187/188 shows recognizable printed structure with substantial contrast
changes and bright reflections. This visual observation does not independently
certify that all surfaces are stationary or that every brightness change is
unwanted illumination.

An optional diagnostic callback now exposes the production reciprocal match
checks without changing selection or confidence. On the 415 rejected event-188
seeds, the 830 immediate event-neighbor checks give 296 unavailable forward
candidates, 242 low forward-confidence candidates, 60 reciprocal-position
failures, 10 low reverse-confidence candidates and 222 accepted matches. An
accepted immediate neighbor does not make the complete trajectory valid.

A specific support mismatch was found near matched footprint (54,38). The nearest
probe, fine-grid coordinate (431,303), uses 507 texture values (13×13 RGB) at 188
but 75 (5×5 RGB) at 187. Its center crosses the existing contrast threshold which
selects wider fallback geometry. The search requires equal texture counts, so
it skips the mismatched candidates. At (495,303), near footprint (62,38), the
frame-188 central energy is only 0.00821; that is a separate weak-texture case,
not merely a support-size mismatch.

`FRANKLUMA_WIDE_GEOMETRY_PROBE=1` in the regional diagnostic fixes geometry support
at half-width 6 while retaining the five-by-five lighting meter, reciprocal
checks, source pixels, RGB validity and held-response tests. It is **not** enabled
in the automatic app path. The same linear-Y / exact area-average ROI yields:

| Source diagnostic | Geometry rejections / seeds | Arithmetic affine patches | Luminance pulse patches |
|---|---:|---:|---:|
| LEGO adaptive support | 415 / 897 | 5 | 45 |
| LEGO fixed wider support | 199 / 897 | 7 | 61 |
| Clean motion adaptive support | 258 / 299 | 6 | 35 |
| Clean motion fixed wider support | 9 / 299 | 14 | 273 |

This is improved correspondence coverage, **not** measured encoded flicker
reduction. Wider neighborhoods can cross material/occlusion boundaries and must
be independently checked. The worst nearby LEGO probe now spans all nine frames,
with less than one fine-grid pixel displacement; however, its mean linear Y is
0.00786 at 186, 0.02602 at 187 and 0.00909 at 188. It fails the existing dark
luminance validity checks. The other worst nearby supports still fail clipping
or held photometric uniformity. Thus better geometry alone has not supplied a
safe lighting model for the remaining flash.

The fixed-wide clean-motion affine measurements depart from identity by at most
0.004414 gain and 0.001259 linear offset. These are small but greater than the
previous narrowly qualified measurements; expanded coverage is not automatically
better photometry. Qualified pulse counts include quiet near-zero measurements
and must not be interpreted as false flash counts.

Verification: 52 SurfaceTrackingTests pass, including a deterministic
contrast-driven descriptor-size switch and recovery with fixed wider geometry,
and a callback parity/flat-rejection test. The default event-188 accepted rows
and rejection counts reproduce the V39 evidence exactly; all 897 seeds are
accounted for. Diagnostic builds, Python syntax checks and project validation
pass. No encoded candidate or full correction control matrix was produced in
this pass; production geometry defaults and correction remain unchanged.

Evidence: `.build/review-v40/{lego188-optimized,lego188-wide,clean-motion-wide}.json`,
`matcher-report/report.html`, `wide-report/report.html`, native frame PNGs,
`tracking-tests-final-v2.log` and source/tool SHA256 hashes in `provenance.json`.

Next experiment should verify fixed-support positions on disjoint native printed
and reflective materials, then test a brightness estimator with sufficient dark
signal and independent held prediction. Do not lower dark/clipping thresholds
solely to make the recovered black-print patch qualify. A shipping geometry
change still requires independent encoded/target controls, partial Strength and
Spatial settings, Fox regression and actual visual improvement.

## Independent native verification — 11 October 2026

The proposed next stages were attempted in order. The source-verification and
brightness-measurement prerequisite did **not** qualify the main flash, so no
bounded field fit, candidate export, Fox correction run or slider acceptance was
performed. Those stages remain pending; this is not a correction acceptance pass.

`NativeDisjointSupportAudit.swift` now checks recovered V40 source trajectories
with geometry and photometry on separate native pixels. A fixed source-grid phase
and complete moving support envelopes retain 43 nonoverlapping LEGO probes.
Native geometry uses a surrounding ring; central photometry uses 25 radiance
samples, each averaged from a 5×5 native tile. Actual decoded interval PTS must
match the original source diagnostic. All central contributors are checked for
near-clipping/invalid RGB before fractional interpolation and tile averaging.
That contributor check prevents a clipped native pixel disappearing inside a
bilinear sample. The existing dark, gain/offset and held-prediction limits remain.

Three geometry probes were compared: affine-normalized native RGB, native
luminance-gradient directions, and gradient directions after a non-ringing 3×3
box average at ±3 native pixels. Gradient qualification requires strong signal,
two independent directions, score ≥0.99 and a reciprocal position check. Central
brightness pixels never participate in geometric validation. Failed photometry
is retained for inspection even when native geometry fails, and never becomes an
eligible correction donor.

The final filtered-gradient/contributor-clipping run accepts 99 of 304 adjacent
LEGO geometry checks; 138 fail shape agreement, 44 lack usable geometry, 14 need
native refinement and 9 fail reciprocal position. Coarse track recovery alone
therefore does not establish native identity. These tests cannot distinguish all
appearance changes from motion, or independently certify unique/color identity.

Across main events 187 and 188, all 74 available native central fits fail:

| Source photometry rejection | Count |
|---|---:|
| Nonuniform held affine response | 30 |
| Dark linear luminance | 21 |
| Unidentifiable or unbounded response | 11 |
| Native clipping/invalid contributors | 6 |
| Invalid interior prediction | 6 |

This remains zero qualified fits even before requiring native geometry. At the
worst nearby printed probe (431,303), 625 native pixels give mean Y
0.007812 → 0.026128 → 0.009061 across 186–188. Individual tile means fall to
0.003701, below the unchanged 0.005 validity floor. The nearby (495,303) probe has
adequate mean brightness but event-188 held error 0.181314 EV, well above 0.04.
No threshold was relaxed to make these patches qualify.

One LEGO fit qualifies at event 185, away from the main flash, with representative
excursion 0.201841 EV. This does not demonstrate that event 185 is unwanted
illumination, authorize a correction there, or supply a donor for event 187.

The unchanged-motion and clean intentional-ramp controls retain only **one**
nonoverlapping, in-bounds region each. Their four qualified measurements have
maximum absolute representative excursions 0.001640 and 0.001138 EV respectively.
These sparse checks are consistent with preserving quiet/gradual lighting but
are not a correction matrix or proof of generalization. Ramp positions are
borrowed from a synthetic case with the same known motion/reflectance construction
and then independently checked on the target movie's native pixels.

Final evidence: `.build/review-v41/report-verified.html`,
`{lego,clean,ramp}-verified.json`, `verification-verified.json` and
`frozen-verified/`. The earlier `report.html`/`*-final.json` are provisional
pre-contributor-clipping measurements; use the verified files above. Source,
core, tool, binary and fixture hashes are retained. Self-tests pass for positive
edge scaling, changed orientation, degenerate/missing edges, fractional clipped
contributors, zero-weight clipped neighbors and sample bounds. The native tool
builds; project validation and `git diff --check` pass. Automatic app correction
is unchanged; no new encoded improvement is claimed.

Next move to broader stable printed landmarks/object geometry, with separately
measured uncertainty on dark patches. Do not continue fitting small-patch affine
corrections to the main event: the independent native checks have not supplied
trustworthy support. Bounded correction and sequential encoded/neighbor/control
validation remain conditional on resolving that source-evidence gap.

Reproduce the final native probe using retained V40 source tracks and a fresh
report path (native runs require macOS decoding services):

```sh
zsh -c 'source scripts/correction-sources.sh; swiftc -parse-as-library -O "${CORRECTION_SOURCES[@]}" scripts/validation/NativeDisjointSupportAudit.swift -o /tmp/frank-native-support'
/tmp/frank-native-support self-test
FRANKLUMA_NATIVE_EDGE_GEOMETRY=1 FRANKLUMA_NATIVE_EDGE_BOX=1 /tmp/frank-native-support .build/review-v40/lego188-wide.json /tmp/frank-lego-native-support-new.json
```

### V42: broader printed edges and spatial metering sensitivity

The source-only native audit adds an optional 70-native-pixel geometry ring
(previous radius 35), sampled every six pixels to retain comparable sampling
cost. Central 25×25-native-pixel photometry, clipping validation, geometry score
threshold and held lighting limits remain unchanged. This is a broader edge
probe, **not** a coherent object/landmark transform or proof of unique identity.
Complete moving envelopes retain 23 disjoint LEGO regions instead of 43; the
other 20 overlap the enlarged envelopes and are excluded.

On the same 159 adjacent pairs for those 23 regions, narrow/broad geometry gives:

| Paired result | Count |
|---|---:|
| Both accepted | 38 |
| Narrow accepted, broad rejected | 15 |
| Narrow rejected, broad accepted | 3 |
| Both rejected | 103 |

Broad geometry therefore loses more accepted pairs than it recovers. It supplies
zero qualified lighting fits overall and remains rejected for integration.
The original-radius replay reproduces the V41 counts exactly (99/304 adjacent
checks accepted, one qualified event-185 fit, none at main events 187/188).

New diagnostics retain ±3-native-pixel central-meter location sensitivity and
leave-one-row/column-of-tiles brightness sensitivity. At printed probe (431,303):

| Frame | Dark tiles / 25 | Location brightness range (EV) | Maximum spatial deletion change (EV) |
|---|---:|---:|---:|
| 186 | 18 | 0.72918 | 0.68981 |
| 187 | 0 | 0.47339 | 0.49526 |
| 188 | 14 | 0.74138 | 0.56188 |

The brighter (495,303) probe has no dark tiles at these frames, but position
ranges 0.44125–0.53303 EV and spatial deletion changes 0.13931–0.14296 EV.
These are observed spatial sensitivities, **not independent noise estimates,
confidence intervals, measured temporal flicker error, or a reason to lower the
dark floor**. Texture, illumination gradients and correlated compression can all
contribute. In particular, clean-motion/ramp controls exhibit spatial position
ranges up to about 0.183 EV while their qualified temporal excursions remain
below 0.002 EV. Large absolute spatial sensitivity alone does not establish a
bad temporal measurement.

Both sparse controls reproduce four qualified measurements, maximum absolute
excursions 0.00164022 EV (clean motion) and 0.00113798 EV (clean ramp), using the
original-radius geometry because the control raster is only 320×192. No broader
control generalization or correction/slider acceptance is claimed.

Evidence: `.build/review-v42/{lego-broad,lego-sensitivity,clean-sensitivity,ramp-sensitivity}.json`,
`review.json`, build logs and `frozen/`. `report_native_sensitivity.py` verifies
in-bounds/disjoint envelopes and compares identical source pairs; the review
records SHA-256 hashes of reports, source movie, tool, summarizer and binary.
Native build and edge/clipping/sensitivity self-tests pass, including a uniform
meter, a dark printed stripe and invalid contributing pixels. Automatic correction
is unchanged and no new candidate was exported.

The broad-radius hypothesis is exhausted by this result. Next investigate a
coherent transform from several separately identifiable printed landmarks with
held landmarks, then measure *temporal* brightness sensitivity over independently
allowed geometry positions. A calibrated dark-noise estimate still needs repeat
source evidence or a known-noise reference; this pass does not provide one.
Correction fitting remains conditional on both geometry and lighting evidence.

### V43: spatially held landmark transforms and temporal position sensitivity

Added `NativeLandmarkTransformAudit.py`, a source-only similarity-transform check
using nominal transported positions that already passed separate native shape
and reciprocal checks. Fixed spatial blocks split landmarks into two folds.
Each fold needs at least three landmarks with two-dimensional spread; each
independently fitted translation/rotation/scale must predict the other fold
within one native pixel and agree with the other model within one pixel.
Neither rejected landmarks nor local diagnostic refinements enter the fit.
The tool does not warp pixels or propagate geometry into unsupported meters.
This checks coherence of the ROI's landmark pool; it does not segment rigid
objects or independently establish unique printed identity.

A denser source phase (spacing 24 analysis pixels, phase 15) retains 80 fully
disjoint native supports instead of the previous grid's 43. The grids differ,
so overall accepted counts are not a like-for-like quality comparison. Strict
filtered-edge geometry accepts 146/577 pairs. It has only one accepted landmark
at 186→187 and two at 187→188. Thus neither main transition supports an
independently held transform. Quiet 184→185 and later 188→189, 189→190 and
190→191 pools do qualify; the 191→192 pool fails held agreement.

Also tested native linear-luminance shape correlation on the same 80 supports.
The geometry diagnostic permits positive affine intensity variation, requires
at least 75% shared unclipped RGB support, luminance variance above 1e-6,
contrast ratio in [0.25,4], correlation ≥0.995 and the unchanged reciprocal
position/nominal-location checks. This avoids requiring independent texture
variance and matching affine response in each colour channel. It is geometry
only and does not certify colour identity or an illumination model.

Luminance geometry accepts 169/577 pairs, including four landmarks on each main
transition. Four still cannot supply two independently spread three-landmark
folds. Only quiet 184→185 qualifies as a held transform; later ROI-wide pools
fail held agreement. Different objects, appearance changes and correspondence
errors have not been separated. A failed pooled transform does not prove that
every individual object moves incoherently.

Both dense geometry variants qualify the same two photometric measurements at
(447,183), events 189 and 190 (−0.09824 and −0.15542 EV). They provide no main-flash
qualified measurement. Across events 187/188, 140 of 141 central photometric
fits reject independently of geometry; the remaining fit at (447,423), event
188, fails native shape checks on both adjacent transitions and remains unusable.
The two later fits are not independently established unwanted lighting and
cannot be used to fill the missing main-event measurements.

Temporal position sensitivity now computes each three-frame arithmetic-radiance
excursion under the **same** ±3-native-pixel displacement in all frames. This
is a stress test, not independently certified alternative geometry or a noise
confidence interval. It does not loosen photometric limits.

| Probe | Event | Nominal integrated excursion (EV) | Maximum position-induced change (EV) |
|---|---:|---:|---:|
| Dark printed (431,303) | 187 | 1.63089 | 0.19552 |
| Dark printed (431,303) | 188 | −0.94291 | 0.27571 |
| Brighter (495,303) | 187 | 1.42319 | 0.03684 |
| Brighter (495,303) | 188 | −0.78179 | 0.03640 |

These are unqualified integrated source measurements, not fitted illumination
or encoded residuals. This distinguishes substantial dark-patch temporal
sensitivity from V42's much larger *absolute spatial* brightness range. The
original filtered-edge clean/ramp controls reproduce four qualified temporal
measurements each, with position-induced excursion changes at most 0.00413 /
0.00460 EV respectively on their one retained region.

Dense luminance geometry retains six disjoint native regions in each clean
control. Clean motion accepts 70/94 geometry pairs and 62 photometric
measurements (maximum absolute qualified excursion 0.00012757 EV). The clean
ramp accepts only 4/94 geometry pairs and two measurements (maximum 0.00107734
EV). That serious coverage difference is unresolved; it is not evidence of
false correction or permission to promote the luminance matcher. Ramp locations
remain borrowed from the shared synthetic motion construction, then verified
on its native target pixels. Only the last two clean-motion transitions have
enough spatially spread landmarks to qualify a held transform; ramp has none.
No full correction or slider control matrix ran.

Verified artifacts: `.build/review-v43/*-final.json` source reports,
`*-landmarks-verified.json`, `review-verified.json` and `frozen/`. Earlier JSONs
without these suffixes are exploratory; final reports use the same frozen
`native-support-luma` binary. Exact source PTS, in-bounds/disjoint envelopes and
unchanged original-radius V41 geometry/photometry are checked. Self-tests cover
known rotation/translation, held displaced landmarks, collinearity, sparse
folds, affine luminance shape, flat/changed texture, uniform temporal scaling,
clipping and spatial sensitivity. Native builds, Python compilation, project
membership and diff checks pass. Automatic correction is unchanged; no encoded
candidate or improvement is claimed.

The held-transform infrastructure is in place, but coherent uniquely identified
object landmarks across the main flash remain unresolved. Next inspect source
landmark identity and contrast changes specifically at 186→187 and the ramp
coverage failure, rather than increasing density again or weakening the shape
threshold. Calibrated dark-noise/repeat evidence and a source-supported lighting
model remain prerequisites to correction fitting.

V43 control follow-up isolates a definite false geometry rejection.
`audit_stationary_ramp_geometry.py` inspects (39,39) using the retained synthetic
foreground ground truth, **only for diagnostic control verification**. For
frames 28–33 the moving foreground never intersects any column of its complete
native sampling/search envelope, even across the full image height. The fixture
construction gives this background constant geometry and reflectance plus the
neutral intended ramp. Native clean scores are 0.99997–1.00000 on the five adjacent
pairs; ramp scores are 0.99066, 0.98348, 0.97599, 0.98814 and 0.98881, all rejected
at 0.995, with zero best refinement. Thus the shape score rejects genuine
stationary structure under the encoded/decoded gradual intensity change.
This does not isolate quantization, compression or colour-transfer causes,
calibrate LEGO noise, or justify an arbitrary lower score. It supplies a concrete
calibration reference for the next geometry model. Ground truth is not used to
select app donors or to alter the LEGO correspondence result. Evidence and
hashes: `.build/review-v43/stationary-ramp-review.json`; script frozen with the
other diagnostic sources.

### V44–V45: geometry averaging and held colour-response hypotheses

A source-only 5×5 non-ringing native RGB average before luminance-shape matching
retains all native contributor clipping checks and the 0.995 shape threshold.
Central brightness metering is unchanged. Source support envelopes expand by
two pixels; controls retain four regions instead of six. Comparing only the
same 62 control pairs, averaging recovers 24 ramp matches and loses none, while
clean motion loses two and recovers none. The known stationary background is
verified only through frame32 with the enlarged envelope: frame33 intersects
foreground in the conservative full-height envelope-column check and is not
included. Of the four fully verified stationary-ramp pairs, averaging recovers
two; the other scores are still 0.99415 and 0.98192, below the unchanged threshold.
It does not solve the calibration failure. Native self-tests also reject shifted
and replaced texture, recover the correct displacement, and preserve rejection
of clipped contributors before averaging.

Averaged LEGO geometry accepts296/577 pairs, with7/8 landmarks at the main
transitions. The first cannot establish a spatially spread held fold; the second
fails held transform agreement (maximum held position error6.88native pixels).
Main photometry stays exactly unchanged and still supplies no qualified fit.
Evidence `.build/review-v44/review-verified.json`, source JSONs, held landmark
report, `stationary-ramp-*-verified.json`, build logs and frozen tools/core/binary.
This is not production tracking or correction improvement.

V45 exports the original native25tile RGB means (625native contributors per
meter) with actual source PTS for source-only response testing. Invalid/clipped
contributors make the entire exported meter unavailable. Geometry-only RGB
averaging never alters these brightness samples.
`NativeSharedResponseAudit.py` evaluates five hypotheses: neutral affine
luminance, positive spectral gain plus offset, affine RGB channels, neutral
log-luminance contrast/tone, and separate log-RGB contrast/tone. Shared fits
hold out whole disjoint native patches; local fits hold out complete disjoint
native tile rows and cannot claim shared illumination. Positive bounded gains
[0.25,4] are an experimental model envelope; the app's existing gain limits
are unchanged. All source/held luminance must exceed0.005; contributor clipping,
held prediction0.04EV and interior/model agreement0.04EV gates remain.

None qualifies at main events186/187/188. At187, six bright geometry-retained
patches exist, but shared neutral/RGB affine held errors reach0.728/0.553EV;
log-tone models reach0.729/0.576EV. Spectral gains/offset cannot be identified
within their bounds. Local row-held models also supply zero accepted main fits.
The failure is not solely a lack of geometry or the old affine gain≤2 bound.
Clean/ramp local controls retain near-quiet fits; their shared tests have too few
whole patches for the six-patch requirement. No shared calibration acceptance
or full correction control matrix is claimed.

V45 source RGB and model reports reside in `.build/review-v45/`; native build,
source PTS validation and response self-tests pass. The tests cover exact known
RGB response, held material replacement, rank deficiency and insufficient whole
patches. No output candidate was generated from these rejected measurements.
The next bounded measurement test uses geometry-only native refinement, with
reciprocal and three-frame triangle checks, before changing photometric models
again. Image pixels will not be warped; only the independently measured source
meter location may move within the already disjoint native support envelopes.

## V46–V49: integrated regional radiance and measured export improvement

The refined per-pixel scalar, RGB and log-tone response models still accept no
main-event LEGO patch at 186/187/188, including the five-row local holdout fit.
See `.build/review-v46/{lego,clean,ramp}-refined-rgb.json` and the local/shared
response reports. Geometry refinement therefore did not make uniform response
inside a material patch a supported assumption.

The next hypothesis measures **integrated native regional radiance**, rather
than requiring uniform per-pixel response. `NativeMeanFluxAudit.py` retains the
native geometry, contributor clipping, positive tile-luminance and complete
support-envelope checks. An event requires four other disjoint meters split
into two spatial folds corroborating its timing and sign. It does not transfer
donor amplitude into a query. A query must also exceed its local geometry-stress
margin and a fixed research margin. These are research guards, not a calibrated
sensor-noise bound or proof that the lighting is unwanted.

With geometry-only 5×5 averaging, unchanged 0.995 shape correlation, reciprocal
and triangular native checks, and unaveraged 625-pixel brightness meters, the
LEGO evidence has these available/active counts:

| Event | Meters | Active |
| --- | ---: | ---: |
| 185 | 15 | 10 |
| 186 | 5 | 5 |
| 187 | 5 | 5 |
| 188 | 5 | 0 |
| 189 | 42 | 0 |
| 190 | 33 | 0 |
| 191 | 31 | 0 |

`NativeMeanFieldFit.swift` fits bounded, neutral coarse exposure increments onto
the retained 96×56 source-guided maps. It holds window endpoints fixed, measures
source-selected transition guards through the native renderer and backtracks
before accepting a nonlinear field step. The native fitting measurements and
rendered guards select the field; frozen encoded audit residuals are never
loaded by the fitter. Exports remain sequential. Exposure-only fitting performed
better than the experimental tone basis on this event.

The preferred **main-transition research export** is:
`dist/Benchmarks/review-v48-native-flux/lego-exposure-8/corrected.mp4`.
Its retained encoded audit gives:

| Measurement | Retained baseline | Candidate | Reduction |
| --- | ---: | ---: | ---: |
| 187→188 median absolute EV | 0.118768 | 0.066266 | 44.2% |
| 187→188 maximum absolute EV | 0.605647 | 0.381237 | 37.1% |
| RMS of 161 supported transition medians | 0.035150 | 0.033664 | 4.2% |

Every surrounding transition from 184→185 through 191→192 has a lower median and
maximum in this retained phase. Individual footprints can still regress; the
aggregate result must not be described as a per-footprint guarantee.

A separate encoded audit shifts the measurement grid from phase 6 to phase 7.
It keeps all source-selected locations and source values identical between the
baseline and candidate. On its 41 main-event footprints, median EV falls from
0.111461 to 0.074686 (33.0%) and maximum from 0.644875 to 0.551737 (14.4%). The
quiet lead-in maximum and 189→190 median vary by less than 0.001 EV. Thus the
improvement generalizes spatially, but its size depends on footprint placement.
The selected fields were exactly reproduced using the frozen V48 fitter.

A true half-strength version scales the accepted full increments relative to
the retained baseline, without refitting. Its main median/max are
0.091875/0.492347, between the baseline and full candidate. Refitting independently
at half amount produced a different field and is **not** the verified slider
implementation. Media checks preserve all 212 frame timestamps, dimensions,
packet durations and copied audio payloads.

Dense source guards at every fourth pixel across the valid interior provide a
more conservative alternative in
`dist/Benchmarks/review-v49-native-flux/lego-dense-exposure-8`. This improves the
early flash transitions more strongly while giving less reduction on 187→188.
Those guards include retained-phase locations; do not call that phase a spatial
holdout. Phase 7 remains outside their even-coordinate guard grid.

Cross-clip checks use unchanged meter rules on Fox. Its first candidate is
rejected for neighboring regressions. Dense protection lowers 558→559 median
from 0.048706 to 0.033514 (31.2%) and maximum from 0.406893 to 0.260401 (36.0%).
The independent phase lowers median/max by 26.1%/36.8%. A quiet 561→562 maximum
still rises from 0.006696 to 0.008633, so this is retained as research evidence,
**not accepted for automatic shipping**. Tightening the renderer guard to
0.0001 EV yields no accepted step; the current coarse-RGB guard Jacobian and
native rendering precision are limits worth resolving rather than bypassing.

The original small clean/ramp fixtures activate nothing but have fewer than the
five meters required for a complete query/donor quorum. Stronger controls make
3× nearest-neighbor upscaled and re-encoded copies of the independent clean
fixtures. The clean-motion source has 19–27 meters per event; the intended fade
has eight, tracked from its own source rather than borrowed clean locations.
Neither activates any correction across events 29–43. These derived fixtures
exercise support and quorum behavior, **not independent sensor-noise evidence**.
The original clean-motion candidate also preserves retained fields exactly and
has identical decoded foreground/background target scores. The original ramp
field passthrough is exact; it does not resolve the previously documented
small-raster geometry rejection.

The source hypothesis is now supported by a substantial measured LEGO export,
not only diagnostics. Automatic app correction remains unchanged: current
native sampling uses a diagnostic window/ROI, and cross-clip protection still
needs work before a general shipping route. The most promising next approach is
tracked regional radiance with smooth neutral fields, plus a guard Jacobian that
measures native pixel response rather than applying the field to RGB thumbnail
means. Keep the conservative per-pixel response validator intact.

Measurements, individual regressions, controls and artifact hashes:
`dist/Benchmarks/review-v49-native-flux/report/{index.html,report.json}`.
Fitter/native-meter sources and binaries: `.build/review-v48/frozen`.
Shifted evaluator source: `.build/review-v49/ShiftedMatchedSurfaceAudit.swift`.
