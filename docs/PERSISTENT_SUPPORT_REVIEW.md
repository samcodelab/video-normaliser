# Persistent support diagnostic

The source-selected matched-footprint reports establish exact-coordinate track
continuity without using corrected-frame measurements to choose tracks. The
diagnostic also optionally compares each track to its episode-start source
texture, using channel-centred log-RGB correlation above 0.95. It never snaps
fractional endpoints onto a new sampling grid.

On the main LEGO transition 187–188, 36 tracks have at least four frames of
support, both before and after episode-start validation. This is useful support
for investigating a spatially restricted residual correction.

On the independent-lighting local-moving control, pairwise continuity gives
45 and 46 four-frame tracks on transitions 35–36 and 36–37. Episode-start
validation leaves only six and five. Earlier full-footprint ground-truth mask
checks showed these wide matches contain background only. The stronger identity
test therefore cannot currently distinguish a large legitimate illumination
change from an identity failure reliably enough to gate correction.

Artifacts are `persistent-exact-support-v2.json`,
`lego-persistent-anchored-support-v3.json` and
`local-persistent-anchored-support-v3.json` in
`dist/Benchmarks/general-review-v30`. Each contains input hashes. The script is
`scripts/validation/audit_persistent_support.py`.

This is an offline diagnostic, not a production correction. Exact-grid linking
underestimates support during camera motion. Pairwise or anchored texture
correlation does not establish physical identity, and there is no demonstrated
export or perceptual improvement from this diagnostic. Next work must make
identity validation robust to illumination while retaining temporal support,
then fit correction through a persistent spatial basis rather than applying a
global adjustment to an independently changing per-frame mask.

## Lighting-slope identity experiment

The control generator applies a Gaussian spatial exposure pulse to background
pixels. Across a footprint this changes the texture as well as its mean, so a
uniform-exposure-invariant descriptor is insufficient. A linear per-channel
normalized descriptor (v4) worsened continuity and is not a candidate.

The v5 offline descriptor subtracts a least-squares x/y lighting plane from each
channel's log texture before comparing against the episode-start texture. It
retains 45 and 46 four-frame tracks across control transitions 35–36 and 36–37,
and retains the 36 four-frame LEGO tracks across 187–188. Reports are
`local-persistent-plane-support-v5.json` and
`lego-persistent-plane-support-v5.json`. An analytic check confirms invariance
to multiplicative planar log illumination and rejection of a shifted textured
surface. This is promising identity evidence, not correction-quality evidence.
Removing low-frequency texture can also weaken identity discrimination; motion,
occlusion and low-texture controls remain necessary before production use.

## Native experimental integration

`PersistentSurfaceIdentity` in `SpatialLighting.swift` implements the log-plane
descriptor with a residual texture-energy floor. The optional
`FRANKLUMA_PERSISTENT_FLASH_SUPPORT=1` flag makes the existing shared-flash probe
require three consecutive matched edges and episode-anchor agreement. It still
requires `FRANKLUMA_SHARED_FLASH_ANCHOR=1` to run that probe. Both remain off by
default. Row-model gaps reset episodes; exact coordinate linking deliberately
does not invent continuity during fractional camera movement.

This integration supplies persistent source support to an existing experimental
global solver. It does not yet implement the required spatial basis and must not
be promoted as a solution for independently lit subjects. The new native tests
exercise illumination invariance, shifted-texture rejection, flat/planar texture
rejection and bounds. Encoded exports and broad generalization checks remain
outstanding.

## Fixed spatial basis probe

`audit_persistent_basis.py` selects exact stationary support throughout an
explicit interval, checks episode-start log-plane identity at every frame, and
builds a fixed union of tapered 13-pixel footprints. It fits a bounded coefficient
through the actual arithmetic luminance response of decoded corrected pixels,
rather than multiplying an already fitted global gain by a mask.

For the explicitly selected LEGO interval 183–192 and transition 187–188,
36 source tracks survive. A shared coefficient reaches the 0.25 EV bound.
Spatial-half holdouts improve RMS from 0.21064 to 0.15820 EV and from 0.15623 to
0.09958 EV. Across all 40 stationary transition footprints, median absolute
step decreases from 0.12777 to 0.07267 EV (43%). Neighboring transition medians
are essentially unchanged, with the largest increase approximately 0.00023 EV.

However, individual held patches worsen by 0.10234 and 0.09202 EV. Thus the
single-coefficient fixed union is not suitable for promotion: supported surfaces
still need distinct coefficients or protection against opposing residuals.
Coarse 1 EV material partitions provide no sufficiently populated spatial-half
holdouts in this interval, so that alternative is unproven rather than successful.

Results are `lego-persistent-basis-v1.json` and
`lego-persistent-basis-all-v2.json`/`lego-persistent-basis-all-v3.json`. These
are thumbnail-only diagnostic results with an explicitly chosen interval,
full-strength zero-step target and overlapping footprints. No native rendered
export, automatic episode selection, brightness preservation, slider validation
or perceptual improvement is established by these results.

## Independent-coefficient probe

`audit_local_basis.py` now fits one bounded coefficient per source track through
the nonlinear arithmetic-patch luminance response. Overlapping basis weights
are normalized so anchor density does not multiply amplitude. Five Gauss–Newton
iterations use a fixed ridge prior; complete sampling rows are held out from
photometric fitting, while retaining their source geometry. Analytic checks
verify the response Jacobian and recovery of two independent lighting gains.

With the same explicit LEGO interval and a 0.05 ridge, training-set RMS falls
from 0.18693 to 0.13091 EV. All six row-holdout RMS values improve, but one held
bottom-row patch worsens by 0.05294 EV. Training-fit worst increase is 0.00632 EV.
Thus training improvements do not establish acceptable generalization.

A fixed reference-frame chroma gate of 0.3 EV reduces the worst holdout increase
to 0.00605 EV. All row-holdout RMS values still improve, but overall training RMS
only falls to 0.17564 EV (6%). This gate is fixed across time, so it does not
introduce per-frame color-mask turnover. It also discards substantial useful
correction support. Neither version is ready for promotion.

Reports are `lego-local-basis-v1.json` and
`lego-local-basis-appearance-v2.json`. The latter initially encountered numeric
underflow in negligible appearance weights; weights below 1e-12 are now omitted
before normalization. These are offline stationary thumbnail probes. Their
explicit interval, full-strength zero-step target, overlapping source footprints
and absence of export/brightness/slider validation remain limitations.

## Independent-lighting control and temporal fit

The existing half-strength control export was decoded with the frozen native
thumbnail sampler into `local-half-corrected-thumbnails-v1.json` under the
shared-flash experiment directory. Source interval 32–39 supplies 43 persistent
stationary tracks. No source or corrected video was modified.

The local solver now uses the intended partial target
`(1 - Strength) × source step + Strength × intentional trend`, and scales the
coefficient bound by Strength. For this pulse test Strength is 0.5 and trend is
zero. Ground-truth foreground masks are used only for diagnostics, never for
selecting support or fitting coefficients.

The single-edge probe v4 reduces target-error RMS from 0.04279 to 0.01300 EV
on fitted transition patches, but holds the coefficient afterward; this does
not establish correct return to scene brightness. The v5 temporal solver fits
all seven interval edges jointly through the same fixed spatial basis, with
endpoint gains constrained to zero. Its fitted RMS decreases from 0.02002 to
0.00252 EV. All six complete-row holdouts improve; the worst individual held
increase is 0.00661 EV. All ground-truth foreground thumbnail-centre pixels
receive zero added gain throughout the interval. The temporal patch-response
Jacobian agrees with finite differences.

Reports are `local-half-local-basis-v3.json`,
`local-half-local-basis-v4.json` and `local-half-temporal-basis-v5.json` in the
general review directory. These findings support further native integration,
but do not establish full-resolution foreground exclusion: the mask audit uses
thumbnail centres. Automatic interval selection, moving/camera geometry,
scene-cut boundary conditions, intentional ramps, native rendering, encoded
media integrity and broad slider coverage still require validation.

## Swift solver parity

`PersistentLightingSolver` now implements the temporal arithmetic-luminance
response and its Jacobian in Swift. Its matrix-free conjugate-gradient normal
solve avoids storing a dense frame-by-track matrix. It retains five nonlinear
iterations, a positive ridge prior and bounded coefficients. It is a reusable
native solver, not yet a renderer stage.

The frozen `PersistentSolverAudit.swift` runner solved the identical half-strength
control input: 258 coefficients and 301 patch transitions. Maximum difference
from the Python direct solver is 1.13e-12 EV; fitted RMS differs by 9.82e-15 EV.
Evidence and all input/source/binary hashes are in
`.build/review-v33/persistent-lighting-solver-native-v1/parity-review.json`.
Native tests verify independent gains, zero amount, temporal derivatives and
invalid support. The full 162-test native suite passes. Next integration must
select episodes automatically and fit through the actual renderer; parity alone
does not demonstrate an exported video improvement.

## Automatic native stage

`FRANKLUMA_PERSISTENT_LOCAL_FLASH=1` selects an experimental stage after the
existing brightness anchor, taking precedence over the global shared-flash
probe. It detects source-step outliers relative to a local trend, forms bounded
nonoverlapping intervals, trims unsupported margins using source evidence,
requires persistent stationary 13-pixel tracks and fits a fixed chroma-gated
spatial basis. Interior interval boundaries return to zero; actual scene edges
can retain a coefficient. Strength sets the partial target and Strength × Spatial
bounds added coefficients. Reference-region mode is excluded. Default builds
do not enable this stage.

Initial native integration exposed new quiet-frame errors of 0.03029 EV from
soft temporal fitting, and the no-regression gate rejected the result. The
revised stage shares coefficient variables across source-quiet transitions,
allowing changes only at source outlier steps. The stationary-pulse integration
test now passes with zero worst increase on quiet edges. Ideal half-strength
output and Spatial 0 remain untouched. The full 163-test native suite passed;
the log is `.build/review-v33/persistent-local-flash-v4-full-tests.log`.

Actual exports and independent-lighting checks remain required before promotion.
Camera transport is unsupported by this stage; stationary identity is required.
Full-resolution boundary leakage, intentional lighting, scene brightness,
held-surface errors and broad slider coverage remain open validation needs.

## First encoded native control results

The v4 frozen native runner exported the 72-frame independent-lighting control
at Strength 0.5 and 1. Independent media-integrity checks pass at both settings.
The first invocation failed before export because the runner-local provenance
file was missing; that failed label was retained, and the successful half-strength
run uses the new immutable label `persistent-local-flash-v4-half-strength-r1`.

`PartialTargetAudit.swift` evaluates full-resolution decoded output against a
target derived independently from source and clean benchmark frames:
`target Y = source Y^(1-Strength) × clean Y^Strength`. It preserves source
chromaticity, uses the ground-truth masks, and does not use fitted trajectories.
The zero-strength source-versus-source sanity check returns zero error.

At half strength, background target-error RMS decreases from 0.003913 to
0.001385 EV (65%); peak adjacent target error decreases from 0.017476 to
0.006672 EV. Foreground RMS changes only slightly, 0.018077 to 0.018017 EV,
and remains an existing unresolved problem. Clean-target residual background
variation increases slightly because half the source variation is intentionally
retained; this is why the independent partial target is necessary.

At full strength, however, clean-target background RMS worsens from 0.001149
to 0.003532 EV; peak adjacent error worsens from 0.005047 to 0.019529 EV.
Tracked-thumbnail fits improve while full-region brightness worsens. This stage
must remain off by default until local fits preserve or improve the correct
scene brightness at full resolution. The decision and input hashes are in
`persistent-local-v4-control-review.json`; partial-target and independent media
reports are beside it in `dist/Benchmarks/general-review-v30`.


## Weight normalization and brightness-scope ablation (v5–v8)

Support-aligned photometry (v5) and aggregate brightness constraints (v6)
did not resolve full-strength encoded regression. Background RMS is respectively
0.002693 and 0.003545 EV, versus current-app 0.001149 EV.

The old basis sums to the strongest triangular donor, producing gain peaks
even for identical coefficients. Experimental v7 separates appearance
confidence from normalized interpolation and applies one three-thumbnail-pixel
taper at the source-fixed union boundary. Compatible interiors reproduce a
constant gain; weak appearance evidence remains attenuated. Tests cover two
anchor densities, duplicated donors, boundaries and weak donors. The full v7
native suite passes 165 tests. This proves representation properties, not
physical material identity or video quality.

V7 encoded background RMS remains worse at full strength: 0.003623 EV,
peak adjacent error 0.019622 EV. At half strength, independent partial-target
background RMS improves 0.003913→0.001937 EV; foreground error remains
0.018077→0.017973 EV. Both v7 exports pass independent timing/media checks.
Do not promote it from its half-strength improvement.

A v8 diagnostic switch, `FRANKLUMA_CONSTANT_SURFACE_ANCHOR=1`, retains
constant shot brightness but disables the later varying global surface and
registered-camera residuals. This is an ablation, not a proposed user mode.
Crossing it with legacy and normalized bases gives background RMS
0.009839/0.009788 EV and foreground RMS 0.017695/0.017629 EV. Constant-only
anchoring without the new local stage gives background 0.010731 and foreground
0.017567 EV. Existing anchoring with the legacy local basis reproduces v6
metrics exactly, confirming the comparison controls.

Thus removing the varying anchor reduces foreground amplification, but damages
background correction and leaves a substantial pre-anchor foreground error.
The evidence supports investigating source-supported spatial scope of residuals,
not removing scene brightness preservation. New basis normalization alone does
not fix the underlying correction. All new stages remain off by default.
The v8 branch compiled and completed encoded factorial checks; its full native
suite has not yet been rerun. These controls do not establish LEGO/Fox improvement.
Immutable score hashes and comparison are in
`dist/Benchmarks/general-review-v30/persistent-local-v7-v8-control-review.json`.


## Source-tracked residual scope, first control (v1)

`FRANKLUMA_TRACKED_SURFACE_RESIDUAL=1` tests a local residual fit after constant
shot anchoring. Source-only forward/backward matches form trajectories, wide
plane-normalized identity is checked against each trajectory's initial source
patch, and at least five observations establish an individual brightness trend.
Only two prepared images remain live; finished histories store observations.
The fit measures arithmetic luminance from rendered RGB, uses source-guided
local neutral gains, and renders no reference or neighbouring-frame pixels.
It retains partial Strength/Spatial targets and bounded gains. This is still
experimental, not a user-facing mode.

On the independent-lighting control, full-strength foreground RMS improves
0.027460→0.017125 EV (~38%), but background RMS worsens
0.001149→0.007330 EV. The export passes independent timing/media checks.
At half strength, the independent partial target gives background
0.003913→0.003892 EV and foreground 0.018077→0.008118 EV (~55%).
The synthetic stationary pulse, ideal partial target and disabled Spatial tests
pass. These results do not establish scene-wide quality or LEGO/Fox improvement.
The remaining full-strength regression prevents promotion.

V2 compares measurement-footprint identity (5×5) with v1 wide identity (13×13),
and provides an ablation retaining the existing varying global anchor.
A small footprint may admit ambiguous or repeated surfaces; motion, occlusion
and no-flicker controls are required. Source identity plus local photometry
alone does not prove independently changing illumination can be separated from
material or camera-response changes.

The v8 full native suite also subsequently passed 165 tests; its terminal log is
`.build/review-v33/persistent-local-flash-v8-full-tests.log`.


## Moving-surface footprint and retained-anchor comparison (v2)

V2 permits plane-normalized source identity on the actual 5×5 measurement
footprint. The original 13×13 default remains unchanged for persistent
stationary support. With constant-only anchoring, local-moving background RMS
is 0.006478 EV and foreground 0.013730 EV: foreground improves, background
still regresses. Retaining the varying anchor instead gives background
0.001047 EV (baseline 0.001149) and foreground 0.020890 EV (baseline 0.027460).
Worst foreground tile error remains essentially unchanged, 0.197289 versus
0.197197 EV; average improvement does not resolve the worst flash.

At half Strength with the retained anchor, independent partial-target RMS
improves background 0.003913→0.002743 EV and foreground
0.018077→0.013774 EV. Full native v2 tests pass 165 tests.

Broader controls reject promotion: global-moving background improves but
foreground worsens 0.008164→0.010748 EV; no-flicker moving foreground worsens
0.001609→0.002893 EV; camera-moving foreground worsens
0.009427→0.010245 EV. Intentional-ramp background worsens
0.004736→0.007498 EV and foreground 0.008485→0.011369 EV.
Occlusion background improves and foreground slightly regresses.
The immutable comparison and hashes are in
`tracked-surface-residual-v2-control-review.json`.

V3 replaces the per-track rolling median in Smooth mode with the production
`ExposureMath.smoothTargets` trend. Rolling windows can alter a gradual ramp
at track endpoints; this change is driven by the intentional-ramp control,
not a threshold tuned to LEGO/Fox. Steady still requests a constant target.
Native endpoint tests and encoded controls remain pending at this entry.
V2 isolated LEGO/Fox exports are running; they do not change the installed app.


## Real LEGO rejection and short-track ramp test

V2 LEGO export passes independent media verification: all 212 video frame
starts/durations and dimensions match, and all 767 encoded audio packets match.
Frozen matched-luminance selection retains the same 161 supported transitions.
Supported RMS worsens 0.035951→0.036009 EV; the main 187→188 flash worsens
0.127806→0.150196 EV (~18%). The following 188→189 transition improves, but
that does not compensate for the worse main flash. This rejects promotion,
even though the independent local-moving synthetic control improved.
`lego-tracked-surface-residual-v2-review.json` records source-selected evidence
and hashes. This metric does not certify physical ground truth or perception.

V3's new short linear-ramp test fails: the production smoother intentionally
uses trimmed temporal windows on spans shorter than four radii, so simply
reusing it retains endpoint flattening for fragmented tracks. V4 adds an
optional `preserveShortRamps` parameter, default false, used only by the
experimental tracked stage to retain the curvature solve on short tracks.
Existing production callers keep their prior behavior. The new endpoint test
remains a required check; do not relax it to accept a changed intentional ramp.
V4 native tests/build and V3 broad encoded controls are running at this entry.
Fox V2 processing is still live and must be measured after export.


## Fox result, short-ramp check, and rapid-only residual hypothesis

V2 Fox export retains 600 frames, 60 seconds and cuts 200/400. Independent
media integrity passes. Frozen matched selection retains all 597 supported
non-cut transitions, but RMS worsens 0.011449→0.033535 EV (~193%). It took
390.55 seconds for analysis/correction with other audit jobs running; this is
not isolated production performance. Its real-video result rejects promotion.

V4's short-ramp endpoint test passes, and all 166 native tests pass. Encoded
controls still reject it: local-moving background/foreground are
0.001087/0.020915 EV, but global-moving 0.006106/0.017328,
camera-motion 0.010223/0.020095 and occlusion 0.006257/0.020075 EV.
Removing short-ramp flattening does not establish that absolute per-track
brightness targets preserve the assembled output's calibration.

V5 therefore tests only rapid required correction: compute r=target−rendered
level on each source-selected track, subtract its slow curvature trend (Smooth)
or its median (Steady), and fit the remainder. Constant/linear calibration is
owned by the existing shot/global stage. This is an unproven hypothesis;
changing basis membership and per-frame acceptance can still introduce steps.
The source descriptor discards means/planes, so correlated texture can also
conceal a changing material. A source-only material-identity audit is needed.
Native constant/ramp/spike tests and encoded controls are required before any
claim of improvement. V5 remains off by default.


## Rapid residual results and benchmark-only occupancy ablation

V5 passes all 167 native tests. It improves several broad controls: global-moving
background/foreground RMS is 0.003522/0.007650 EV, intentional-ramp
0.004357/0.008386 EV and local-moving 0.001143/0.021124 EV. However,
no-flicker moving foreground worsens 0.001609→0.002524 EV, peak adjacent
error 0.006469→0.010087 EV. Largest local-moving foreground tile error stays
about 0.197 EV. Neither broad robustness nor the worst visible error is solved.

`build_tracked_oracle.py` instruments a frozen source copy which depends on the
benchmark harness and cannot compile into the app. Known FG/BG masks classify
25 nearest native labels at each tracked thumbnail measurement centre.
Raw instrumentation reproduces V5 scalar metrics exactly. Only 4/159 quiet
tracks cross a FG/BG label boundary; resetting their histories changes quiet
foreground RMS 0.002524→0.002495 EV. Global-moving reset slightly worsens
foreground; local-moving slightly improves. Thus FG/BG inheritance is not the
main measured error. The diagnostic misses antialiased support and material
changes within foreground, and reset alters coverage; it is not a universal
identity proof. Immutable summaries are `tracked-material-oracle-v1-review.json`.

Stable quiet foreground source steps have RMS 0.00836 EV and requested rapid
corrections 0.00710 EV. Their curvature correlation is −0.943: the estimator
requests flattening of source changes before basis fitting. A fixed-position
track at (31,31), frames 39–46, changes source level despite all 25 sampled
centres being foreground. A clean clip does not authorize removing those
appearance/footprint changes. High-passing the absolute-target residual cannot
solve that target-definition error.

The next estimator separates an independently supported illumination component
from intrinsic source appearance: target = source + Strength×(H(illumination)
−illumination). Unknown evidence must abstain. `audit_source_illumination.py`
is a source-only spatial held-plane prototype; clean thumbnails and oracle
classes score it only after estimation. Its eight-independent-donor quorum
abstains on all foreground observations and many strong local pulse edges;
it cannot yet solve those cases. Supported global illumination step RMS error
is 0.00320 EV versus individual source-step 0.00065 EV, also preventing use as
a replacement. A common temporal component with independently validated
surface response is being investigated on the same frozen source traces.

V5 real exports and independent checks have completed. With exactly the same
source-supported transitions (161 LEGO, 597 Fox), matched luminance step RMS is
0.035951→0.035235 EV for LEGO (2.0%) and 0.011449→0.010331 EV for Fox (9.8%).
LEGO 187→188 remains 0.114238 EV versus 0.127806 baseline (10.6% lower); the
following transition is 0.028138 versus 0.039619. Media integrity checks pass.
These are source-selected patch measurements, not a perceptual guarantee or
independent clean-lighting ground truth. V5 remains rejected because quiet
foreground is harmed and the largest local-moving tile error remains.
Immutable evidence: `tracked-surface-residual-v5-real-review.json`.

`audit_common_illumination.py` freezes source-only lighting evidence before clean
targets load. Quiet footage requests exactly zero across 4,719 observations.
Source-relative step RMS for globally lit BG/FG falls 0.54618→0.00595 and
0.56584→0.00768 EV; local BG 0.19844→0.02596. Those large reductions are against
uncorrected source illumination, not against our existing correction. Local FG
has two supported-absence tracks and 17 unknown tracks, so sparse coverage
remains unresolved. Complete-event validation accepts fewer tracks than
same-pulse temporal folds. Frozen report: `common-illumination-component-v3-review.json`.

`audit_common_gain_calibration.py` tests the next step offline: calibrate only
the existing rendered gain associated with independently supported common
lighting, retaining other gain and source appearance. Baseline thumbnails are
decoded from immutable encoded outputs; clean footage enters only scoring.
The V1 audit is superseded: it fitted gain against raw illumination increments
and then replaced a component in the different H(illumination)−illumination
basis. A correctly adjusted sinusoidal source could receive another 0.099 EV.
V2 fits actual correction increments, with a separately fitted drift term;
its regression test goes through fitting and preserves already correct
full and partial corrections to numerical precision. V1 source is retained
under `.build/review-v33/common-gain-calibration-v1/source/`.
No movie or app default is changed. V2 local FG matched baseline residual
steps improve 0.026215→0.024940 EV with just one supported track; complete-event
validation abstains and leaves FG unchanged. Local BG 0.012136→0.004712
(strict 0.008347); global FG 0.011093→0.008333 (strict 0.010189), global BG
0.006117→0.005719 (strict 0.005755).
Quiet footage receives exactly zero new correction. These source-track-weighted
scores differ from full-frame benchmark metrics and must not be conflated.
Reports: `{local-moving,global-moving,no-flicker-motion}-common-gain-calibration-v2.json`.
Joint validation counts now require both source and gain acceptance, and
baseline residual metrics are labelled accordingly. Four globally lit tracks
still regress by more than 0.002 EV, including mixed/edge and one foreground
track; aggregate improvement does not justify promotion.
Half-strength scores use the matched-footprint log-luminance blend of source
and independent clean footage as target. Local BG 0.007401→0.003112 EV
(strict 0.005043), FG 0.016747→0.016483 (strict unchanged).
These are matched-footprint predictions, not new encoded video exports.

Native source-component/gain calibration is being implemented with timestamp-based
smoothing, scene-local evidence, sparse-surface coverage and stable spatial
support. Actual rendered controls, intermediate sliders and real clips must
pass before promotion. New models remain off by default.


## Native common-lighting review, 8 October 2026

The source-only component and automatic rendered-gain calibration now have
native implementations in `CommonIllumination.swift`. All experimental routes
remain off by default. Calibration uses the actual rendered luminance gain and
physical timestamps; partial Spatial retains the actual global-only rendered
component. Manual EV is excluded. A sinusoidal fixed-point test covers partial
Strength and Spatial: already-correct gains receive exactly zero addition.

V1 encoded testing covered all 18 controls, both strict separate-event and
same-event validation, plus a half-Strength local-moving case. Strict local BG
residual RMS improved 0.0011488 to 0.0009272 EV, while FG changed only
0.0274596 to 0.0273744 EV. Same-event FG reached 0.0263395 EV, with the worst
foreground flash still present. All five clean-motion controls and intentional
ramp remained unchanged in V1. Some other controls regressed, so these aggregate
improvements did not justify promotion. Immutable result summary:
`dist/Benchmarks/general-review-v30/common-illumination-native-v1-review.json`.

For real footage, strict V1 Fox source-selected matched-luminance adjacent RMS
improved 0.0114485 to 0.0106200 EV (about 7.2%). LEGO remained effectively
unchanged: 0.0359507 to 0.0359532 EV. Its main 187→188 zero-based frame
transition stayed about 0.12777 EV. These measures have source-correspondence
limitations and are not proof of imperceptible flicker.

V3's wider identity fallback did not add accepted source-lighting coverage on
the moving controls. V5 added a gain-only absence fallback, but it activated on
none of the 18 controls and none of the LEGO main-scene tracks. V5 controls
exactly match the corresponding V1 validation mode. V5 Fox used same-event
validation, unlike the strict V1 real export; its 0.0103699 EV score must not
be attributed to the absence fallback or compared as a fallback-only gain.
The V5 full native suite passed 178 tests.

V6 all-edge diagnostics identify why the whole-scene estimator abstains.
Unsupported evidence on even one edge currently invalidates the whole scene.
LEGO's main 13-frame scene has only 3 supported edges out of 12, with eight
quorum failures and one opposite-sign failure. The longest actual supported
run is three edges (four frames). Adding hypothetical source-qualified short
pairs raises support to six edges and the longest run to four edges, but these
pairs remain diagnostic donors, not enabled correction evidence. Duplicate
footprints cannot inflate the independent count. Geometry thresholds were not
lowered.

V7 implements opt-in `FRANKLUMA_COMMON_SUPPORTED_RUNS=1`: a query must fit
wholly inside a supported contiguous run; integration and smoothing restart
at each run's own origin. Unknown edges are never filled or bridged. Tests
compare recovered runs with separately analysed clips, verify that a long
query crossing a missing transition is rejected, preserve already-correct
gain, and prevent excitation in one run from changing a quiet other run.
All 183 native tests pass (release, 29.024 seconds).

V7 same-event encoded testing again covers all 18 controls. It makes small
improvements to camera motion, rotation, zoom and parallax relative to V1
same-event, but intentional-ramp FG residual worsens 0.0084851 to 0.0086499 EV.
Five clean-motion controls remain identical. LEGO V7 with baseline-matched
confidence settings is exactly unchanged on all 161 independently supported
matched-luminance transitions, including the main flash. Recovering one
calibrated track in another LEGO scene did not meet spatial fitting quorum.
These results prevent promotion of this configuration.

The main LEGO failure now has a structural explanation: production query
tracks require at least five observations, but its actual supported runs are
shorter. Even accepting a four-frame intersection would leave insufficient
observations for reciprocal temporal fitting of response plus drift. A
one-off-event path needs held-out evidence across independent spatial/material
surfaces within the event, rather than merely disabling the separate-event
requirement. This path still needs a design, clean-motion controls, encoded
slider sweeps and real-video verification. The user-visible default correction
algorithm has not been replaced by these experiments.


V7 real Fox has 597 supported transitions and 0.0101280 EV adjacent RMS,
about 11.5% below the existing 0.0114485 EV baseline and 2.3% below the prior
same-event V5 configuration. V7 exported-video timing, geometry and audio
integrity checks pass for both real clips. Still-preview contact sheets were
inspected, but are not temporal playback proof. Half-Strength local-moving
partial-target BG RMS improves 0.0039134→0.0026016 EV and FG
0.0180772→0.0178112 EV; half-Spatial also has an encoded control export.
Immutable complete review:
`dist/Benchmarks/general-review-v30/common-illumination-native-v7-runs-review.json`.
The first V7 exploratory real exports omitted confidence-target selection;
only the separately labelled `runs-confidence-real` outputs are used for
baseline-matched real metrics and integrity reports above.


### Next experiment: spatially validated single-event evidence

A proposed bracket diagnostic freezes source-only geometry over A→B→C,
retains fixed material identity, and independently checks A↔C endpoint/cycle
agreement. At actual timestamps, alpha=(tB−tA)/(tC−tA). On the same transported
interior pixels measure per-channel r=logRGB(B)−[(1−alpha)logRGB(A)+alpha logRGB(C)].
Fit a constant per channel on contiguous training blocks and validate on disjoint
held blocks, then reverse folds. The full footprint is one material donor;
25 pixels do not constitute 25 independent surfaces. Overlapping correspondence
or identity supports belong to the same evidence group. Use an independent
source donor bank as the event clock, excluding the query's entire support at
all three times. Start with twelve independent footprint groups and record
quorum, cycle, saturation, nonuniform-response and held-residual abstentions.
Thresholds require control calibration, not tuning specifically to LEGO.

This residual is not automatically an exposure target: deformation, changing
normals, occlusion and intentional illumination can create bracket excursions.
Only a spatially replicated, geometry-certified illumination component is
eligible; private appearance residual remains untouched. Uniform normal-induced
shading can still be indistinguishable from exposure from three frames, so the
control suite must include it and a confidence rejection remains necessary.
Do not silently accept unsupported foreground because background proves an event.

If subsequent encoded evidence supports correction, let a be the validated
SOURCE illumination excursion, b the validated shared AUTOMATIC rendered-gain
excursion, and c the actual global-only gain excursion. Holding endpoints
fixed, the proposed middle-frame added EV is
`delta=(1−Spatial)*c−Spatial*Strength*a−b`.
Source absence permits a=0; unknown or nonuniform response abstains. b must be
a known or spatially replicated automatic component rather than arbitrary
per-track gain curvature. Endpoint overlap and scene-brightness neutrality
need a joint solve before applying multiple events. This is a design target,
not an implemented or validated correction path.


### V8 source-pulse diagnostic and measured noise floor

Implemented a read-only three-frame source audit in TrackedSurfaceResidual,
with portable `CommonIlluminationComponent.pulsePixels` tests. It uses actual
timestamp interpolation, frozen three-observation identities, reciprocal A↔C
closure, per-channel constant log-gain prediction across reciprocal contiguous
spatial blocks, and a whole-interior consistency check. It rejects nonfinite,
near-black or clipped channels. Luminance excursion is calculated from RGB
energy, not mean channel EV. Event donors exclude the complete query footprint
at all three times, conservatively grouping 13×13 correspondence supports.
The pixels inside one footprint never count as independent donors.

All 186 native tests pass (release, 29.405 seconds). New tests cover VFR-linear
ramps, channel-specific pulses, spatial shape changes, a changing centre pixel,
dark/clipped channels and invalid times. The diagnostic does not read rendered
gains or modify correction fields. Compared with V7, LEGO global stops and
fields are exactly identical; Fox stops are identical and only two field Float
values differ, by at most approximately 1e-9 EV.

With provisional .02 EV held-error tolerance and twelve independent groups,
V8 produces zero qualified event queries on LEGO, Fox, global-static,
local-moving, clean-motion, intentional-ramp and nonlinear-fade inputs.
The known positive global-static control itself reaches only ten independent
donors. Thus zero detections cannot be treated as absence of flicker.
LEGO's main scene has zero pixel-qualified footprints at its logged brackets:
clipped/dark channels and spatially nonuniform responses dominate. At zero-based
frame187 it has only two three-observation candidates, both rejected. This
suggests a geometry/photometry coverage problem beyond a temporal-fit limit.

An independent fixed-geometry audit of all 6,860 generated global-static
source patches finds median reciprocal held RMS .020548 EV and 95th percentile
.057290 EV, despite known fixed camera/material geometry. The .02 gate accepts
only 47.8% using held RMS alone; .04 accepts 86.5%, .08 accepts 99.2%.
This includes encoding, colour conversion and resampling effects, not a sensor
noise measurement. The production matcher introduces further uncertainty.
The audit is reproducible with `scripts/validation/audit_pulse_noise.py` and
its source/manifest/generator hashes are recorded. A two-horizontal-fold
preliminary calculation gave .018174 EV median; the authoritative four-fold
result above supersedes that preliminary figure.

Immutable reports: `common-source-pulse-v8-review.json` and
`common-source-pulse-v8-oracle-noise.json` under
`dist/Benchmarks/general-review-v30`. A first nonlinear-fade command used the
wrong root and failed before processing; the completed diagnostic uses
`dist/Benchmarks/adversarial-v30/cases/no-flicker-nonlinear-fade/input.mov`.
V9 adds explicit diagnostic-only tolerance/donor parameters so their effects
can be separated on known positive and negative controls. No pulse correction
is enabled and no production matcher threshold has been weakened.


### V9/V10 spatial evidence calibration

V9 independently varied held tolerance (.02/.04) and nonoverlapping group
quorum (12/4). Lowering tolerance alone leaves the known global-static event
clock empty; changing quorum alone restores 1,530 query events, and combined
settings restore 3,540. Local-moving supplies seven supported-absence
candidates with combined settings. The isolated-flash control has candidates
at frames116,117,118 around its one injected flash117. These are the expected
second-difference signature of one flash, not three independent flashes.
No events occur in five clean-motion controls, nonlinear fade or noisy motion.
The same calibration yields events only in LEGO's first scene, not its main
problem scene. Immutable V9 calibration report:
`common-source-pulse-v9-calibration-review.json`.

V10 adds neutral-exposure validation based on linear RGB luminance. A dark
individual channel no longer invalidates a sufficiently bright neutral
luminance measurement; clipped/nonfinite RGB and dark luminance still reject.
This path cannot authorize RGB channel correction. Tests cover a strongly
coloured patch with dark individual channels and constant-luminance colour
variation; RGB validation rejects the latter shape change while neutral EV
correctly reports zero. All 188 native tests pass (release, 30.340 seconds).

With calibrated .04/4 diagnostic settings, V10 has 4,311 source response
query events in global-static, 159 around the injected isolated flash,
312 in local-moving (including thirteen absence candidates), and 19,466 in
Fox (one absence candidate). All five clean-motion controls, nonlinear fade
and noisy motion again produce zero events. LEGO has 214 candidate event
queries in other parts of the clip, but its main brackets at localframes6–8
have zero, zero and one qualified patch respectively, insufficient for an
independent donor clock. Its raw three-frame bank has only one, two and four
trajectories at those brackets. Luminance validation therefore fixes an
unnecessary channel gate without solving the underlying material coverage.
No event correction or new encoded quality improvement is implied by these
source-only counts. Immutable report:
`common-source-pulse-v10-luminance-review.json`.

The next geometry experiment measures rolling three-frame detail at two
source resolutions, without retaining larger thumbnails for a whole video.
This tests whether the existing 96×56 patches mix too many materials/edges
inside the LEGO figures. It uses the same source identity, reciprocal matches,
clipping gates and physical-time pulse model, not video-specific thresholds.
A finer diagnostic is not a production memory/performance decision.


The source-noise audit now also validates the global-static folder and records
its encoded source hash; the identical measured results with this extra
provenance are in `common-source-pulse-v8-oracle-noise-provenance-v2.json`.
The standalone detail harness will reproduce production's 192×112 Lanczos
resize plus 2×2 reduction for its96×56 branch, rather than directly resizing
to96×56. The192 branch uses that same detail without reduction, keeping the
resampling comparison explicit. Two-step endpoint search radius scales with
resolution so source-detail differences are not a search-range confound.


### V11 bounded source-detail comparison

Implemented `scripts/validation/SourcePulseDetailAudit.swift` and compiled
an immutable native runner. It indexes exact compressed presentation timestamps,
then decodes only a supplied known single-scene range, retaining three RGB
thumbnails. It seeds each middle frame independently, matches backward/forward,
checks fixed source identity and two-step endpoint closure, and invokes the
source-only neutral pulse test. This avoids the completed-track ≥5-frame gate.
Its app processing/export pipeline is not invoked. Source controls and both
resolution jobs completed successfully.

For LEGO's scene15–16.083333333333332 seconds, both resolutions decode thirteen
frames and inspect eleven brackets. At sourceframe187,96×56 yields two source
triples and192×112 yields five; neither has a pixel-qualified pulse surface.
Frame186 yields one versus six triples, again zero qualified; frame188 yields
four versus six triples and one versus zero qualified patches. Both resolutions
therefore remain unsupported at the main flash. Across the whole short range,
96 has33 query events and192 has39, at other brackets. Before-frame reciprocal
match failures dominate the geometry rejection counts (487/546), with weak
confidence next (242/219). Higher detail has not resolved the main case.

The injected single-flash positive control115–120 verifies the harness: both
resolutions detect its expected bracket signature at116,117,118 and no event
at119. Query counts are56/51/55/0 at96 and27/26/27/0 at192. More pixels or
more trajectories must not be treated as better lighting evidence by themselves.
Grid phase is approximate, while physical seed spacing/search range is scaled;
finer resolution also shrinks the measured patch. This is a diagnostic comparison,
not a proposed blanket increase in mobile or desktop analysis memory.

Immutable source/harness/binary provenance and logs are under
`.build/review-v33/common-illumination-native-v11-detail`; immutable complete
report is `common-source-pulse-v11-detail-review.json` under the general-review
folder. The next hypothesis to test is contrast/tone-aware photometric matching
and held prediction, which could explain some constant-gain rejections. Current
results do not yet prove that tone changes, rather than material/geometry
ambiguity or noise, cause the LEGO mismatch. Single-event correction still
requires a joint temporal solve; treating the derivative signature as separate
flashes would introduce new adjacent-frame artifacts.

## V12 geometry versus photometry ablation (9 October 2026)

Frozen source-only detail runner: `.build/review-v33/common-illumination-native-v12-geometry/runner/detail-audit`; file hashes in its `build-provenance.json`. Four completed native audits used the supplied LEGO scene [15, 16.083333333333332), 96 by 56 source thumbnails, neutral-luminance pulse tolerance 0.04 and four independent donor footprints. No correction or export was performed. Results are recorded in `geometry-review.json` beside the logs.

At source frame 187, narrow matching with the usual photometric confidence produced two reciprocal three-frame candidates and zero held-pixel-qualified candidates. Removing only the photometric confidence factor, retaining geometric confidence, reciprocal matching and source identity checks, increased candidates to ten but still qualified zero: nine failed nonuniform held response and one failed clipping/validity. At frames 186 and 188 the corresponding qualified counts were 0/1 normally and 2/1 with geometry-only confidence; none obtained a supported event query. Wider half-six matching produced zero triples at frames 186 and 187, and one at 188, in both confidence variants.

This ablation does not prove that tone variation is the cause, but rules out these matching adjustments as sufficient fixes for the main bracket. Neither confidence removal nor larger patches is promoted. The next bounded test is an independently held-out affine log-luminance response model, followed by clean-motion and intentional-lighting controls. A tone slope/intercept is diagnostic evidence, not permission to apply a scalar EV or geometric warp.

## Joint pulse reconstruction foundation (9 October 2026)

`PulseReconstruction.swift` adds a source-only temporal inverse for corroborated three-frame excursions. It uses actual presentation-time interpolation coefficients, solves weighted curvature equations jointly with conjugate gradients, and constrains the unobservable constant and physical-time linear components to zero. Optional amplitude regularization bounds the inverse; unknown or zero-weight rows split evidence into independent runs rather than becoming assumed quiet observations. Shared boundary levels remain unknown. This utility is not connected to production correction.

Native `swift test --filter PulseReconstructionTests` completed successfully: four tests, zero failures, including recovery of one isolated flash from its negative/positive/negative three-bracket pattern, variable-frame timing and the linear nullspace, unsupported gaps, and invalid timing. Log: `/tmp/frankluma-pulse-reconstruction-tests.log`. These tests establish the inverse math only; they do not establish that source event classification is sufficiently reliable or that exported LEGO/Fox videos improve. Independent run gauges cannot establish relative exposure across an unsupported gap.

## Held-out contrast response diagnostic implementation (9 October 2026)

`CommonIlluminationComponent.pulseToneLuminancePixels` now fits a robust affine log-luminance mapping from the timestamp-interpolated source endpoints to the middle frame. Four reciprocal contiguous spatial tests require at least 0.2 EV training range, bounded positive slope [0.5,2], held samples within the training range (0.03 EV numerical margin), accurate held predictions and consistent predictions across independently trained blocks. A full 25-pixel interior check includes the omitted center row/column. The result exposes slope/intercept and per-pixel excursions; the representative gain is diagnostic and cannot authorize a scalar correction.

With `FRANKLUMA_COMMON_PULSE_TONE_DIAGNOSTICS=1`, rejected constant-response patches receive a separate `COMMON_LIGHT_SOURCE_TONE` record after the existing geometry gates. These records do not enter the donor clock or change any correction field. Native focused validation completed: 27 CommonIllumination/PulseReconstruction tests, zero failures. New tone tests cover a true contrast response, a changed center, VFR linear exposure and insufficient texture. Log: `/tmp/frankluma-tone-pulse-tests.log`. The isolated V13 native detail runner snapshot has been prepared for real/control testing; source-video effectiveness is still unproven.

V13 LEGO source audit completed successfully at 96 by 56 with narrow geometry-only confidence, the unchanged reciprocal/identity gates, and tone diagnostics. All 99 constant-rejected geometry candidates failed tone qualification: 63 extrapolation, 21 invalid/clipped RGB, eight insufficient range and seven held response failures. At frame 187: six extrapolation, two insufficient range, one clipped/invalid and one held failure; zero qualified. This does not establish absence of tone variation, because most tests lack overlapping training/held luminance support. It establishes that this small-patch contrast model cannot yet support correction on the main bracket. Logs and summary: `.build/review-v33/common-illumination-native-v13-tone/lego96-tone.log` and `lego96-tone-review.json`. No output improvement is attributed to V13.

## V14 broader photometric support ablation (9 October 2026)

The diagnostic tone validator now supports odd source footprints from 5 to 13 pixels across, while retaining the same contiguous reciprocal folds, clipping checks, monotone slope bounds, held support and interior test. Geometry matching remains narrow and unchanged; only the measured lighting footprint grows. `FRANKLUMA_COMMON_PULSE_TONE_HALF` selects diagnostic half-width 2...6, and out-of-image footprints are explicitly rejected. This does not modify correction, donor counts or production defaults. The 24 CommonIllumination tests pass, including a 13-by-13 true tone response and rejection of a different response in one half of that footprint.

Three immutable native LEGO audits completed: 9-by-9 photometry at 96-by-56 analysis, 13-by-13 at 96-by-56, and 13-by-13 at 192-by-112. All produced zero qualified tone patches, including frames 186/187/188. Overall rejection counts: 9-by-9/96 had 53 extrapolation, 40 clipped/invalid, three held-response, one insufficient range and two dark-luminance failures; 13-by-13/96 had 40 extrapolation, 56 clipped/invalid and three held-response failures; 13-by-13/192 had 42 extrapolation and 54 clipped/invalid failures. Wider photometry alone therefore cannot supply the missing main-event evidence and increases invalid/clipped coverage. It is not promoted. Artifacts and provenance: `.build/review-v33/common-illumination-native-v14-wide-tone/`, summary `lego-wide-tone-review.json`; focused tests `/tmp/frankluma-wide-tone-tests.log`.

The next investigation should examine source-area selection and common photometric support rather than repeat larger-patch sweeps. Requiring every held pixel to lie inside each disjoint training block's luminance interval can reject a genuine tone curve on a spatial gradient; any overlap-restricted diagnostic must still establish adequate held texture, reciprocal predictive consistency and interior coverage before it can authorize correction. No V14 encoded output improvement is claimed.

## V15 overlapping brightness support (9 October 2026)

An opt-in tone diagnostic (`FRANKLUMA_COMMON_PULSE_TONE_OVERLAP=1`) tests held pixels inside each training block's brightness range instead of requiring every held extreme to overlap. Each reciprocal fold still requires at least half its held pixels (minimum four), 0.15 EV held range, and 0.2 EV training range. At least 75% of off-center pixels must receive an in-range held prediction across the folds. Prediction consistency is still checked across the entire footprint, and all interior pixels must fit the final response. The strict mode remains the default. Twenty-five focused CommonIllumination tests pass, including recovery of a genuine tone mapping with one unsupported extreme and rejection of different mappings in separate regions.

Both native LEGO audits completed. Five-by-five photometry qualified two patches across the scene, nine-by-nine qualified one; each qualified one at frame 188 and none at frame 187. At frame 187, five-by-five produced four insufficient-held-support, two insufficient-range, one invalid/clipped and three actual held-response failures; nine-by-nine produced six held-response, one insufficient-held-support, one insufficient-range and two invalid/clipped failures. This establishes that brightness-overlap requirements explained some rejection, but removing unsupported extremes does not solve the main flash. Qualified patch responses do not enter the clock or correction pipeline.

Two complete clean-control source audits also finished: clean motion (72 frames, 70 brackets) and intentional nonlinear fade (300 frames, 298 brackets). Both produced zero tone-qualified patches and zero constant-response event queries under this diagnostic configuration. This is limited negative-control evidence, not proof of general safety or corrected video quality. Frozen V15 artifacts and hashes: `.build/review-v33/common-illumination-native-v15-tone-overlap/`; summaries `lego-tone-overlap-review.json`, `clean-controls-review.json`; focused test log `/tmp/frankluma-tone-overlap-tests.log`.

The independently matched-surface quality audit uses camera-guided 13-by-13 footprints and a texture-correlation check rather than local reciprocal search. That differing correspondence selection may explain why it obtains source evidence where the current small-patch event tracker cannot. A camera-guided diagnostic must require an actually validated camera model (the quality audit's identity fallback cannot authorize correction), then verify local source identities and three-frame consistency. This is a specific next coverage investigation, not permission to use arbitrary same-position patches.

## V16 camera-guided source coverage (9 October 2026)

The standalone detail harness now has opt-in `FRANKLUMA_DETAIL_CAMERA_GUIDED=1`. It uses the existing fitted camera models when available. A missing model is not treated as proof of identity: stationary geometry requires at least 12 textured 13-by-13 anchors, at least 60% of eligible anchors agreeing, and source coverage across half the image width and height. Each candidate also requires normalized source texture correlation above 0.95 at camera-predicted integer positions in both neighboring frames. The core diagnostic rechecks A/C endpoint texture correlation instead of repeating local reciprocal search. Source radiances remain unchanged; no image warp or correction path is introduced.

The first V16 snapshot failed compilation because its harness directly accessed fileprivate descriptors. The corrected V16b snapshot keeps that access boundary and exposes only an optional geometry correlation measurement; missing/flat evidence is nil. Native SurfaceTracking validation completed: 45 tests, zero failures, including correct camera-predicted pan under an exposure change, wrong-position rejection and flat-evidence rejection. Log: `/tmp/frankluma-camera-guided-tests.log`.

Completed LEGO scene and full clean-motion audits are frozen in `.build/review-v33/common-illumination-native-v16b-camera-guided/`, with hashes and `camera-guided-review.json`. Stationary geometry is established in eight of 11 LEGO brackets. Frames 186/187/188 have 62/63/64 camera-guided candidates and 13/10/11 constant-response-qualified patches, versus 11/10/12 candidates and 2/0/1 qualified under V12 narrow geometry-only local matching. This confirms that correspondence selection was losing usable source photometry. However, the conservative disjoint 13-pixel donor bank still has only four/three/three maximum independent donors. Frame 186 supports seven response queries (median donor excursion -0.49364 EV), while 187 and 188 do not meet the configured minimum four donors and support zero event queries. Whole-scene event queries total 120; this is evidence coverage, not exported quality.

The complete 72-frame clean-motion control establishes camera geometry on all 70 brackets and produces zero event queries. Further camera motion, repeated-texture, occlusion and intentional-lighting controls remain necessary. The next bounded coverage test should increase seed density while preserving disjoint footprint requirements; a finer grid can test whether poor seed placement limits donor count without treating overlapping patches as independent. V16b remains diagnostic and is not promoted.

## V17 denser camera-guided seeds (9 October 2026)

The standalone harness adds bounded `FRANKLUMA_DETAIL_SEED_STRIDE` (3...12 pixels at 96-pixel width; physical stride scales with analysis resolution). Default six is unchanged. An immutable V17 runner tested stride three with camera guidance, 0.04 EV luminance tolerance and four independent donors. The 13-by-13 disjoint donor rule, leave-query-out selection, photometric held tests and spatial sign corroboration are unchanged. This change is diagnostic only.

All four native jobs completed. The LEGO scene establishes geometry in eight of 11 brackets, with 507 supported event queries across frames 185,186,187,189,190,191. Frames 186/187/188 have 246/251/254 geometry candidates and 39/33/47 qualified photometric patches, with maximum independent donor counts five/four/five. Crucially, frame 187 now supports 27 response queries and median source donor excursion +0.35810 EV; frame 186 supports 39 responses with median -0.49109 EV. Frame 188 remains unsupported by the spatial sign test despite having five independent donors, so it cannot be silently treated as zero. This resolves a sampling-coverage failure for the main event, not the complete temporal correction problem.

Full clean-motion and nonlinear-fade controls produce zero event queries on 70 and 298 brackets respectively. The known camera-motion positive establishes geometry on only six of 70 brackets and produces 1,351 event queries on those six; this exposes limited moving-camera coverage and does not establish broad camera robustness. Frozen source/binary hashes, logs and summary: `.build/review-v33/common-illumination-native-v17-dense-camera/`, `dense-camera-review.json`. No correction export or rendered quality gain is claimed.

Next implementation must distinguish genuinely corroborated quiet source brackets from unknown brackets and feed supported runs into the joint physical-time reconstruction. The conflicting bracket at 188 must remain an evidence gap. Then source and existing automatic rendered gains must be calibrated jointly, with Strength and Spatial correction scaling tested against independent partial targets before production promotion.

## V18 explicit quiet clocks and source reconstruction (9 October 2026)

`CommonIlluminationComponent.pulseClock` now returns quiet/event/unknown evidence from already independent, source-selected, spatially ordered, leave-query-out donors. Quiet requires every donor's absolute excursion plus twice its held error to be at most 0.01 EV; weak, missing, opposing or merely below-event-threshold evidence remains unknown with no numeric excursion. Event sign/uncertainty thresholds match the earlier diagnostic. Quiet measurements retain their measured small curvature rather than being forced to zero. Thirty focused CommonIllumination/PulseReconstruction tests pass, including weak/conflicting/error-bounded quiet evidence and unknown-gap reconstruction.

All three native source audits completed in `.build/review-v33/common-illumination-native-v18-quiet-clock/`, with `quiet-clock-review.json`. LEGO has event support at 185/186/187 and 189/190/191, no corroborated quiet brackets, and unknown brackets 181..184 and 188. The complete 72-frame clean-motion control supplies quiet evidence on all 70 interior brackets and no events. The isolated-flash range [4.6,4.84) supplies three event brackets 116/117/118 followed by quiet bracket 119, with no unknown interior bracket. Queries are correlated measurements of shared donor banks, not additional independent donors.

`PulseClockReconstructionAudit.swift` runs the existing physical-time joint inverse on diagnostic medians of supported donor clocks; mixed event/quiet query banks and unknown rows remain unsupported. This aggregation is diagnostic and is not calibrated as a production global exposure target. Inputs, outputs and source/binary hashes are retained beside the source audits, with `reconstruction-review.json` and `runner/reconstruction-provenance.json`. LEGO reconstruction keeps two separate gauges and leaves the shared boundary frame 188 unknown; its maximum fitted curvature residual is 0.000424 EV. Clean-motion reconstruction covers 72 frames with maximum residual 3.67e-9 EV. The isolated pulse's reconstructed contrast to its adjacent frames is 0.80195 EV, maximum residual 0.001092 EV.

The benchmark generator explicitly injects +0.9 EV at frame 117 (`BenchmarkAudit.swift`), so 0.80195 EV is an approximately 10.9% amplitude underestimate against the generator setting. Codec/color transformation, sampling, donor selection and inverse regularization require separation against the independently encoded clean target before any quality claim. These results establish a usable supported temporal signal, not a verified correction. Existing automatic rendered gain must be measured and calibrated, and per-surface source response must not be replaced by this uncalibrated global clock. No correction output was changed or exported in V18.

## V19 independent clean-target amplitude calibration (9 October 2026)

The V18 nominal 10.9% amplitude-underestimate interpretation is superseded by independently encoded clean-reference evidence. A new frozen production ThumbnailDump runner decoded all 300 frames of both isolated-flash input and target. `audit_source_pulse_target.py` compares same-frame luminance and source-selected stationary 5-by-5 event footprints; it excludes dark/clipped samples and hashes its inputs and script. Native snapshots, binary hashes and JSON are in `.build/review-v33/common-illumination-native-v19-target-calibration/`, report `isolated-target-review.json`.

At flash frame 117, all 5,364 valid thumbnail pixels have median actual source/clean-target gain 0.80310 EV. The 266 source-selected valid query footprints have median actual gain 0.80401 EV, median source curvature 0.80399 EV and median donor-clock excursion 0.80304 EV. Clean-target curvature in those same footprints has median zero and RMS 0.0001007 EV. V18 reconstructed adjacent-frame flash contrast 0.80195 EV is about 0.00207 EV (0.26%) below the selected clean-target measurement, not 11% below the actual decoded reference. The source measurement, rather than reconstruction, already observes roughly 0.803 EV after the generator's encode/decode/color pipeline despite its nominal +0.9 EV injection. The exact color/codec contribution is not isolated by this audit.

Do not multiply correction strength by 0.9/0.802 to compensate: that would overcorrect this actual encoded reference. The next validation must measure actual rendered automatic gain and compare composed output with the decoded clean target. This audit uses the known stationary, constant-rate controlled case and does not establish general VFR, geometry, source-clock aggregation or rendered-correction validity. No new correction export was produced.

## V20 actual rendered-gain composition evidence (9 October 2026)

A native confidence-target baseline isolated-flash export completed with all 300 frames and 12-second duration verified (`dist/Benchmarks/review-v33-pulse-composition-v20/isolated-baseline/`). It uses the frozen V10 real-audit runner with `FRANKLUMA_CONFIDENCE_TARGETS=1`, no source-component or pulse correction flags, and full settings/field diagnostics. The frozen V19 sampler decoded that actual export. The clean-target audit now optionally measures encoded automatic gain and residual curvature on source-selected patches, requiring corroborated stationary camera geometry and equal bracket timing. All 266 selected flash patches have median automatic gain curvature -0.80187 EV against source curvature +0.80399 EV; corrected/clean-target residual curvature median is +0.001798 EV, RMS 0.003131 EV. Same-frame corrected/target offset is -0.02116 EV, which is a separate brightness-calibration issue. Adding the full source estimate again would create a severe opposite pulse.

`audit_rendered_pulse_gain.py` independently measures source and actual encoded automatic gain on the 27 newly corroborated LEGO frame-187 query patches. This stationary-camera audit uses actual bracket timestamps and refuses unvalidated/moving camera evidence. It reads the retained confidence-target-v8 LEGO baseline export rather than inventing a clean LEGO reference. Median source curvature is +0.35518 EV; median automatic gain curvature is -0.35187 EV. Output curvature median is +0.001804 EV, but RMS remains 0.02706 EV and the individual range is -0.03355 to +0.05356 EV. Diagnostic additional curvature for full removal varies from -0.05319 to +0.03317 EV, median -0.003861 EV. Therefore the camera-guided source-valid subset is largely corrected already, with spatially mixed residuals. It does not explain or prove removal of the previously measured 187→188 whole-footprint step; the source-invalid areas remain unmeasured by this classifier. A blanket EV adjustment is unsupported.

Immutable decoded evidence and reviewed-invariant reports reside in `.build/review-v33/common-illumination-native-v19-target-calibration/`: `isolated-composed-gain-v20-reviewed-invariants.json`, `lego-composed-gain-v20-reviewed-invariants.json`. Each records hashes of the selected source/encoded-output data, source-evidence log and audit code. Baseline export log: `/tmp/frankluma-v20-isolated-baseline.log`. The next source model should test smooth spatial illumination variation within source-valid geometry, then calibrate a local residual field against actual automatic gain. This is evidence for composition and locality, not a new algorithm export or general video-quality improvement.

## V21 independently held spatial illumination plane (9 October 2026)

`pulsePlaneLuminancePixels` adds a diagnostic robust three-parameter plane for source log-luminance excursion: a constant plus normalized horizontal/vertical gradients. It fits reciprocal contiguous blocks, bounds gradient amplitude, requires independently held RMS error <=0.04 EV, checks predictive disagreement throughout the footprint, and checks every interior pixel (RMS <=0.04 EV, maximum error <=0.08 EV). Geometry and independent external donor support remain separate requirements. No source sample or image geometry is changed. With `FRANKLUMA_COMMON_PULSE_PLANE_DIAGNOSTICS=1`, rejected constant-response patches receive a separate diagnostic record, never a donor-clock or correction entry. Twenty-eight focused tests pass, including a genuine spatial gradient, changed-center rejection, irregular deformation rejection and VFR linear illumination.

Three complete native camera-guided, stride-three source audits are frozen in `.build/review-v33/common-illumination-native-v21-source-plane/`, with hashes and `source-plane-review.json`. LEGO has 1,562 tested constant-rejected patches and only one plane-qualified patch across the scene, none at main frames 186/187/188. Overall: 907 held-plane failures, 530 clipped/invalid, 67 invalid gradients, 50 dark and seven inconsistent predictions. At frame 187: 135 held-plane failures, 54 invalid/clipped, 25 invalid gradients, one inconsistent prediction and one dark patch. Thus a bounded smooth illumination plane is not sufficient to recover the missing main-event evidence.

Complete clean-motion and nonlinear-fade controls qualify zero plane patches and retain zero constant event queries. The plane path does not modify correction outputs. Its inability to predict most source pixel changes suggests revisiting measurement correspondence: camera-guided 13-by-13 texture agreement permits small local movement or subpixel misregistration that can violate 5-by-5 pixel-level photometry. This is a hypothesis, not a proof that every rejection is geometric. The next bounded ablation should refine source sampling coordinates and compare held prediction errors, without warping rendered images, loosening lighting thresholds or promoting the failed plane model. No V21 exported quality improvement is claimed.

## V22 measurement-only fractional refinement (9 October 2026)

The opt-in source diagnostic `FRANKLUMA_COMMON_PULSE_REFINE_SAMPLING=1` refines camera-predicted measurement positions on the wide 13-by-13 normalized geometry footprint. It searches within one pixel in quarter-pixel steps, requires texture correlation >0.95, an improvement of at least 0.01 before moving the camera coordinate, and reciprocal return within half a pixel. Bilinear sampling changes only source measurement coordinates; rendering is untouched. Independent donor exclusion expands to 15 pixels to include the searched footprint. A native known fractional-motion/exposure test passes, with flat-evidence rejection.

V22b is the authoritative native snapshot (V22 was built before donor exclusion was expanded and was not used for this comparison). Complete LEGO and clean-motion runs are in `.build/review-v33/common-illumination-native-v22b-refined-sampling/`, with hashes and `refined-sampling-review.json`. LEGO retains 507 event queries on the same frames as V18. At 186/187/188 the qualified counts remain 39/33/47, independent donor counts five/four/five and event queries 39/27/zero. Across all 507 shared corroborated query positions, only one measured excursion changes beyond 1e-12 EV; its difference is 0.0002552 EV. Clean motion remains event-free and all 70 brackets retain quiet evidence. This conservative refinement does not solve the missing photometry.

Current worktree additionally closes a weak-initial-correlation edge case and makes combined tone/refinement diagnostics sample the same fractional coordinates. Integer-coordinate calibration scripts now explicitly refuse refined sampling logs rather than silently measure different pixels. The native V22b tests do not include those later small edits. Before interpreting refinement as disproven, record proposed geometric improvements and actual accepted offsets: its 0.01 correlation-improvement gate may leave most candidates at camera coordinates. Any subsequent ablation must retain held photometric thresholds and reciprocal geometry, document searched-footprint independence, and verify clean/intentional-motion controls. No new correction or output-quality improvement is claimed.

## V23 refinement proposals and RGB coverage (9 October 2026)

The geometry refinement diagnostic now reports proposed texture-correlation improvement and accepted movement separately for forward/reverse searches. Its bounded optional minimum-improvement parameter defaults to 0.01; trace/correlation thresholds do not change photometric acceptance. Native tracking regression validation passes all 46 tests. Immutable V23 sources/binary hashes, logs and `refinement-trace-review.json` are in `.build/review-v33/common-illumination-native-v23-refinement-trace/`.

Complete LEGO runs show 4,844 forward proposals, median improvement zero and maximum 0.01460. Default 0.01 accepts two forward movements; a diagnostic 0.001 gate accepts 45. Both retain 507 event queries. At frame 187 the finer gate loses one photometric candidate (32 versus 33, due to reciprocal refinement rejection), and event queries remain 27. The main 186/187/188 qualified counts otherwise remain unchanged. Complete finer-gate clean-motion testing accepts 427 of 39,246 forward proposals, produces zero events but retains quiet evidence on only 69 of 70 brackets. Finer acceptance is therefore not promoted; geometry search mostly prefers camera coordinates and the added motion does not recover the missing lighting evidence. Forward acceptance counts are proposals, not final independently corroborated illumination donors.

A separate complete RGB-channel camera-guided/stride-three audit used the existing strict RGB response test with no refinement. It produced zero supported event queries. At frames 186/187/188, qualified counts are zero/zero/three. Frame 187 rejects 186 patches for clipping/dark channels and 63 for actual held response, plus two endpoint-identity failures. This does not disprove channel-specific lighting: the strict all-pixel/all-channel >0.005 requirement rejects most strongly colored candidates before testing their informative channels. Any next RGB model must retain source geometry and independent donor gates, use independently held observable channel samples, and bound the luminance contribution of unresolved dark channels rather than assign them an invented gain. The already-held luminance and spatial/tone experiments remain evidence against a simple blanket neutral correction. No V23 correction was exported or promoted.

## V24 observable spectral response (9 October 2026)

`pulseObservableRGB` adds source-only partial spectral evidence. Each channel is fitted only if all four contiguous reciprocal blocks contain at least four exposed source samples. Gain estimates must independently predict held channel excursions. Unresolved channels remain nil and are never assigned zero or copied gains; resolved channels must account for at least 98% of measured luminance at every pixel in all three source frames. Full interior resolved-luminance predictions have RMS <=0.04 EV and maximum error <=0.08 EV. Coverage describes measured radiance and does not bound hidden illumination or authorize full RGB correction. Thirty focused tests pass, including genuine color-dependent response with a dark unresolved channel, changed-center rejection, significant unresolved energy rejection and an intended VFR ramp.

The diagnostic flag `FRANKLUMA_COMMON_PULSE_OBSERVABLE_RGB_DIAGNOSTICS=1` records constant-rejected camera-valid patches separately; it never enters donor clocks or fields. Complete native LEGO, clean-motion and color-flicker control audits are frozen in `.build/review-v33/common-illumination-native-v24-observable-rgb/`, with hashes and `observable-rgb-review.json`. The color-flicker positive adds 14 spectral-qualified patches; clean motion adds zero and retains zero events. LEGO adds zero: of 1,562 rejected neutral patches, 530 are invalid/clipped, 1,031 fail a held observable-channel prediction and one lacks measured-luminance coverage. Frames 186/187/188 add zero, with 160/162/151 actual channel-prediction failures and 38/54/56 clipped/invalid failures. The original 507 neutral event queries remain unchanged.

Thus dark-channel eligibility alone does not explain the missing LEGO photometry. Held pixels fail multiplicative channel response even when useful channels are sampled. A next bounded source-image-formation test may fit a positive affine response in linear intensity (gain plus additive component), which differs mathematically from the previously tested affine log-luminance curve. It must reject weak training variation and independently predict held RGB/luminance, without assigning unresolved color correction, loosening geometry, or treating a fitted response as proof of unwanted flicker. This is a hypothesis to test, not an implementation recommendation established by V24. No new correction export or quality improvement is claimed.

## V25 positive affine linear-luminance response (9 October 2026)

`pulseLinearLuminancePixels` tests gain plus additive offset in linear luminance, unlike V13's affine log-luminance model. Each reciprocal contiguous training block requires at least 0.01 linear-luminance range, bounded positive gain [0.5,2], offset magnitude <=0.05 and positive/unclipped predictions. Independently held error is measured in EV (RMS <=0.04); cross-model predictive disagreement must remain <=0.04 EV across the footprint; every interior pixel must satisfy the same RMS and maximum-error <=0.08 EV. The timestamp interpolation remains geometric in endpoint luminance, preserving physical-time linear EV ramps. This source response is diagnostic, not permission for correction. Thirty-two focused tests pass, including a true additive component, changed-center rejection, weak-variation rejection and a VFR ramp.

The diagnostic flag `FRANKLUMA_COMMON_PULSE_LINEAR_DIAGNOSTICS=1` records rejected constant-response patches separately. Four complete native source audits are frozen in `.build/review-v33/common-illumination-native-v25-linear-response/`, with hashes and `linear-response-review.json`. LEGO at 96-pixel analysis adds 13 affine-qualified patches across the scene, none at frame 186 or 187 and two at 188; original constant event queries remain 507. Main frame 187 rejects 75 on held response, 79 as unidentifiable/unbounded, seven invalid predictions, 54 invalid/clipped source values and one dark footprint. At 192-pixel analysis the model adds 15 across the scene, but source camera geometry is unsupported at 187/188, so those frames have no candidate photometry. This is not evidence that the lighting model independently fails those finer-scale frames. Constant event queries total 368 at that scale. Geometry footprints remain 13 pixels across, so their physical source support differs between resolutions; a resolution comparison must account for that confound.

Clean motion adds zero affine-qualified patches and no events. The complete nonlinear-fade control adds three affine-qualified patches, with original event count still zero. This directly illustrates why a fitted photometric response alone cannot authorize removal: intended lighting changes can satisfy the model. Qualified affine patches do not enter the donor clock or renderer. Next work must address geometry/support coverage or spatial residual calibration, rather than assume those extra fits solve the main flash or blindly increase model flexibility. No V25 exported-video quality improvement is claimed.

## V26 physical camera-support scaling (9 October 2026)

The detail harness adds opt-in `FRANKLUMA_DETAIL_SCALE_CAMERA_SUPPORT=1`: camera geometry half-width scales from six at 96-pixel analysis to twelve at 192, and identity/endpoint texture checks use the same scaled support. Independent donor exclusion scales conservatively from 13 to 26 pixels. Seed stride and margins already scale with resolution; photometry intentionally remains 5-by-5 to measure finer local source areas. The two image samplers have different pixel apertures and half-detail-pixel phase, so physical support is approximately matched rather than bit-identical. No production analysis resolution changes. Fractional refinement currently supports only half-six geometry; metadata explicitly reports that restriction instead of silently applying a smaller search footprint.

V26b is authoritative: V26 was compiled before the conservative 26-pixel donor spacing and was not used for comparison. All three V26b native audits completed with hashes/logs in `.build/review-v33/common-illumination-native-v26b-scaled-geometry/`, summary `scaled-camera-review.json`. LEGO at 96 retains eight geometry-supported brackets and 507 event queries. At 192 it establishes nine supported brackets and 576 event queries. Main frames 186/187/188 at 192 regain geometry support and have 53/54/62 qualified constant-response patches; event queries are 53/54/zero, versus 39/27/zero at 96. Thus higher-detail camera-guided analysis adds usable source evidence when its geometry context is scaled; the earlier unscaled V25 failure at 187/188 was a confounded comparison. The conflicting bracket at 188 remains unsupported by the independent spatial event test.

The complete 192-detail clean-motion control supports geometry and quiet lighting on all 70 brackets, with zero events. A native doubled-resolution known-motion/exposure test passes, including wrong-position and unsupported-footprint rejection (`/tmp/frankluma-scaled-camera-tests.log`). These are coverage and geometry results, not an output-quality claim. Next validation must decode the existing corrected LEGO export at the same 192 detail sampling and measure actual composed gain on the newly supported source-selected patches. A global correction must not be inferred from this larger query count, nor may these correlated queries count as additional independent donors. No V26 correction export or promotion occurred.

## V27 high-detail actual-gain localization (9 October 2026)

The detail harness can now stream per-frame diagnostic JSON with exact presentation index/time into a new directory (`FRANKLUMA_DETAIL_DUMP_DIRECTORY`), without retaining the complete range. Dump-only mode skips correspondence selection; it requires an output directory and refuses overwrite. The rolling thumbnail count remains at most three, plus transient serialized data and native decoder/GPU memory. This is a diagnostic sampler, not an exporter or app analysis setting.

A frozen V27 runner independently decoded 13 source and 13 existing confidence-target-v8 LEGO baseline frames at the same 192-by-112 sampling, source range [15,16.083333333333332). `audit_rendered_pulse_gain.py` now accepts indexed frame directories, requires matching source/output indices and presentation times, and uses only the V26b original-source-selected 54 query positions. Corrected radiance is allowed to be bright/clipped for measurement: output clipping must not make an overcorrection silently disappear from the audit. Original source validity still comes from its stricter held photometric test. Immutable dumps, native hashes and `lego192-composed-gain-review.json` are in `.build/review-v33/common-illumination-native-v27-detail-gain/`.

Across the 54 newly supported source queries at frame 187, median source curvature is +0.36838 EV, actual automatic gain curvature -0.35089 EV, and output curvature +0.01639 EV (RMS 0.04102 EV). Individual output curvatures range -0.14718 to +0.06028 EV. The most overcorrected source-valid patch is (44,50): source curvature +0.18602 EV, automatic gain curvature -0.33319 EV, output -0.14718 EV. Its independently held source excursion is +0.18785 EV against donor clock +0.35972 EV, giving local response about 0.52 of the common event, while the existing correction acts more like a full response. Diagnostic additional curvature to remove the measured pulse is +0.14534 EV there. Other source-valid patches need adjustments down to -0.05962 EV.

This concretely localizes an opposite-sign automatic pulse that the earlier 96-detail qualified subset missed, and confirms why a global adjustment is wrong. It is source-common-event calibration evidence, not an independently clean LEGO target or proof that all original source variation is unwanted. The next correction implementation should fit local source response and actual composed gain, preserve spatial/temporal continuity and unknown gaps, and test partial Strength/Spatial targets. No new algorithm export or improvement was produced in V27.

## Local gain composition implementation (9 October 2026)

`CommonIlluminationComponent.pulseAdditionalCurvature` now computes the additional automatic curvature from a validated source excursion and measured combined/global-only automatic gains. Its target is `(1-Spatial)*actualGlobalGain - Spatial*Strength*sourceExcursion`; the existing combined gain is subtracted once. Global gain already includes Strength. Manual EV is excluded. Missing or nonfinite measurements remain unknown, disabled controls return exact zero, and requests exceeding 0.25*Strength*Spatial EV are rejected rather than silently clamped. Geometry and independent donor certification remain caller responsibilities.

Eight focused gain-composition and temporal-reconstruction tests passed. They cover an already corrected 0.804 EV flash, opposing local over/undercorrection, partial slider targets, missing/unsafe evidence, one flash rather than three corrections, variable timing and unknown gaps. This is implemented calibration math, not yet connected to a new rendered spatial field; no new corrected export or video improvement is claimed. Next work remains integrating supported local curvature into continuous fields and validating actual native exports against retained baselines.

## V28 rendered local pulse composition candidate (9 October 2026)

The opt-in `FRANKLUMA_PULSE_COMPOSITION=1` path now executes after the existing automatic field calculation. It certifies stationary geometry with wide normalized texture correlation, sufficient image-spanning anchors, source-only held pixel fits, and leave-query-out donor clocks. It calibrates each supported local curvature against actual rendered combined/global-only gains, reconstructs each fixed source coordinate jointly using exact timestamps, and leaves unknown rows disconnected. Bounded, source-guided continuous local neutral-EV fields retain original image pixels and manual adjustments. A final actual-renderer check rejects the candidate if supported measurements worsen materially or aggregate error does not decrease by at least 10%. These checks use fitting locations; they do not substitute for independent output/control validation. Camera motion is presently excluded from this new path.

The candidate is frozen under `.build/review-v33/local-pulse-composition-v28/`, including source and runner hashes. It compiles natively; the eight gain/reconstruction tests pass. Full tests and an added actual-renderer overcorrection test are running. Native LEGO and Fox exports were launched with confidence targets enabled, luminance-only source fits, four independent donors and 0.04 EV held tolerance. Outputs are under `dist/Benchmarks/review-v33-local-pulse-composition-v28/`; logs `/tmp/frankluma-v28-{lego,fox}.log`. No V28 improvement or default promotion is claimed until terminal jobs and independent encoded-output comparisons are inspected.

V28 native LEGO and Fox exports completed and passed the independent media verifier (212/600 frames with original timing/dimensions/audio policy). The independent source-selected matched-luma audit supports the same 161 LEGO and 597 Fox transitions as the retained baseline. LEGO RMS is 0.0355431360704 EV against 0.0359506938931 (1.13% lower); transition 187→188 is 0.125622427543 EV against 0.127805978477 (1.71% lower). Fox RMS is 0.0106935117793 EV against 0.0114485285668 (6.59% lower). This is a modest real improvement, not elimination of visible flashes. The earlier supported-run V7 Fox result (0.0101280090993 EV) remains better than V28 alone; these are different opt-in candidates, not cumulative results. V28 modifies LEGO frames 184–192 in the main shot. Controlled exports for isolated flash, nonlinear clean fade and noisy clean motion are running; no default promotion.

## V29 finer evidence without changing the baseline map

The next opt-in candidate retains a 192×112 `detailThumbnail` only when `FRANKLUMA_PULSE_DETAIL=1`. The existing 96×56 thumbnail and baseline correction/scene detection remain unchanged. Detail evidence survives segment assignment and scene slicing. Pulse geometry/seed spacing/donor footprint scale physically, while the new neutral-EV residual is sampled back onto the original baseline map. The map dimensions, original guidance and source pixels remain intact. Actual-renderer validation measures the resulting 96-grid map on the finer source evidence. This experimental retained detail adds about 258 KB per analyzed frame and is not a production mobile memory policy; streaming/bounded retention is still required before broad default deployment. Frozen V29 source/runner provenance is under `.build/review-v33/local-pulse-composition-v29-detail/`; native compilation is running.

V29 LEGO completed and passed independent media integrity. On the frozen 54 finer source-selected patches at frame 187, encoded-output curvature RMS falls from 0.0410218969765 to 0.0231151233268 EV (43.65% lower); the worst (44,50) overcorrected patch improves from -0.147177762743 to -0.0893943899230 EV (39.26% smaller magnitude). Residual errors remain. The broader independent matched-luma audit is mixed: 161-transition RMS is 0.0356250611813 EV (0.91% below baseline), but transition 187→188 is 0.129283429971 EV, 1.16% above baseline 0.127805978477. Thus improved local pulse curvature does not prove improved every-frame continuity or a perceptual fix. Next tuning must address this discrepancy and remaining local gain attenuation; no default promotion.

The retained V4 partial-target runner rejected all three adversarial controls because its mask parser retained the 72-frame generator default. These failures occurred before scoring; they do not indicate correction failure. `PartialTargetAudit.swift` now sets the expected mask frame count from independently decoded source media after verifying all four inputs agree. A fresh immutable V28b control runner is being built. Full debug tests remain live; a one-second process sample confirms active `SurfaceLighting.estimate/regularizedGains` computation, so the test process was not restarted or interrupted.

V29 Fox completed and passed independent media verification. Its supported-transition RMS is 0.0114371015127 EV (0.10% below the retained baseline), substantially weaker than V28's 6.59% improvement. No V29 Fox scene printed an accepted pulse-composition result; finer evidence is not uniformly more effective. A future resolution fallback or broader source model must be validated generically rather than selecting algorithms by video name.

The repaired independent clean-target audits scored all 300 frames of each V28 control. Isolated-flash foreground residual RMS is 0.00307877999039→0.00306769337663 EV, background 0.000206212254327→0.000148487400938 EV; there is no double correction of the isolated source event. Nonlinear clean fade changes foreground RMS 0.00264966079990→0.00265086860480 EV and background 0.00279713855369→0.00279762671370 EV: tiny regressions (~0.00000121/0.000000488 EV), with worst and p95 errors unchanged. Noisy clean motion scores are exactly unchanged. Reports are in each V28 control directory as `partial-target-review.json`. This does not replace the broader motion/colour/partial-slider suite. The ~-0.024 EV common target offset remains a separate calibration issue.

## V30 correction-boundary anchors (9 October 2026)

Source lighting reconstruction still removes its unobservable constant/linear components by default. A separate `anchorEndpoints` option now fixes correction increments to zero at each independently supported run endpoint. This chooses a correction gauge without claiming that unknown source illumination is quiet. Unknown shared boundary rows remain nil; both neighboring run endpoints receive no increment. A variable-frame-timing test confirms that the supported curvatures remain recoverable when the shared boundary is left unchanged. The opt-in production experiment is `FRANKLUMA_PULSE_BOUNDARY_ANCHORS=1`.

The frozen V30 runner exports both resolutions for both supplied videos. All four exports and the half-Strength local-motion export passed independent media verification. Supported-transition LEGO RMS: base 0.0356260112346 EV (0.90% lower than baseline), detail 0.0355539713616 EV (1.10% lower). Transition 187→188: base 0.127796416711 EV, detail 0.127860135446 EV, versus baseline 0.127805978477. The detail transition's earlier 1.16% regression is reduced to 0.042%, though the remaining large step is unresolved. On the frozen 54 finer local footprints, encoded-output pulse RMS is 0.0172812805180 EV versus baseline 0.0410218969765 (57.87% lower). Worst patch (44,50): -0.0605461857429 versus -0.147177762743 EV (58.86% smaller magnitude). Residual local pulse remains visible in principle; these metrics are not a perceptual guarantee.

Fox supported-transition RMS is 0.0105517333798 EV at base resolution (7.83% lower), and 0.0101385169027 EV at detail resolution (11.44% lower). Unlike V29, all three V30 detail scenes accept a source-certified candidate after boundary anchoring. A universal fallback selected by video name is neither needed nor implemented.

The independent half-Strength local-moving target uses source Y^0.5 × clean Y^0.5. Foreground residual RMS changes 0.0180771937035→0.0179830232958 EV (~0.52% better), background 0.00391343113186→0.00307147769146 EV (~21.51% better). Background p95 absolute error worsens 0.0259093707537→0.0285995210365 EV; foreground p95 is unchanged. Report this tradeoff rather than claiming all brightness errors improved. Current experiments remain off by default.

The full pre-anchor integration suite completed: 210 tests, zero failures, 726.147 seconds. The separately compiled actual-renderer single-overcorrection test passed (54.715 seconds). Nine current gain-composition/reconstruction tests, including the new boundary test, passed. New PulseReconstruction and all three pulse test files are now included in Xcode project source membership; `plutil -lint` passes.

## V31 bounded actual-gain refinement

The experimental composition can now perform at most three passes (`FRANKLUMA_PULSE_ITERATIONS=3`; default one). Frozen original-source evidence and desired targets are reused. Each pass measures remaining actual rendered gain error, rather than reapplying the entire source correction. Patch gains are cached between accepted passes, unused global-only measurements are omitted at full Spatial, and a shared neutral gain buffer avoids repeated full-image allocations. Total per-channel map change is bounded against the initial automatic map, so three passes do not triple the limit. Each pass requires at least 10% error-energy improvement and no material supported-patch regression; rejected passes retain the last accepted field.

An actual-renderer test with simultaneous 0.2/0.4 EV source flashes and one 0.3 EV automatic correction verifies both opposite local errors, better held-patch energy with three passes, unchanged source guidance/endpoints, and the 0.25 EV total limit. It passed in 40.217 seconds. Fitting-row RMS fell 0.0707107074786→0.0126857067000→0.00555564591714→0.00381567390650 EV; those fitting diagnostics are not the independent clean-target video result. Nine focused gain/reconstruction tests also pass. Frozen V31 runner compilation is underway under `.build/review-v33/local-pulse-composition-v31-refinement/`.

Remaining validation includes native V31 LEGO/Fox outputs, controlled clean/intended-lighting cases, more motion/colour/partial-slider coverage, radius/mode behavior and production memory/latency policy. No experimental source-pulse path has been promoted as the default app algorithm.

V31 LEGO/Fox exports completed and passed independent media verification. LEGO supported-transition RMS is 0.0353878572185 EV (1.57% below baseline), transition 187→188 is 0.127807225853 EV (essentially unchanged from baseline 0.127805978477). Local 54-footprint pulse RMS is 0.0130852344138 EV versus baseline 0.0410218969765 (68.10% lower). Previously worst (44,50) patch is now -0.0256252828999 EV versus -0.147177762743 (82.59% smaller magnitude); another patch remains as low as -0.0420564333889 EV. Fox is exactly the V30 detail matched-score result, 0.0101385169027 EV (11.44% below baseline): all three scenes retained one pass because additional passes failed the acceptance checks. No further Fox improvement is claimed from iteration.

Source frame 188 has 62 held-photometry-qualified queries and up to eight independent source donors, but no supported event or quiet clock. It remains unknown rather than being filled as quiet. Future review should inspect this unresolved source/gain evidence before modifying donor classification or claiming the adjacent-frame flash is fixed. Finer output-field representation and bounded step damping are possible subsequent experiments if actual residual evidence supports them.

A frozen V31 full-control benchmark runner is compiling under `.build/review-v33/local-pulse-benchmark-v31/`. The benchmark harness now records the eight explicit experimental runtime flags alongside native hashes/settings; it does not serialize unrelated environment variables. Broad control runs and production promotion remain outstanding.

The V31 full-control benchmark compiled and its source/binary hashes were recorded. Both the 18-case motion suite and 8-case adversarial suite are now running, with one identical configuration for every case: confidence targets, detail evidence, boundary anchors, three passes, luminance source fits, four independent donors and 0.04 EV held tolerance. Immutable result label: `local-pulse-composition-v31-refinement-smooth` within each existing suite's `results/`. Native harness scores independently generated clean targets/masks and codec floors, verifies cut/timing/geometry expectations, and records exact flags. Logs `/tmp/frankluma-v31-{motion,adversarial}-benchmark.log`. These runs remain unverified until their terminal reports are inspected.

## V31 broad results and V32 confidence correction

Both benchmark handles are now absent and both aggregate score artifacts are complete: 18 motion cases and 8 adversarial cases, all with `timingAndGeometryPreserved=true`. Compared against `slider-range-v33-confidence-target-v6-smooth-default`, global-static foreground/background residual RMS changes 0.0028052/0.0038053→0.0021182/0.0023014 EV; repeated-texture-motion background changes 0.0028586→0.0019660 EV. Local-moving foreground improves slightly (0.0274596→0.0272153), but background worsens (0.0011488→0.0013829). Highlight-stress background also worsens (0.0170661→0.0172603), despite foreground improvement. Isolated-flash changes slightly adversely: foreground 0.0030788→0.0030833 and background 0.0002062→0.0002145. No-flicker motion/zoom/rotation/parallax/occlusion, nonlinear fade and noisy motion have unchanged RMS at seven decimal places. These mixed results do not support default promotion or a claim of universal improvement.

V32 source certification now requires the query itself to satisfy `abs(excursion)+2*heldError <= 0.01` when its external donor clock is quiet. Quiet neighboring donors cannot authorize removal of a strong isolated source change. A deterministic textured three-frame test, with a local 0.2 EV source change and quiet disjoint donors, confirms that other quiet queries are certified while the strong isolated patch is left uncertified (one test passed, zero failures). The V31 video artifacts predate this gate and do not validate it.

Refinement rejection diagnostics now report total-increment limits, supported-patch regressions, insufficient rows or insufficient improvement, with measured energy/error values where available. Acceptance thresholds and output math are unchanged. These diagnostics are intended to identify the next concrete cause of rejected Fox/LEGO passes rather than widening limits blindly. Current renderer integration tests are running; V32 native video and partial-control validation remain outstanding.

The current V32 renderer integration suite completed with three tests and zero failures in 89.866 seconds. This covers isolated strong-query rejection with quiet donors, actual rendered overcorrection reduction without geometry changes, and bounded repeated correction of opposing local errors. The frozen V32 native runner compiled successfully; source hashes and binary hash are retained under `.build/review-v33/local-pulse-composition-v32-confidence/runner/`. Both supplied clips are exporting to `dist/Benchmarks/review-v33-local-pulse-composition-v32-confidence/` with identical explicit runtime flags. These exports still need terminal status, media verification and independent scores before any V32 video improvement claim.

V32 LEGO export and independent media verification completed successfully. The 161 supported-transition score is exactly V31: 0.03538785721846664 EV RMS, with 187→188 at 0.1278072258533649 EV. The quiet-query guard therefore does not improve this remaining jump. Diagnostics identify total-increment-limit rejection at third passes; Fox remains processing.

## V33 budget-aware refinement

Instead of rejecting an entire proposal that exceeds the accumulated map budget, the solver now calculates the largest common step inside the original per-channel limit, scales it slightly inward for Float rounding, and evaluates the actual rendered proposal with the unchanged error-energy and patch-regression checks. A zero available step still rejects the proposal. The budget is not widened, individual map channels are not clipped, and source evidence or unknown-lighting classification is unchanged. Tests cover both gain directions, remaining budget, inward steps from a saturated boundary and invalid input. Renderer tests and a frozen native build are running; no video improvement is yet established for V33.

The V33 focused suite completed: eight gain-composition and renderer tests, zero failures, 93.525 seconds. The native frozen runner compiled, with source and binary provenance recorded. Full-Strength LEGO/Fox exports and a half-Strength local-moving export are running. Existing renderer fixtures accept full-size steps, so they verify unchanged accepted behavior but do not alone establish the benefit of damping on encoded video; the pure remaining-budget test covers the fractional-step calculation.

V32 Fox export completed and passed independent media-integrity verification. Diagnostics show all three scenes reject the second pass because of the total increment limit. V33 tests this identified limit with bounded smaller steps rather than expanding the correction allowance. Independent Fox scoring completed and must be read before recording a numerical comparison.

V32 independent Fox scoring reads 597 supported transitions at 0.010136880691222334 EV RMS, only marginally different from V31's 0.010138516902735943. V33 LEGO and half-Strength local-moving exports completed; LEGO independently passes media integrity. Two previously rejected third passes now accept common step scales 0.3703358391 and 0.5357735763, both passing unchanged fitting checks. This establishes that the fractional step is exercised on native footage, not that it fixes the unsupported LEGO jump.

The independent V33 half-Strength target comparison shows foreground residual RMS 0.0180771937035→0.0179555148648 EV and background 0.00391343113186→0.00368168860230. Foreground p95 and peak adjacent error are unchanged. Background p95 worsens 0.0259093707537→0.0301526251013 EV, and peak adjacent error worsens 0.0174764034376→0.0182514453627. Partial Strength is honored, but this tradeoff still requires improvement before default promotion. Fox V33 export remains live; its terminal output and independent scores are pending.

V33 LEGO independent scoring completed: 161 supported transitions, RMS 0.0353644979859166 EV (1.63% below the original baseline; V32 was 0.03538785721846664). The troublesome 187→188 step is 0.1278928406507625 EV, slightly worse than V32's 0.1278072258533649. Damping therefore helps aggregate error slightly but does not resolve that flash. The remaining unsupported source-query/automatic-gain evidence and field representation still require investigation.

## V34 unresolved source-query audit

Source diagnostics now include every held-photometry-qualified query's excursion/error, donor count and clock state, including unknown or insufficient donor evidence. This adds no certification. `audit_rendered_pulse_gain.py --include-unknown` measures those original-source-selected positions in decoded output and retains unknown clock values as null. The default event-only audit reproduces the frozen 54-footprint baseline RMS exactly (0.041021896976455946 EV). Python syntax validation passed. Diagnostic-only hypothetical small-footprint bank construction is skipped when diagnostics are disabled; actual donor selection is unchanged.

The native source-only audit compiled and completed for the LEGO main scene. At frame 188, 62 source-qualified queries all have unknown clocks. Their source curvature RMS is 0.0236808371381 EV, baseline output curvature RMS 0.0236175624836, actual automatic gain curvature RMS 0.0135771143797. This does not support a blanket automatic-gain-spike explanation for the 0.128 EV adjacent transition. Adjacent source-selected luminance steps at 186→187, 187→188 and 188→189 are 0.5531693, 0.2961562 and 0.1548610 EV; V33 output steps are 0.0914751, 0.1278928 and 0.0341143. A substantial exposure decline can have weak three-frame curvature at its middle, so stronger multi-timescale source evidence is the next relevant investigation. Unknown source lighting must not be filled as quiet to force removal.

V33 Fox export and independent media verification completed. Its 597-transition RMS is exactly V32, 0.010136880691222334 EV (11.46% below original baseline). The damped second-pass candidates fail the unchanged 10% fitting improvement threshold in each scene; they no longer fail the cap outright. No additional Fox benefit is established by damping.

## V35 multi-interval source evidence

The source-only native audit now supports `FRANKLUMA_DETAIL_FRAME_INTERVAL=1...6`, selecting three source samples from a bounded rolling window of `2*interval+1` thumbnails. The default is unchanged. Geometry, held photometry and disjoint donors are re-evaluated at each interval; actual source PTS determine interpolation. The caller must still supply a known single-scene range. This is measurement infrastructure, not a new correction mode or authorization to fill unknown source states.

The rendered-gain audit now reads the explicit before/middle/after frame indices from source evidence instead of assuming adjacent endpoints. Existing interval-one output is verified unchanged, including the frozen 54-footprint RMS. Python syntax and whitespace checks pass. An initial native compilation rejected a concurrent comment edit; it terminated with exit 1, and compilation was relaunched from immutable copied sources with their hashes recorded under `.build/review-v33/multiscale-source-v35/`. The frozen build is running. Wider-interval native evidence and intentional-lighting negative controls remain pending.

The frozen native build and all four LEGO interval runs completed successfully. At middle frame 188, interval one has 62 photometrically qualified queries and zero supported events; interval two (source endpoints 186 and 190) has 72 qualified queries, all 72 independently donor-supported response candidates. Intervals three and four have no qualified queries. This establishes a concrete coverage improvement from a wider interval without reducing the existing geometric/photometric thresholds. It does not yet establish safe correction of fades or a video improvement. The next implementation must reconstruct compatible multi-interval correction constraints, honor actual time/radius/Strength/Spatial, and validate intentional-lighting negatives before promotion.

## V36 joint multi-interval correction

Added sparse weighted joint correction reconstruction with explicit before/middle/after indices and actual timestamp interpolation. Only certified middle frames are correction variables; unsupported frames remain nil and retain their existing gain. This is a correction gauge, not a quiet-source assertion. Shared one-/two-interval constraints are solved together, with convergence and maximum residual checks. Seven reconstruction tests pass, including exact compatible multi-interval recovery under variable frame timing and preservation of intervening unsupported frames.

`FRANKLUMA_PULSE_MULTISCALE=1` now enables joint one-/two-frame interval composition. Stationary geometry and source photometry are recomputed for each interval, every frame in its span must belong to the same scene, and wider spans cannot exceed twice the selected smoothing radius. Rendered gain is measured at each row's actual endpoints. Existing Strength/Spatial targeting, total correction budget, damping and actual-render acceptance remain in force. The default path still uses its previous adjacent reconstruction. Current baseline renderer regression tests, an explicitly enabled multi-interval renderer test and a frozen native build are running. Intentional-fade controls, partial slider behavior and independent video scores remain required before promotion.

The ten baseline reconstruction/renderer tests completed with zero failures in 30.846 seconds. The explicitly enabled multi-interval renderer test also passed (19.505 seconds): 1,456 rows, fitting RMS 0.0790569743296→0.0141686329788→0.00620832931209→0.00426472404991 EV across three passes. These fitting values are not an independent video metric. Frozen native compilation succeeded; source/binary hashes and nine explicit runtime flags are recorded under `.build/review-v33/local-pulse-composition-v36-multiscale/runner/`. LEGO, Fox, no-flicker nonlinear-fade and half-Strength local-motion exports are now running under the matching `dist/Benchmarks/review-v33-local-pulse-composition-v36-multiscale/` directory. Benchmark provenance now also records the multiscale flag. No native V36 improvement is claimed until terminal exports and independent target scores are inspected.

V36 half-Strength local-moving export completed successfully. The LEGO handle terminated with exit 133 and no completed evidence. Source inspection found the invalid `2..<n-2` interval-two range for a three-frame scene. V36b filters unavailable intervals before constructing ranges and adds an explicitly enabled three-frame regression test. A new immutable V36b runner is compiling; the failed V36 LEGO run is retained and excluded from validation. Existing Fox/fade runs have not been restarted because this short-scene condition does not apply to their full-length scenes.

The explicitly enabled three-frame test passed in 2.415 seconds; V36b native compilation succeeded and LEGO is exporting into its new V36b directory. Independent V36 half-Strength target scores show foreground RMS 0.0180771937035→0.0179082712591 EV, background 0.00391343113186→0.00257883686895 EV (34.10% lower). Foreground p95 is unchanged and peak adjacent error improves slightly (0.0844657504384→0.0842715431540). Background p95 improves 0.0259093707537→0.0257027960580 and peak adjacent error 0.0174764034376→0.0120185554430. Unlike V33, this tested partial-Strength profile improves both average and reported tail errors.

V36 no-flicker nonlinear-fade export and independent media verification pass. Independent clean-target comparison shows exactly unchanged foreground/background RMS, p95 and peak adjacent errors against the baseline. This covers one intentional nonlinear fade, not every possible lighting transition. Fox remains live. A frozen V36b broad benchmark runner is compiling under `.build/review-v33/multiscale-benchmark-v36b/`; broad motion/adversarial validation is still pending.

V36b LEGO export and independent media verification completed. Independent supported-transition RMS is 0.035470588038871494 EV across 161 transitions, 1.34% below original baseline but slightly worse than V33's 0.0353644979859166. The 187→188 jump is 0.12752198443887855 EV, a marginal reduction versus baseline 0.127805978477 and V33 0.1278928406507625; it remains unresolved. The gain in source evidence coverage is therefore not equivalent to a large output improvement. V36 Fox export and independent media verification completed; its independent score is running.

The V36b broad benchmark compiled. Initial launches terminated before case processing because the required `runner/build-provenance.json` was missing (harness failure, not a correction result). The source/binary manifest was supplied and both suites were launched with a new immutable label `joint-multiscale-v36b-smooth-r1`; failed-label artifacts remain intact. The motion and adversarial suites are now live with the same nine explicit flags. No broad V36b result is claimed yet.

V36 independent Fox score completed: 597 supported transitions at 0.011398057696670098 EV RMS, only 0.44% below original baseline and substantially worse than V33's 0.010136880691222334 (11.46% below baseline). Replacing adjacent reconstruction with the new joint system therefore loses an established improvement on Fox. It must not be promoted. The next integration should preserve the validated adjacent correction and add independently supported wider constraints without sacrificing it; this requires explicit per-interval compatibility and acceptance evidence rather than video-specific switching.

## V37 supplemental wider constraints

`FRANKLUMA_PULSE_SUPPLEMENT=1` with multiscale enabled now runs the adjacent reconstruction first, retaining its original correction gauge and acceptance. A second phase uses wider targets only at query middle frames without an adjacent target, jointly with remaining adjacent-target error. Both phases share the original total budget. Unsupported source centers remain excluded. Adjacent supported corrections may change only while their aggregate rendered target-error energy does not increase and no individual adjacent error grows by more than 0.001 × Strength EV. This protects correction quality rather than freezing all prior gain values, which would prevent compatible joint refinements. The second phase separately requires at least 10% improvement on at least twelve wider-only rows and retains the original patch-regression checks.

The sparse solver accepts an explicit supported-variable set, with tests covering a protected excluded middle frame. Initial supplemental tests and a frozen prototype runner are being retained. The final target-error protection revision is compiling/testing separately (`/tmp/frankluma-v37c-supplement-tests.log`); the earlier frozen prototype does not include this last revision and must not be used to claim current-source validation. Broad V36b suites remain live and have not been restarted. V37 native output, partial controls and fade/negative tests remain pending.

The V37c enabled suite passed twelve tests with zero failures in 57.264 seconds. Frozen V37c native compilation succeeded, and supplied LEGO/Fox exports are live with ten explicit runtime flags and recorded source/binary hashes. The current function additionally accepts explicit test overrides for multi-interval/supplement selection, so tests need not mutate process environment. A new renderer test with a wider-only lighting event passed in 34.440 seconds: the supplemental result lowers the middle frame's decoded-pixel luminance residual by at least 10% relative to adjacent correction, preserves all source guidance and the original 0.25 EV map budget. In that fixture, wider fitting RMS falls 0.0668104381730→0.0109833278932→0.00483196093863→0.00347752343356 across three supplemental passes. This establishes that the supplemental phase can perform a useful correction rather than simply reject every proposal; real footage still needs independent scores.

Both V36b broad suites are now terminal and complete: eighteen motion plus eight adversarial cases, all timing/geometry preserved. Their old joint-system results remain mixed. Full-Strength local-moving background RMS worsens 0.0011488→0.0018864 EV, although foreground improves 0.0274596→0.0268719; highlight background worsens 0.0170661→0.0173016. Global-static and repeated-texture background improve, while all seven tested no-flicker controls retain unchanged RMS at seven decimal places. Isolated-flash foreground/background change slightly adversely (0.0030788/0.0002062→0.0030853/0.0002200). These results apply to V36b's replacement joint system, not the new V37c supplement, and do not support default promotion.

V37c LEGO export and independent media verification completed. Independent 161-transition RMS is 0.035357778878644955 EV, 1.65% below original baseline and slightly below V33's 0.0353644979859166. The 187→188 step is exactly V33's 0.1278928406507625, so the main jump is not fixed. Supplemental passes are accepted on some independently supported rows, but their fitting improvement is not a perceptual or large aggregate improvement. Fox remains live. A same-configuration export of the previously documented CC0 Teja clay stop-motion source is now running to extend real-footage coverage; its rights/attribution evidence remains in `PracticeFootage/README.md` and `scripts/validation/benchmark-real-cases.json`. No new download or new licence claim is introduced.

V37c Fox export and independent media verification completed. Its independent 597-transition RMS is 0.010136880691222334 EV, exactly V33/V32's value, retaining the 11.46% reduction against original baseline. The supplemental integration therefore avoids the previous V36 Fox regression, but establishes no further Fox benefit. Teja export (597 frames, 480×360, 20.587 seconds) completed and passed independent media integrity; a matched same-core baseline with only confidence targets enabled is now exporting. Its source-selected transition audit is running; clean ground truth is unavailable.

## V38 measured-error fit consistency

The V37c main LEGO scene's wider proposal is rejected for insufficient improvement: 82 wider-only rows, fitting energy 0.135353754873→0.134745833877. Added per-scene solved/residual-rejected/budget-rejected key counts to distinguish source coverage from reconstruction rejection. The fixed 0.01 EV maximum reconstruction residual may be stricter than held source-model errors that already passed certification; rejection counts must be inspected before calling that the confirmed cause.

An opt-in `FRANKLUMA_PULSE_UNCERTAINTY=1` experiment checks each joint row's fit against `Strength × Spatial × max(0.01, 2 × measured held error)` rather than one fixed unscaled maximum. This deterministic bound is not a statistical confidence interval. It changes only reconstruction consistency, retaining source event certification, finite/geometry checks, the original gain cap, adjacent-error protection and renderer acceptance. Nine reconstruction/consistency tests pass, including scaled controls and rejection of invalid or mismatched input. Frozen V38 compilation succeeded; source/binary provenance and eleven runtime flags are recorded. LEGO and half-Strength local-motion native exports are running. No V38 output improvement is yet established.

V38 LEGO and half-Strength exports completed. LEGO independently passes media integrity and exactly reproduces V37c's supported-transition score (0.035357778878644955 EV; 187→188 0.1278928406507625). Main-scene diagnostics at 15.0 seconds report 160 solved keys, zero residual rejections and zero budget rejections. The wider candidate still improves fitting energy only 0.135353754873→0.134745833877 and is rejected. Thus the fit-precision hypothesis does not explain or resolve this example. V38 half-Strength scores reproduce V33: background RMS improves 0.00391343113186→0.00368168860230, but p95 worsens 0.0259093707537→0.0301526251013 and peak adjacent error 0.0174764034376→0.0182514453627. This is inferior to the earlier replacement V36 half-Strength result and does not support promotion.

The CC0 Teja paired baseline/export both pass media integrity. On the same 534 source-supported transitions, baseline RMS is 0.013886644744745427 EV and V37c is 0.013865562406702116 (~0.15% lower). Eight source/corrected contact-sheet stills were visually inspected; changing clay shapes and the three main camera compositions remain present, with no obvious contour deformation in those sampled stills. This is neither full playback validation nor clean-ground-truth evidence; the numerical result measures variation on supported textures.

Matched LEGO Steady scene exports completed: baseline RMS 0.03494729906955181 EV, supplemental 0.034355145741872616; 187→188 is 0.1240181634176975 and 0.1240964150402671, respectively. Steady scene reduces overall variation relative to Smooth, but still leaves the main jump and its supplement slightly worsens that step. Selecting a different mode is therefore insufficient to resolve the remaining case.

Current source inspection shows that rendered field gain uses RGB-guided bilinear weights on the original 96×56 map, while desired query increments are scattered/averaged on the finer source grid and then resampled. A direct fit through the renderer's actual guidance weights and local luminance response is the next relevant implementation experiment. Existing successful synthetic temporal reconstruction does not prove that this scatter/resample operation reproduces the desired local gains. Retain source certification, unchanged geometry, original total budget and independent renderer/video acceptance when replacing that spatial reconstruction step.

## V39 renderer-guided spatial reconstruction

Added `SpatialRenderer.fitSurfaceIncrements`: it constructs each 5×5 patch's local luminance-gain Jacobian from the renderer's actual normalized RGB-guided bilinear weights and finite-difference response to a neutral EV increment, including highlight protection/clamping. Sparse regularized least squares fits map-node increments directly to desired patch gains; unobserved nodes remain zero. Nearly clipped/nonresponsive patches, invalid/nonfinite data and unconverged solves abstain. Source pixels and the original map guidance/dimensions are unchanged.

`FRANKLUMA_PULSE_RENDERER_FIT=1` applies this fit only to the supplemental wider phase. The validated adjacent spatial reconstruction remains unchanged; original total-budget damping, adjacent target-error protection and actual-rendered acceptance still validate every proposal. Nine reconstruction regressions pass. Two new renderer tests pass (0.034 seconds): simultaneous opposite patch gains are reproduced to below 0.015 EV RMS through actual CPU renderer evaluation, and clipped highlights with no gain response return no fitted correction. A complete wider-only-event integration test is running with the fit flag explicitly enabled. Frozen native V39 compilation is running under `.build/review-v33/local-pulse-composition-v39-renderer-fit/`. Native exports, paired slider/negative controls and perceptual review remain pending; no V39 video improvement is established.

Frozen V39 native compilation completed, with source/binary hashes and twelve explicit runtime flags recorded. LEGO and half-Strength local-motion native exports are now live. The measured-error experiment is explicitly disabled in this candidate so the spatial fitting comparison isolates the new renderer-guided reconstruction. The prior scalar scatter/average code remains available for matched comparison and remains the default; no production algorithm promotion has occurred.

The explicitly enabled renderer-fit wider-only integration test completed successfully. Its supplemental fitting RMS falls 0.0668104381730→0.000986335180716→0.0000127720649976→0.000000924594505136 EV, versus the previous spatial reconstruction's final 0.00347752343356 EV. The test also verifies lower actual middle-frame luminance residual than adjacent-only correction, unchanged source guidance and the total gain budget. These fitting-row numbers are not encoded-video or perceptual results; native comparisons remain pending.

V39 LEGO and half-Strength exports completed; LEGO passes independent media integrity. Independent LEGO RMS is 0.035361698569577084 EV, close to V37c, with the same unresolved 187→188 jump (0.1278928406507625). The main scene's wider fitting energy improves 0.135353754873→0.133183135453, still below the required 10% and is rejected. The half-Strength wider proposal improves its fitting energy 0.311813884452→0.000924785579326 but worsens 82 protected adjacent rows and is rejected; independent output therefore retains V33's mixed partial-control score. The synthetic field-fit improvement does not translate into a large real-video improvement in this candidate.

## V40 per-node bounded spatial fit

Added optional box constraints to the renderer-guided spatial solve. Bounds intersect each node's remaining original correction budget across all three channels, rather than rejecting or scaling every spatial region together when one node is saturated. Sparse coordinate minimization keeps all iterates inside those bounds and checks its projected gradient before accepting a fit; cancellation, nonfinite inputs and unconverged results abstain. The subsequent rendered target-error and adjacent-protection checks remain unchanged. `FRANKLUMA_PULSE_BOUNDED_FIT=1` gates this experiment. Budget scaling uses the existing 1e-7 Float tolerance for bounded proposals to avoid letting harmless rounding couple otherwise independent regions.

A new regression sets one region's positive allowance to zero and checks that an independent negative correction remains possible while all node bounds are honored. The initial 512-cycle solve abstained before convergence and failed that test; the cycle limit was increased with the convergence threshold retained and explicit rejection diagnostics added. The bounded-fit tests are running again. Native validation and any video benefit remain unproven. Rejected proposal logs now record the step scale and both adjacent error energies so budget and protection failures can be distinguished.

The two bounded/renderer regression tests now pass in 0.110 seconds, including the saturated-region case and highlight abstention. Frozen native V40 compilation and the explicitly enabled full wider-only integration test are running. No source/matching thresholds or output geometry are relaxed by this bounded solve; original footage and independent controlled targets remain required for acceptance.

V40 frozen compilation and full wider-only integration passed (36.619 seconds). LEGO and half-Strength exports completed. The bounded solve addresses the main scene's field-fit attenuation: wider fitting energy falls 0.135353754873→0.0000525319775930 and adjacent energy 0.0822734872242→0.0000499008934891 at full step. However, two other checked patch errors increase by up to 0.021800523536 EV, beyond the unchanged 0.02 EV limit, so that candidate is rejected. The half-Strength full proposal improves both aggregate energies but increases 82 individual protected adjacent errors, so it is also rejected. These improvements remain uncommitted fitting proposals, not output video improvements.

## V41 smaller-step retries

`FRANKLUMA_PULSE_BACKTRACK=1` tries fractions 1, 1/2, 1/4, 1/8 and 1/16 of a bounded supplemental proposal before abandoning it. Each fraction is evaluated through the actual renderer against the same per-patch limits, adjacent aggregate/individual protection and at least 10% primary error-energy improvement. The previous accepted field remains the fallback. Convex interpolation between budget-valid maps preserves the original budget and source geometry; no thresholds are widened. Scenes with fewer than twelve eligible wider-only rows now skip the supplemental phase before expensive fitting because they cannot pass its existing acceptance gate.

The enabled full wider-only renderer integration test passed; its full-size accepted behavior is unchanged. A frozen V41 native runner is compiling. Actual footage is required to demonstrate that a smaller step is accepted in the previously rejected cases; no V41 encoded improvement is yet established.

## V41b cumulative refinement safeguards

Smaller-step retries now compare protected per-patch error with both the last accepted field and the field at the start of the supplemental phase. This prevents multiple individually tolerated refinements from accumulating beyond the original 0.001 × Strength adjacent or 0.02 × Strength general allowance. The adjacent aggregate-energy requirement and original total map budget remain unchanged. Six pure gain-composition tests pass, including positive/negative cumulative-budget and partial-Strength checks; the previously completed V41 full wider-only integration passed in 36.095 seconds. That integration precedes this last cumulative-safeguard edit and is not full V41b validation.

Frozen V41b native compilation succeeded under `.build/review-v33/local-pulse-composition-v41b-cumulative-backtrack/`, with eleven source files hashed in source-provenance.json and binary/runtime provenance in runner/build-provenance.json. LEGO and half-Strength local-motion exports are running into a new immutable V41b directory with fourteen explicit flags. No encoded V41b improvement is claimed until independent media/target audits complete.

V41b native exports and independent media verification completed for LEGO, Fox, half-Strength local-motion and the intentional nonlinear fade. The current-source wider-only integration passed in 36.041 seconds. Smaller steps are accepted on LEGO's main wider rows, but independent LEGO RMS is 0.035360191483837435 EV (1.64% below baseline), and 187→188 rises to 0.1284398601040407 EV versus baseline 0.127805978477. The main visible jump remains unresolved. Fox retains exactly the V33 score, 0.010136880691222334 EV (11.46% below baseline).

The independent half-Strength target improves background RMS versus V33, 0.00368168860230→0.00336079951088 EV, p95 0.0301526251013→0.0292022523030, and peak adjacent error 0.0182514453627→0.0167210623371. Foreground RMS improves only slightly, while peak adjacent error worsens 0.0844657504384→0.0845780504124. Relative to the original half-Strength baseline, background RMS is ~14.1% lower and its peak improves, but p95 remains worse. This is mixed partial-control evidence, not promotion approval. The fade changes slightly: foreground/background RMS fall by roughly 1.2e-6/4.9e-7 EV, while p95/peak adjacent errors are unchanged and clipping remains zero. Exact fade preservation is not established for this candidate. Machine-readable evidence is review-report.json in the frozen V41b directory.

Independent decoded 72 wider source queries at LEGO frame 188 improve output curvature RMS to 0.0126270875529 EV from the earlier baseline 0.0444391, but their 187→188 median absolute step is only ~0.0234 EV while larger source-selected 13×13 footprints measure 0.12844 EV. The remaining step is concentrated in larger/other regions; distance from those certified small-patch centers correlates with larger residual steps in this sample, but does not establish causation or validity of those regions over the whole wider interval. A coverage diagnostic is retained separately.

## V42 source photometry footprint review

Generalized the pure source-only constant RGB/luminance excursion validators to odd footprint sides 5–13 while retaining reciprocal contiguous held folds, all-interior checks and clipping/dark thresholds. Existing calls use the same default side 5. Source pulse diagnostics accept an explicit photometry half-size, enforce bounds and donor disjointness across the larger footprint, and record it; production correction calls remain unchanged. The native source-only audit accepts FRANKLUMA_DETAIL_PHOTOMETRY_HALF for this experiment. All 33 CommonIllumination tests passed, including larger uniform-exposure acceptance and held/interior nonuniform rejection. A frozen V42 source-only runner is compiling; larger-footprint evidence is pending. This change does not yet introduce larger-footprint correction into exported video.

Frozen V42 source-only multi-footprint audits completed at half-sizes 2, 4 and 6 with unchanged source geometry and thresholds. At LEGO frame 188, qualified/certified queries fall from 72/72 to 49/49 and 35/35. The sampled torso region has one small qualified query and zero larger ones; clipping/mixed/nonuniform photometry increases rather than providing more correction evidence. Larger constant-exposure footprints therefore do not solve this coverage gap and are not integrated into correction. All jobs completed normally; source-only support is recorded in lego188-support-by-footprint.json. A separate frozen V42 run is examining the already implemented held-validated tone/plane/linear/observable-RGB diagnostics on rejected small source patches in the wider interval; it remains diagnostic-only.

The V42 rejected-source model review completed. Of 185 rejected frame-188 small source queries, linear-luminance diagnostics pass four and plane diagnostics three, but neither supplies a new held-qualified torso query. Observable-RGB and tone diagnostics pass none. These existing models therefore do not supply evidence for the remaining torso jump in this interval. Their output is retained in lego188-model-diagnostics.json; none is authorized or used as a correction. Further work must address source-region observability/geometry or the spatially varying lighting model, rather than assuming larger footprints or a looser correction strength fixes this result.

## V43 source-selected masked photometry

Added a diagnostic-only neutral luminance validator that excludes pixels clipped or near-black in any source bracket frame. It requires at least 80% observed footprint coverage and reciprocal held-fold coverage, checks uniform response in every observed interior pixel, and returns the explicit observed subset. It does not infer excluded pixels, use output/clean targets for source selection, or authorize corrections. Geometry and external source donors remain separate gates. All 34 CommonIllumination tests pass, including clipped-pixel exclusion, invalid-input rejection, insufficient coverage and held/interior nonuniformity. The frozen V43 source-only runner compiled successfully and the wider LEGO interval is being audited with recorded source/binary hashes. Production correction behavior is unchanged.

V43 initial masked audit supplies zero additional qualified source patches because a negative resampling RGB sample rejects the whole patch. V43b excludes those individual finite negative pixels alongside clipped/dark pixels, retaining every coverage/held/interior requirement and rejecting all nonfinite input. All 34 tests pass with the added negative-pixel regression. Frozen V43b compiled and its LEGO wider audit completed: thirteen additional photometrically qualified frame-188 patches, but none in the previously sampled torso region. Other wider centers qualify six/five/seventeen at 186/189/190. No independent donor certification or correction is claimed for these diagnostics. V43/V43b immutable records remain separate.

A same-frozen-core native global-only LEGO export is running with only confidence targets enabled. This ablation separates existing global and spatial contributions in the remaining jump and uses the actual Spatial slider's zero endpoint; it does not promote any source-masked correction or assume that one slider setting solves most videos. Independent decoded-region scoring remains pending.

The global-only and half-Spatial LEGO references completed and pass independent media checks. On the same 161 source-selected transitions, global-only RMS is 0.0563677182597 EV and 187→188 0.137113339293; half-Spatial RMS is 0.0436244052270 and jump 0.140690972798. Both are worse than full-Spatial baseline RMS 0.0359506938931/jump 0.127805978477 and the V41b candidate. These actual slider endpoints/intermediate settings do not resolve this LEGO jump. They are matched frozen-baseline ablations, not V43 correction exports. Their settings/media/score references are retained in lego-spatial-reference-report.json.

## V44 dense measurement correspondence

Added a diagnostic-only source sampling helper using native exposure-normalized optical flow. It requires reciprocal closure at every measured pixel, bounded two-pixel displacement and an independent wide source-texture correlation above 0.95 before bilinear measurement sampling. Source pixels, output geometry and renderer behavior are unchanged; flow is ephemeral. Rejected constant source queries can emit a separate dense-transport/masked-photometry record; they are never added to source donor clocks or correction callbacks. A regression passes exact exposure-preserving translated sampling and rejects inconsistent flow, over-limit displacement and flat identity. Frozen native V44 compilation is running; real-source qualification and negative/motion controls remain unverified.

Frozen V44 compiled and completed both native source-only audits. Across rejected LEGO wider queries, 36 dense-transport/masked photometry records qualify; at frame 188, eighteen qualify, including one sampled torso point (110,50), excursion +0.376315741213 EV, held error 0.037442589562 and maximum displacement 0.086657697863 detail pixels. At 190 a different torso point qualifies. The independently generated clean moving-subject input produces zero additional qualified records out of 41 rejected queries. This is source photometric evidence only: donor certification, rendered correction and broad generalization remain unverified. It does not prove that the previously worst larger torso footprints are now observable or corrected. The two jobs are terminal and their immutable diagnostic snapshots remain in the V44 folder.

Current source additionally includes `SpatialRenderer.sampledSurfaceGain`, measuring transported automatic gain by bilinear interpolation of rendered radiance at the same source samples, rather than interpolating EV or rendering already interpolated RGB. This preserves nonlinear guidance/highlight behavior. A regression passes an independently calculated fractional footprint with highlight limiting and demonstrates that blending RGB before rendering gives a materially different answer; invalid indices, duplicates and nonfinite positions abstain. This latest helper is not in the frozen V44 diagnostic runner and is not yet used by the export correction path. Next integration must preserve these transported footprints/masks through source donor certification, gain targets, renderer fitting and acceptance before testing actual encoded output.

## V45 transported-footprint correction integration

The opt-in FRANKLUMA_PULSE_DENSE=1 path adds transported source queries only to wider supplemental measurements, retaining the original adjacent phase. These queries must pass masked held/interior photometry, reciprocal bounded flow and a separately built clock of original strict donors. They never become donors themselves; exclusion is enlarged by four pixels for the bounded transport. Their coordinates and observed pixel subset are preserved in gain measurement, the renderer's finite-difference Jacobian, iterative error targets and candidate acceptance. Multiple distinct footprints at the same source frame are fitted jointly, rather than silently replacing one measurement with another. Existing Strength/Spatial target composition, original total budget, cumulative per-patch/adjacent protection and smaller-step retries remain unchanged. No output image is warped or blended across frames.

Four existing gain/renderer/geometry regressions passed. The additional fractional masked-footprint bounded fit test initially failed to compile because a fixture expression exceeded Swift's type-checking limit; simplifying that expression fixed it and the test passed in 0.185 seconds. The first full integration launch also terminated at that fixture compile failure and is not passing evidence. A new enabled full wider-event integration test is now running. Frozen native V45 compiled, with eleven source hashes and fifteen explicit runtime flags recorded; LEGO and half-Strength local-motion exports are running into new immutable output directories. No V45 encoded-video quality improvement is established yet.

V45 enabled full wider-event integration passed in 37.339 seconds. Native LEGO and half-Strength exports completed and both independently preserve media timing, dimensions and audio policy. At the main LEGO scene, eighteen transported frame-188 queries pass separate donor corroboration; main solved keys rise to 170 with zero residual/budget rejections. Smaller supplemental steps are accepted without widening any limit. Independent LEGO RMS is 0.035174557317297774 EV on the same 161 transitions, 2.16% below original baseline; main 187→188 step is 0.11984201698687874 EV, 6.23% below original baseline and 6.69% below V41b. This is a modest actual encoded improvement, not resolution of the visible flash. Neighboring 189→190 step rises to 0.0208290844470 from V41b 0.0185715265043, so the local change is mixed. Half-Strength independent foreground/background target scores are exactly unchanged versus V41b, including its known mixed foreground-peak/p95 limitations.

Frozen same-configuration Fox and previously documented CC0 Teja exports are live. A native broad benchmark runner is compiling from the exact V45 core plus current independent BenchmarkAudit.swift with the new flag recorded; broader scene/negative/control results remain pending. The default application algorithm has not been promoted.

V45 Fox and Teja exports completed and independently pass media integrity. Fox retains exactly 0.010136880691222334 EV on 597 supported transitions (11.46% below original baseline), with no further benefit. Teja has 0.013866578801232593 EV on 534 transitions (0.1445% below its matched confidence baseline), a negligible measured difference, not a visible-improvement claim. The V45 machine-readable review-report.json collects real/partial/media evidence.

Both V45 broad suites are terminal and complete: eighteen motion and eight adversarial cases, all internal timing/geometry checks pass and all detected cuts match expected cuts. All seven no-flicker controls retain exactly unchanged foreground/background RMS against the same confidence-target baseline. Results remain mixed: global-static foreground/background improve 0.00280523059748/0.00380533278118 to 0.00217101614432/0.00226219673587; local-moving foreground improves 0.0274596139897 to 0.0268974288203 but background worsens 0.00114880462002 to 0.00138091869955; highlight background worsens 0.0170660667351 to 0.0172996713386. Isolated-flash foreground improves slightly, background worsens slightly. Full comparative errors/tails/clipping/scene cuts are retained in dense-benchmark-v45/comparison-to-confidence-baseline.json. These results apply to V45 only and do not justify default promotion.

## V46 source significance protection

An opt-in FRANKLUMA_PULSE_SIGNIFICANCE=1 check freezes each current automatic gain target when the requested extra correction is no larger than max(0.003 EV, twice the source held-pixel RMS error), scaled by Strength times Spatial. Stronger proposals retain their requested correction. This deterministic significance floor is not a probabilistic confidence interval. Rows remain in the fit/protection system with zero extra target; source-supported already-correct regions are not discarded. Seven gain-composition tests pass, including partial-slider scaling, positive/negative small-change suppression, strong-change retention, exact zero bypass and invalid-input rejection. Frozen native V46 compiled with sixteen explicit flags and immutable source/binary provenance.

V46 LEGO and full-Strength local-motion exports completed and independently preserve media. The full-resolution independent clean-luminance target shows background RMS 0.00138091872024 to 0.00106460103898 versus V45 (also below original benchmark baseline 0.00114880462002), p95 0.0262707913930 to 0.0256242470085 and peak adjacent error 0.00656146359972 to 0.00502345368449. Foreground RMS gives up some V45 benefit (0.0268974287654 to 0.0271066323539) but remains below original baseline 0.0274596139897, and its peak improves. LEGO gives up some V45 benefit: RMS 0.035410644603805955 EV and main jump 0.12513913553849665, versus V45 0.035174557317297774/0.11984201698687874. The main flash remains unresolved. These two-case results support reducing weak corrections as a robustness direction, not broad/default readiness. V46 review-report.json records the evidence and limitations.

Further primary research reviewed: Farbman, Fattal, Lischinski and Szeliski, 2008, [Edge-Preserving Decompositions for Multi-Scale Tone and Detail Manipulation](https://www.microsoft.com/en-us/research/wp-content/uploads/2008/08/Farbman-EPD-small-SG08.pdf). Their weighted least-squares framework includes piecewise-smooth propagation of sparse constraints and discusses halo/edge limitations. Applying a related spatial continuity prior to our EV increments could address gaps between supported patches; this is an implementation hypothesis, not a deflicker result or evidence of any commercial tool's internals. Current renderer fitting gives unobserved nodes zero increment. A bounded, guide-aware smoothness term should be tested against protected regions, mixed lights and encoded outputs before changing that behavior. It has not been implemented or validated here.


### V47: optional source-guided spatial prior (not promoted)

Added spatialRegularization (default zero) to the renderer-response fit. With a positive value it activates map nodes and appends horizontal/vertical EV-difference constraints, weighted by exp(-squared log-RGB guide contrast / 0.3). The amplitude ridge, original box bounds, source geometry and rendered acceptance checks remain. Unknown temporal frames are still not filled. This prior is an inference about spatial continuity, not new photometric evidence; similar-looking independently illuminated surfaces can still be coupled incorrectly.

An explicit FRANKLUMA_PULSE_SPATIAL_PRIOR=1 gate selects weight 0.1 in the wide-phase fit. Benchmark metadata records the gate. Default behavior remains off. No encoded real-video results yet and no claim of improvement on LEGO or Fox.

The new synthetic regression checks propagation into an unobserved same-material region, isolation across a strong reflectance boundary, and bounded fits. All 21 SpatialRendererTests passed (18.605 seconds; /tmp/frankluma-v47-spatial-prior-tests.log). This verifies the renderer implementation before adding the pipeline gate; compilation of that call site is checked separately. Next: freeze the candidate and measure actual encoded real clips, independent clean-motion controls, tails and partial sliders before deciding whether this hypothesis improves the end result.

V47 encoded LEGO and local-moving exports are terminal-success. Independent matched LEGO score: 0.035358759366313025 EV RMS across 161 source-supported transitions; frame 187 to 188: 0.1278928406507625 EV. Known-clean control compared with V45: foreground RMS 0.0268974287654 to 0.0269471989649; background RMS 0.00138091872024 to 0.00125525815273; background p95 error 0.0262707913930 to 0.0267104745559. Mixed control results, no default promotion. Exact media checks completed for both. Machine report: .build/review-v33/local-pulse-composition-v47-spatial-prior/review-report.json.


### V48: overlapping temporal intervals (experimental)

Independent encoded V45 footprint errors for LEGO 187 to 188 include residual steps of -0.6066 EV at (54,38) and -0.5296 EV at (54,30), substantially larger than the median. V47 changes those tails only modestly. A broad source-only diagnostic at doubled analysis coordinates across frames 186 through 190 shows opposite adjacent and wide curvature signs, compatible with a multi-frame exposure pattern. These footprints have no held geometry/occlusion validation in this diagnostic and cannot themselves authorize corrections. Evidence is in .build/review-v33/local-pulse-composition-v48-measurement-review/.

The current supplemental solver discards wider constraints whose middle frame already has an adjacent constraint. Added default-off FRANKLUMA_PULSE_JOINT_INTERVALS=1 to retain both source-certified constraints at such frames. The same certified variables, solver residual checks, original total correction budget, renderer fit and actual rendered acceptance gates remain. This tests temporal coupling rather than increasing gain or accepting uncertified source regions. Spatial prior and significance remain separately configurable, allowing an isolated comparison to V45. No encoded V48 result yet; no claim of a production fix.

V48 validation froze before a follow-up acceptance-coverage correction: the legacy primary-energy gate still counts only wider rows without adjacent middle support. The frozen V48 run is intentionally preserved as an intermediate, narrower experiment. Current source now includes overlapping wider rows in primary energy when JOINT_INTERVALS is enabled; adjacent protection and initial/current regression budgets remain. This follow-up needs its own frozen candidate and encoded validation, and must not be attributed to V48 exports.

V48 intermediate encoded exports/scoring/media verification are terminal-success. LEGO 161 supported transitions: RMS 0.03533062584180692 EV; 187 to 188 jump 0.12659169003164217 EV. Control foreground RMS 0.026897428765446728 to 0.026922011425655056; background RMS 0.0013809187202403392 to 0.001313519952443245. These are mixed and inferior to V45 for the main LEGO jump. V48b complete acceptance coverage frozen separately; 9 temporal tests pass; its LEGO/control exports launched and live handles recorded in its validation-jobs.json. No scoring or promotion claim for V48b yet.

V48b complete encoded validation terminal-success. LEGO RMS 0.03533062584180692 EV across 161 supported transitions; main jump 0.12659169003164217 EV. Control metrics equal intermediate V48, with background RMS slightly lower but foreground RMS and background p95 slightly higher than V45. Exact media checks pass both outputs. Main scene joint fit solves 152/170 keys; 18 residual-rejected. Large candidate steps lower aggregate adjacent energy substantially but worsen several individual protected rows, so actual-rendered acceptance correctly backtracks/rejects. This is a spatial/temporal fitting tradeoff; loosening the protection would risk overcorrection. The fit needs to honor the joint temporal constraints more directly instead of assigning each surface a solved increment and fitting frames independently. No default promotion. Machine report in V48b review-report.json.


### V49: direct temporal residual fitting (experimental, off)

Added optional positive finite observation weights to fitSurfaceIncrements; default weights remain one. Weighted least squares scales both Jacobian terms and targets by square-root weight, retains the original ridge and box bounds, and rejects malformed weight arrays.

FRANKLUMA_PULSE_TEMPORAL_FIT=1 (requires joint intervals, dense measurements and bounded fit) performs four block-coordinate sweeps after the initial frame-wise candidate. For each certified variable frame, all source-certified temporal rows involving it are measured through the actual candidate renderer. Their residual is divided by that frame's temporal coefficient (1 for middle, negative endpoint interpolation weight otherwise). Fit weights are coefficient squared times 0.0001 / max(0.0001, held-error squared). This is deterministic weighting, not a confidence probability. Each update preserves original total per-node correction limits, guidance and image geometry. Unsupported temporal variables never become adjustable. Final original/current regression, adjacent protection, aggregate energy and backtracking checks remain unchanged.

All previous 21 renderer tests pass after pipeline compilation; an additional conflicting-measurements/invalid-weights regression passes. No test yet verifies enabled full pipeline behavior or encoded improvement. Four sweeps are a bounded experiment, not a convergence guarantee. New frozen candidate .build/review-v33/local-pulse-composition-v49-temporal-fit; encoded quality and runtime require evaluation before any default change.

V49 enabled integration passed (76.316s); encoded LEGO/control exports, independent scores and media checks terminal-success. LEGO161 RMS 0.035360376462910764 EV, main jump 0.1278928406507625 EV. Control foreground RMS worsens V45 0.0268974287654 to 0.0270848196230; background improves 0.00138091872024 to 0.00129719164322 but background p95 worsens 0.0262707913930 to 0.0264836663520. Main-scene wider proposal rejected at all backtracks: one protected row still worsens at quarter/eighth steps, and the safe sixteenth step does not meet 10 percent improvement. Soft weighted direct temporal fitting is insufficient; no promotion. Need exact per-row protected residual inequalities within the fit, with original frame/node bounds and supported variable set, rather than only soft objective terms followed by global rejection.


### V50: protected-row projection (experimental, off)

Extracted the neutral-EV observed-footprint Jacobian from the renderer fit, preserving its guide weights and radiance sampling. Added boundedMeasurementProjection: project a linearized measured error onto a permitted interval, with each variable clipped to its original box budget. Saturation can make constraints infeasible; this helper does not assert feasibility and the caller must remeasure.

FRANKLUMA_PULSE_PROJECTION=1 (joint/dense/bounded required) projects violated adjacent constraints using their true temporal coefficients and sampled renderer derivatives. It changes only map nodes on source-certified variable frames for that query, applies neutral changes to all RGB EV channels, and retains each channel's original total budget. Twelve sweeps in sorted query order remeasure actual nonlinear residuals each time. Allowed error is min(last accepted error, initial phase error) + 0.001 * Strength; projection aims slightly inside that bound for numerical margin. Original nonlinear acceptance, aggregate adjacent preservation, wide energy threshold and backtracking remain mandatory. This is bounded feasibility repair, not a proven constrained optimum or guarantee of convergence. Strong clipped/nonresponsive footprints abstain. New default-off gate recorded by benchmark metadata.

Candidate is isolated from V49 soft block-coordinate fitting (TEMPORAL_FIT=0) and spatial prior/significance remain off. No encoded V50 result yet. New tests cover neutral-node finite differences, measurement projection and deliberately infeasible saturated bounds, in addition to previous renderer regressions.

V50 renderer regressions all24 pass (17.949s). Enabled wide-only integration terminal-success; projection diagnostics show the branch runs, though this synthetic case has zero protected violations and does not prove repair of the real LEGO conflicts. Frozen native runner built successfully. LEGO and local-moving exports are live with exact handles in validation-jobs.json; no encoded scores yet.

V50 encoded validation terminal-success. LEGO RMS 0.03523736801564973 EV, jump 0.12168106901827172 EV: better V48b/V49 but worse V45 jump 0.11984201698687874. Control background RMS 0.00138091872024 to 0.00171286968102 (regression), foreground 0.0268974287654 to 0.0269826387239 (regression). Media exact checks pass. Projection repairs some accepted main-scene steps; this does not establish clean-reference quality and is not promoted. V51 isolated combination adds existing source-significance gate, using exact same V50 frozen binary/source, with separately recorded runtime configuration. Encoded validation required.

V51 projection/significance encoded LEGO/control exports and media verification terminal-success. LEGO161 RMS 0.03543762800818029 EV, main jump 0.12615226976560373 EV. Control background RMS improves versus V45 0.00138091872024 to 0.00118730698763 and p95 0.0262707913930 to 0.0260076308940, but peak adjacent worsens 0.00656146359972 to 0.00677598012969; foreground RMS worsens 0.0268974287654 to 0.0271067338511. Significance reduces V50 control regression but is still mixed and gives no default promotion evidence. General-video and partial-slider validation next.


### V52: small source-meter footprint (experimental)

Source-flow geometry retains the wide 6-12 pixel descriptor, reciprocal per-pixel flow, displacement bounds and original stationary camera/donor prerequisites. Default-off FRANKLUMA_COMMON_PULSE_SMALL_FOOTPRINT=1 changes only rejected-query transported photometry to 3x3. All nine observed pixels must be valid/unclipped; contiguous held folds each have two pixels, tolerance is capped at 0.02 EV, and every interior pixel including center is validated. These transported measurements remain queries and never enter the donor bank. The small sample size may still miss deformation or produce unreliable confidence; wider geometry does not guarantee photometric identity. No source-only or encoded coverage/result claim yet.

34 existing CommonIllumination tests pass (7.562s), plus a new small-footprint test verifies constant exposure, clipping rejection, held disagreement and changed center rejection. No new UI mode or slider. Candidate remains off. Frozen source-only audit build: .build/review-v33/small-meter-v52.

V52 source-only audits terminal-success. {'oldQualified': 36, 'smallQualified': 26, 'smallAdditionalLocations': [(188, 20, 92), (188, 32, 62), (188, 38, 20), (188, 44, 44), (188, 158, 80), (188, 158, 86), (189, 26, 38), (190, 14, 32), (190, 20, 68), (190, 32, 56), (190, 32, 86), (190, 56, 44), (190, 62, 68), (190, 68, 38), (190, 152, 56), (190, 158, 80)], 'combinedLocations': 52, 'motionQueries': 79, 'motionQualified': 15, 'limitation': 'Source-only photometric qualification; donor-corroborated correction coverage and encoded quality not proven'}
Current source follow-up V52b changes SMALL_FOOTPRINT from replacement to fallback: retain transported larger-footprint measurements when accepted; try strict 3x3 only otherwise. This is not the frozen V52 behavior and needs a separate source/encoded run. Accepted fallback clears stale diagnostic rejection. No default promotion.

V52 source-control follow-up classifies the middle query centers against the independent foreground mask: 13 background, 2 foreground. Center classification is limited and does not prove endpoint identity or donor support. Evidence: small-meter-v52/motion-qualified-region-review.json. V52b frozen native runner built and LEGO/control encoded exports are live with handles in validation-jobs.json. Configuration isolates fallback relative V45, with all V46-V51 experiments explicitly off. No encoded result claim yet.

V52b fallback encoded exports/scoring/media terminal-success. LEGO161 RMS 0.03531898514342842 EV; main jump 0.12661081953799375 EV. Control foreground RMS 0.0268974287654 to 0.0269114392608; background 0.00138091872024 to 0.00138496287678, both slightly worse than V45. Full metric and media report in V52b review-report.json. More source measurement locations do not establish better output; not promoted.


### V53: actual scene/global diagnosis before pulse refinements

Frozen V52b real runner, CONFIDENCE_TARGETS=1, PULSE_COMPOSITION=0, PULSE_DETAIL=0, --patch-check --diagnostics, no export. Terminal-success. Actual tracked main-scene patch corrections at frames187/188: -0.15795794471217883 and -0.0024954613575910215 EV, a +0.15546248335458782 EV gain step. Patch pool has104 tracks; several frames have direction disagreement/broader overshoot reduction. This is evidence against simply raising global gain on this clip, not proof of which individual patches are correct.

Same-coordinate analysis-grid review (not held-motion or encoded validation): the 13x13 region centered(54,38) darkens -0.75353 EV; combined local/brightness correction adds only +0.00345 EV between187/188 on top of global +0.15546. Region(54,30) similarly darkens -0.66965 EV with only +0.00405 EV local/brightness gain. Other larger residual regions show local/brightness steps +0.002 to +0.024 EV. Thus these regions receive essentially global correction despite strong regional source changes. The surviving error is a spatial metering/identity coverage problem as well as conservative global estimation; scalar controls cannot selectively solve it. Current source measurements still must establish whether those changes are lighting versus reflectance/deformation before correction is authorized.

Artifacts: scene-global-meter-v53/audit-provenance.json and lego-local-gain-review.json, plus frozen harness output and full diagnostics. No new production behavior or promotion. Next experiment should target held source identity and a suitable radiometric response in these missed regions, with independently lit/material-change controls.


### V54: source spectral luminance response (diagnostic only)

Added pulseSpectralLuminancePixels. Three positive diagonal source-RGB basis gains predict middle-frame luminance from component-wise geometric endpoint interpolation using actual time alpha. Gains are fitted by unregularized three-variable least squares with pivot rejection for unidentifiable bases and bounded [0.25,4] coefficients. Reciprocal contiguous folds must predict held luminance within tolerance and agree on every footprint pixel. Full interior and maximum pixel errors are checked. Diagnostic reports spatially varying per-pixel exposure and integrated representative exposure, not an authorized scalar correction. All source channels must be finite, positive and below clipping; dark luminance abstains.

This is a model hypothesis, not proof of illumination identity. Material or reflectance changes can fit a luminance-only RGB model; independent geometry and donor/event evidence are still required before any correction integration. No correction code consumes this model. FRANKLUMA_COMMON_PULSE_SPECTRAL_DIAGNOSTICS=1 only prints evaluations on reciprocal-flow footprints rejected by the original source query meter. Small-footprint fallback is off in this isolated diagnostic.

All37 CommonIllumination tests pass (7.307s), including held material-dependent spectral changes rejected by the constant-luminance model, changed interior rejection, unidentifiable basis rejection, and VFR exposure preservation. Frozen source-only candidate spectral-meter-v54; real source coverage not yet measured.

V54 LEGO source audit terminal-success: 564 spectral evaluations, zero accepted, including zero at frame188. Rejections: unidentifiableSpectralBasis283 (this label also includes out-of-bound gain fits), invalidSpectralShapeTimeOrRGB221, nonuniformHeldSpectralResponse44, darkSpectralLuminance16. This hypothesis adds no usable LEGO coverage and is not integrated into correction. Full snapshot spectral-meter-v54/lego-spectral-snapshot.json. Motion-control audit remains live at last poll; exact handle90672 recorded.

V54 motion-control source audit subsequently terminal-success: {'queries': 75, 'accepted': 0, 'rejections': {'unidentifiableSpectralBasis': 73, 'nonuniformHeldSpectralResponse': 2}}. Neither source audit changed correction behavior.


### Independent Astra review and sampling diagnostic follow-up

Astra review identifies a metrology mismatch: middle pixels are integer samples while endpoints use bilinear transported sampling; reciprocal closure does not equalize their effective spatial filters. Production and source audits use Lanczos analysis reduction. Original raw source support must remain disjoint when testing any filtered held prediction, including every fractional interpolation tap. Filtering cannot establish material identity, and zero/fractional transport plus intentional material-change controls remain necessary.

Added reusable fixed-coordinate source-only audit_antialiased_meter.py. It checks disjoint integer raw support for reciprocal folds and compares raw5x5 versus radius1 Gaussian5x5 centres spaced2. It refuses evidence overwrite and hashes inputs/tool. These are different physical extents and there is no flow/donor/correction integration. At LEGO188, filtered measurement qualifies one original rejected location (98,80); raw qualifies0 on the same query list. This preliminary result does not demonstrate the proposed transported filter mechanism.

Negative-support diagnostic in spectral-meter-v54/negative-support-diagnostic.json: main regions(108,76) and(108,60) include negative RGB and even negative luminance across186/188/190. Minimum luminance around(108,60) ranges -0.0208 to -0.0293, invalidating logarithmic samples. This can arise from conversion or resampling, and current evidence does not isolate the cause. Source ffprobe only reports yuv420p; colour space/primaries/transfer tags are absent in that probe output. Do not assume a specific source gamut or silently relax clipping. Next bounded source-only ablation should compare positive prefiltered analysis reduction against current Lanczos, retaining unfiltered geometry/material checks, before any correction integration.

Astra also notes smoothTargets uses a trimmed moving target on shots <=4*radius; main LEGO13-frame scene satisfies this condition. A separate target-branch audit is warranted, but changing the temporal target cannot recover missing regional measurements by itself. No correction improvement or promotion claimed from this review.


### V55: source-only analysis reduction ablation

SourcePulseDetailAudit optionally uses FRANKLUMA_DETAIL_ANALYSIS_PREFILTER=1: clamped-edge Gaussian prefilter at radius 0.5 times the maximum source-to-analysis reduction factor, then Core Image bicubic reduction with B=1,C=0. Final analysis dimensions and source timing remain the same. The default path is unchanged production Lanczos. Apple exposes B/C parameters in its typed bicubic filter API: https://developer.apple.com/documentation/coreimage/cifilter-swift.class/bicubicscaletransform%28%29 . This experiment changes analysis samples and therefore would change geometry estimates if used in audit mode; it is not production-parity validation. First use dump-only mode and compare source radiometry at fixed original source query locations. No clipping-rule relaxation, app processing change, encoded output or improvement claim. Build frozen in analysis-prefilter-v55.


V55 source dumps and fixed-coordinate comparison complete. LEGO13 frames retain identical source PTS/dimensions: original negative RGB samples11474 and negative luminance863; alternative both0. On the original rejected frame188 query list, raw5x5 fixed-coordinate qualification rises0 to51; additional downsampled Gaussian-spaced measurement gives16. Four passing raw-prefilter queries in x96..122/y50..90 include(98,50),(98,74),(104,62),(110,86). This is not donor-corroborated transported or encoded quality evidence.

Motion-control dump comparison at original rejected query locations, restricted to points with original flow geometry support: baseline fixed-coordinate meter qualifies0, prefiltered qualifies20 background-centered and1 foreground-centered. Source masks classify center only, not endpoint/kernel identity. Full report motion-fixed-meter-review.json. Existing original geometry support is historical membership, not a remeasurement of transported filtered taps. Filtering can conceal changes; material-change/occlusion controls and measured filtered renderer gain must be validated before correction integration. No default promotion. Source-only evidence materially supports investigating the analysis reduction, but does not establish an improvement to exported video.


## V56: separated prefiltered metering — encoded experiment in progress

The current opt-in `FRANKLUMA_PULSE_ANALYSIS_PREFILTER=1` path retains an additional positive-filter analysis raster while preserving the original detail image for geometry. Scene/sample copying preserves the optional meter. Donor and transported source photometry can use that raster; descriptor matching, optical flow, renderer fitting and actual field-gain evaluation continue to use the original detail raster. Default behavior is unchanged.

The tracking suite passed 48 tests, and the focused transport contract passed after adding assertions that an alternative meter changes sampled radiance without changing transport positions, cannot rescue failed geometry or inconsistent flow, and rejects mismatched dimensions. The immutable source/binary/configuration snapshot is `.build/review-v33/separated-meter-v56`. Native exports are being evaluated for LEGO and the independent-clean-reference local-moving case before any quality claim.

This is an ablation, not independent certification: globally prefiltered raster samples have overlapping source support across nominal held folds, and the fitted/raw rendered footprint does not have the same effective filter as the source meter. More qualified measurements therefore do not prove trustworthy new correction coverage. Any promotion needs disjoint native-pixel supports, matching rendered-gain measurement, material/occlusion and intentional-light controls, partial-slider checks, and encoded regional-tail evaluation. The extra optional meter also doubles detail-raster retention; mobile and long-video processing need bounded storage.

### V56 first encoded results

LEGO retained 212 frames, the same 14 cut positions, exact presentation times and packet durations, dimensions and audio. On the same 161 independently source-selected matched transitions, RMS was 0.0349911856519 EV versus V45 dense 0.0351745573173 (0.52% lower). The 187→188 jump was **0.126110778873 EV versus 0.119842016987 (5.23% worse)**. More filtered support did not resolve the important flash.

At full Strength, the 72-frame independent-clean-reference local-moving control had foreground RMS 0.0269008491299 versus V45 0.0268974287654 (essentially unchanged/slightly worse); background RMS improved 0.00138091872024→0.00121491103409, but worst tile error worsened 0.0789197171678→0.0798633399068. At Strength 0.5, foreground RMS improved 0.0179529909261→0.0178100497448, while background RMS worsened 0.00336079951088→0.00342947838269; background p95, peak adjacent and worst tile errors also increased. Both control exports preserve timing and geometry. These are distinct mixed outcomes, not a single combined improvement.

The native logs show filtered transport at LEGO scene-start 15 s/middle-frame 8/interval 2 qualified and corroborated 21 queries, yet phase-two full-field proposals still violate protected adjacent rows and backtrack. This gives a concrete next investigation: match source-meter and rendered-gain kernels and retain disjoint native-pixel validation before treating the added queries as trustworthy constraints. Do not relax adjacent protection or promote a blurred meter to manufacture a better scene-average score. Fox evaluation remains in progress in the V56 job manifest; no Fox result is asserted here.

V56 Fox completed: 600 frames, expected cuts [200, 400], timing/dimensions preserved; independent scoring supports 597 transitions. RMS 0.0101047288325 EV versus V45 0.0101368806912. All four V56 exported-media checks pass. The mixed LEGO/control results still preclude promotion.


## V57: finite-kernel photometry and matching renderer response

The new opt-in `FRANKLUMA_COMMON_PULSE_KERNEL_METER=1` fallback follows every tap in an 11×11 raw-detail region through the original flow/geometry gates. It forms a 5×5 grid of stride-two, positive separable [1,2,1]/4 features. Training/held supports are explicitly expanded to original integer raster pixels, including every nonzero bilinear corner in all three frames; overlapping folds are rejected. Averaging cannot rescue clipped or negative raw taps. Original accepted 5×5 measurements and original donor selection remain unchanged. The globally prefiltered V56 raster is disabled for this experiment, and this kernel path is not enabled when an alternative photometry raster is supplied.

Source excursion now uses the total luminance over exactly the valid weighted features, with an additional consistency check against the source held-fold median. Repeated taps, validity masks and positive weights propagate through row-gain measurement, fit Jacobians, dense fitting and the optional temporal/projection solvers. Each nonlinear renderer response is applied before weighted radiance is accumulated. This avoids comparing a filtered source meter with an unfiltered rendered-gain footprint. It adds no retained full-frame meter raster.

Tests cover VFR exposure, fractional source supports, deliberate overlapping endpoint supports, material change, clipping, weighted nonlinear output, node derivatives and fitted increments. The derivative test exposed highlight-kink bias in the old global finite-difference step; genuinely weighted kernels now use a smaller response step while all-one/default footprints retain the existing step. The 26 kernel/renderer tests and the additional weighted-fit contract pass. V56's earlier core regression suite finished with 104 tests passing before these V57 changes.

Frozen source, binary and explicit environment are at `.build/review-v33/finite-kernel-meter-v57`; LEGO and independent-clean-reference local-moving encoded evaluation is in progress. Geometry/donor support and source tests establish a more coherent measurement contract, not proof of real-video improvement. Do not promote before independent encoded results, material/intentional-light controls and partial-slider checks. The inherited raw raster can itself contain Lanczos artifacts; requiring nonnegative unclipped raw taps may still leave the troublesome LEGO regions unsupported.

V57 encoded validation completed for LEGO and local-moving. Both media checks pass. LEGO has the same 212 frames/cuts and audio; 161 matched transitions give RMS 0.0351744055290 EV versus V45 0.0351745573173, an effectively negligible change. The important 187→188 jump is exactly the V45 0.119842016987 EV. Local-moving full-resolution clean-target scores are identical to V45. Logs total 103 newly kernel-qualified queries and eight corroborated queries over LEGO; the main frame-188 interval has no added support, while one added query appears at frame 189. Local-moving has zero added qualified/corroborated kernel queries. This fixes the measurement contract without solving the coverage failure, and is not a perceptual-improvement claim.

These disjoint supports are pixels of the **192×112 analysis raster**, not original video-resolution pixels. The next diagnostic must measure the unsupported region at higher/native resolution with fixed geometry and physically matched supports, and distinguish reduction artifacts from actual material/light-response variation. Raising tolerance or lifting protection is not justified by these results.

V57 half-Strength moving-control export also completed, with clean-reference metrics identical to V45 and timing/geometry preserved.

## V58: higher-resolution source diagnostic

The source-only audit now permits 384×224 and 768×448 dumps, explicitly requiring dump-only mode because production geometry thresholds are not defined at these sizes. Existing 96/192 reduction paths retain the same production raster. Frozen diagnostic code/binary/environment and the original LEGO frames 186–191 are in `.build/review-v33/higher-resolution-meter-v58`.

The fixed-coordinate comparison uses the same normalized 5×5 feature positions/extent at 192 and 768, actual source PTS and disjoint integer supports including fractional bilinear corners. All raw taps must be finite, nonnegative and unclipped. On the same 185 frame-188 queries, strict 0.04 EV held/interior qualification rises from **0 at 192 to 14 at 768**. This differs from V56 global blur: it increases analysis resolution while retaining the same physical query extent. The effective reduction filters and tap supports still differ, so it is only evidence that reduction fidelity can affect the measurement failure. It does not prove flow/donor qualification or encoded correction benefit, and 768 is not native resolution. The report and the exact probe are frozen alongside their input hashes. Next: inspect regional coverage and actual transported supports at higher resolution, with clean motion/material controls, before deciding on bounded on-demand native metering.

V58 regional caution: the previously investigated 192-grid box x96–122/y50–90 has no qualified query at either resolution. The 14 higher-resolution qualifications occur elsewhere. This does not establish recovered evidence for the previously investigated regional box.

Next model review: the V54 spectral diagnostic rejects unidentifiable channel gains even when a lower-rank luminance prediction may be observable on held material samples. Review rank-aware prediction in the supported RGB subspace (explicit null-space uncertainty, disjoint held folds and changed-material controls) before considering any correction; do not infer RGB channel gains from a rank-deficient basis or mistake a prior for measured information. V58's (116,62) held error remains about 0.25 EV at higher resolution, so reduction alone does not explain that nonuniform response. This is a candidate diagnostic investigation, not an accepted model change.


## V59: rank-aware spectral prediction diagnostic

The diagnostic can fit a supported luminance prediction in a lower-rank RGB subspace while leaving channel gains unknown. It explicitly bounds omitted-direction prediction uncertainty over the declared [0.25,4]^3 gain box, rejects unseen held material directions, and retains contiguous held/interior and prediction-agreement checks. A neutral coefficient anchor selects a representative fit but is not evidence for unobservable channel gains. Tests pass for rank-one/rank-two prediction, unsupported held materials, interior replacement and VFR ramps; default full-rank diagnostic behavior is retained.

Native source evaluation with unchanged V54 geometry/photometry produced **zero accepted models** out of 564 LEGO and 75 local-moving evaluations. LEGO now distinguishes 60 unsupported predictions, 49 held-response failures, 218 unsupported fits (the inherited rejection label is unidentifiableSpectralBasis), 221 invalid/clipped supports and 16 dark supports. Rank deficiency alone therefore does not resolve the source failure. No correction path consumes this model. Frozen inputs, native binary, explicit configuration and source reports are in `.build/review-v33/rank-aware-spectral-v59`.

## V60: independently supported low-texture queries — encoded evaluation pending

A fixed-coordinate frame-188 diagnostic found 18 smooth, colour-stable background candidates, largely in the upper-right blue backdrop. The source matcher requires textured identity, so these cannot establish local correspondence or become illumination donors. The opt-in `FRANKLUMA_COMMON_PULSE_LOW_TEXTURE_QUERIES=1` experiment instead permits them only for brackets where existing textured anchors already establish a stationary camera across the image.

Each query checks a full 13×13 nonnegative/unclipped raw support, low spatial log-channel variation and stable luminance-normalized colour. Its 5×5 center must pass the existing held/interior neutral-exposure checks. Source excursion and rendered gain use the same observed luminance aggregate. Queries never enter the donor bank and require the existing independent, disjoint textured-donor quiet/event clock before correction. Adjacent and wider brackets carry these explicit footprints into the existing bounded fits, actual renderer checks and backtracking. Stationary-camera certification is inherited from the existing >=12/spanning-half-image/60%-of-eligible anchor test; no camera warp is introduced.

Five focused low-texture/spectral contracts pass, including absent-camera rejection, occlusion, changed chromatic material and a preserved linear VFR ramp. The quiet-clock test establishes that a strong local appearance change is not authorized by a quiet external event clock. These tests do not establish real-video quality or address intrinsically indistinguishable same-colour material replacement. Frozen native export evaluation is at `.build/review-v33/low-texture-queries-v60`; the experiment remains disabled by default. No new UI mode or slider is added.

V60 encoded results contradict promotion: on the same 161 LEGO matched transitions RMS is 0.0353382043262 EV versus V45 0.0351745573173 (0.47% worse), and the 187→188 jump is 0.127022819884 versus 0.119842016987 (5.99% worse). The moving clean-reference control improves background RMS 0.00138091872024→0.00136756379907 but worsens foreground 0.0268974287654→0.0269724396036. Timing/dimensions and LEGO audio are preserved. LEGO logs have 345 low-texture qualifications/179 corroborations; local-moving 666/518. These counts do not imply independent events or visual benefit.

Coverage imbalance is explicit: LEGO frame187/interval1 has zero low-texture qualifications, frame188/interval1 has two and zero corroborations, frame188/interval2 has 17/17, and frame189/interval1 has 22/22. Frame187/interval2 has no stationary-certified bracket. Thus a wider-window response at 188 can be acted on without comparable smooth-background evidence at the preceding brighter frame. The existing adjacent protection still rejects broad proposals; do not loosen it to improve a headline median. A fixed-coordinate frame187 texture/chroma diagnosis is recorded separately to distinguish rejection causes before changing the support model or solver. V60 remains disabled by default.

## V61: independent channel clocks — no encoded improvement

Smooth-background queries can now require separately measured RGB donor clocks, without treating an unmeasured channel as known or applying new RGB correction gains. The source contracts reject changed chromatic material, same-colour intrinsic brightening during a common lighting event, insufficient donors and missing channels. The integrated stationary-camera callback test also accepts supported global coloured lighting and rejects concurrent local intrinsic brightening. This remains opt-in.

Frozen exports and scores are in `.build/review-v33/colour-clock-queries-v61`. Both media checks pass. LEGO RMS is 0.0353407939467 EV over the same 161 transitions, worse than V45 0.0351745573173; the important jump remains 0.127022819884 EV. Moving foreground RMS worsens to 0.0269404526359; background RMS 0.00138019095984 is only marginally below V45. Two supported adjacent low-texture measurements at frame187 are recovered, and its fitted map changes, but the encoded flash does not improve.

The main LEGO scene has 204 source keys solved with zero residual/limit rejections. Therefore an early temporal cap is not the demonstrated blocker there. Large subsequent spatial-fit proposals reduce wider-bracket residual energy but violate actual adjacent-frame protections; only a small backtracked step is accepted. Added measurements alone do not solve this coupling.

## V62: constrained joint field fit — encoded evaluation pending

The opt-in joint fit solves temporal residuals directly in the renderer node variables instead of independently fitting frame proposals. Only nodes in source-certified middle-frame footprints are authorized. Variable bounds retain the original total neutral-gain budget and a per-step trust region. Sparse linearized residual constraints protect individual rows and aggregate adjacent-frame energy; all proposals still pass the unchanged nonlinear renderer checks and backtracking. Unsupported nodes receive no inferred correction.

Four focused contracts pass: coupled field solution and source bounds, aggregate adjacent protection/invalid inputs, the integrated channel-clock query pipeline, and weighted nonlinear renderer/Jacobian agreement. These establish solver contracts, not encoded quality. The baseline V45 configuration plus only `FRANKLUMA_PULSE_JOINT_FIELD_FIT=1` is frozen at `.build/review-v33/joint-field-fit-v62`; native build/export evaluation is underway. No default or UI change is authorized by these tests.

V62 first encoded results: LEGO preserves 212 frames, cuts and audio. The same 161 transitions yield RMS 0.0351504441613 EV (V45 0.0351745573173, about 0.069% lower); frame187→188 is 0.118768244346 EV (V45 0.119842016987, about 0.90% lower). This is small numerical progress, not proof of a visible fix. Moving-control clean-reference metrics are exactly unchanged and its media check passes. The main LEGO scene first falls back when the joint solver is unavailable, then accepts two joint-fit passes under actual nonlinear protection. Fox, CC0 Teja and half-Strength moving-control evaluations are pending; default remains off.

V62 control qualification: local-moving logs report the joint proposal unavailable on all three passes; unchanged scores therefore establish fallback parity, not that an active joint solve handles moving subjects. Distinguish active-fit evidence from fallback when reviewing subsequent cases.

V62 CC0 Teja validation completes with 534 supported transitions, RMS 0.0138588181613 EV versus V45 0.0138665788012 (about 0.056% lower), with media verification passing. Half-Strength moving control gives exact V45 metric parity (foreground RMS 0.0179529909261; background 0.00336079951088) and preserved media. These tiny real-video differences do not demonstrate removal of visible flashes. V62b freezes failure-reason logging and an exact field width/height topology guard; its non-exported motion-control diagnostic is running to distinguish solver residual failures from source/budget availability.

V62 Fox evaluation completes: 597 supported transitions, RMS 0.01013688069122 EV versus V45 0.0101368806912. Media verification passes. All V62 evaluation jobs are terminal.

V62b establishes that the moving control has 160,983 authorized node variables and 27,277 rows. At 400 iterations, the three linear violations are 8.25917e-5, 2.56817e-5 and 1.40987e-5 EV, exceeding the retained 1e-5 rejection threshold. This is convergence-limited fallback, not absent source evidence.

## V63: restore finite-iteration feasibility — encoded validation pending

An opt-in feasible-step restoration intersects the ray from the valid zero increment to the box-clamped iterate with every residual box and the exact adjacent-energy ball. It scales toward the unchanged current field, never enlarging source/row/energy budgets. A direction that cannot preserve a quiet adjacent group returns zero, and unchanged nonlinear checks still govern acceptance. The feature is separately gated by `FRANKLUMA_PULSE_JOINT_FEASIBLE_STEP`. Three solver contracts pass, including a deliberately one-iteration infeasible fit whose restored step preserves all constraints while reducing the objective and a quiet-frame direction that must become zero. This does not prove real-video improvement. Frozen source/environment at `.build/review-v33/feasible-joint-field-v63`; native build is in progress.

V63 encoded results reject promotion. LEGO's same 161-transition RMS is 0.0352524456565 EV and its main jump 0.123489941526 EV, both worse than V45 (0.0351745573173 / 0.119842016987). Motion foreground RMS becomes 0.0269136252051 (V45 0.0268974287654), background 0.00165536945541 (V45 0.00138091872024, about 19.9% worse). Background peak adjacent error increases 0.00656146359972→0.00770964467627. Its foreground peak adjacent error improves slightly, but that cannot offset the background regression. Both media checks pass. Active motion-control joint fits use feasibility scales 0.859, 0.796 and 0.020; this is actual-fit evidence rather than fallback parity. LEGO's first main-scene joint pass is active, then the next direction has no positive feasible step and is rejected.

Mathematically feasible fit-row residual improvement is therefore insufficient for perceptual/general-region quality. Before promoting a joint fit, investigate independent source-certified quiet-region protection rows and spatial response coverage, retaining brightness/scene boundaries, clean motion and intentional-light controls. Guard/partial-slider batch is running. No inference from missing source measurements is authorized, and both joint experiments remain default-off.

V63 additional guards: clean no-flicker-motion scores are exactly unchanged despite active joint fits (first fit 173,965 variables/32,577 rows). Intentional-ramp foreground RMS improves 0.00852143673195→0.00840883078994, but background worsens 0.00413438419893→0.00421877495172; background peak adjacent error rises 0.0107463722336→0.0115097310047. Both media verifiers pass. Intentional lighting cannot be claimed fully protected by the fit-row constraints. Half-Strength and half-Spatial exports are still running in the same sequential batch; do not restart completed guards or infer slider quality from full-Strength results.

V63 slider evaluation is terminal. Half-Strength motion control improves foreground RMS 0.0179529909261→0.0178447912311 and background 0.00336079951088→0.00279073286197 against its independent partial target. This does not transfer to LEGO: same half-Strength settings give V63 RMS 0.0576583740558/jump 0.214756329909 versus baseline 0.0576147543409/0.212839330647, and both leave more residual flash than full Strength. Half-Spatial motion control improves foreground slightly (0.0259689128852→0.0258774154167) but worsens background (0.0771598953288→0.0774037743895), measured against the same full clean target. That target is not a declared half-Spatial desired-output model; only the same-setting baseline/candidate comparison is justified. All media verifications pass. All V63 exports/scoring are terminal.

## V64: separate quiet-source protection — encoded validation pending

Source-qualified stationary low-texture queries with strict unchanged normalized colour and |source excursion| + 2×held error <=0.005 EV can now supply protection-only footprints independently of an external event clock. They never become illumination donors, source correction rows or authorized node variables. The integrated query test passes for an independently quiet patch during a common coloured event, while rejecting local intrinsic brightening and absent stationary-camera support. This is inherited stationary support supplied explicitly in the synthetic test, not a new camera certification test.

The opt-in joint bridge records the current field's quiet-footprint temporal response at the beginning of phase2 and constrains subsequent change within a reserved 0.0005×Strength EV linear budget. Every actual nonlinear proposal, including fallback, must remain within 0.001×Strength EV of that same baseline; protection does not accumulate across passes. Guard derivatives use only already-authorized event nodes. These guards preserve existing response on observed quiet regions; they do not infer unknown lighting or repair earlier baseline errors. `FRANKLUMA_PULSE_QUIET_SOURCE_GUARDS` requires the joint-fit flag, remains default-off and introduces no UI control. Combined bridge compilation/contracts are running; no encoded-quality claim. Frozen current source/environment is at `.build/review-v33/quiet-source-guards-v64`.

V64 combined compilation/contracts completed: four focused tests pass. The frozen native audit build is running; encoded evidence is still outstanding.

V64 encoded evaluation completes. LEGO RMS 0.03525244565653 EV/main jump 0.1234899415263; the main scene has zero qualifying quiet low-texture guards. Motion control has 648 guard footprints but no additional nonzero gradient constraints on event-authorized variables (joint row count remains 27,277), and scores exactly match V63, including its background regression. Both media checks pass. Protection-only source testing passes with event-query mode disabled and rejects equal-luminance colour replacement. No promotion.

V64b extends protection to independently RGB-stable textured source footprints. Existing endpoint/correspondence gates remain; every channel must pass strict 0.0025 EV reciprocal held/interior checks and max channel excursion + 2×held error <=0.005 EV. Only exact 5×5 raw-source coordinates are supported (no fractional refinement or separate meter raster); opposing colour changes cannot qualify through quiet aggregate luminance. These rows remain protection-only and cannot authorize variables. A test covering quiet textured material during external lighting and changed material is running. Encoded evidence is outstanding.

V64b integrated source protection contract passes, including textured quiet support and changed-material rejection. Native audit build is still pending.

V64b encoded evaluation completes. LEGO RMS 0.03525244559396 EV/main jump 0.1234899415263, unchanged from V63/V64; no main-scene quiet guards qualify. Motion has 25,479 quiet guards and 52,033 joint rows (active derivatives now overlap event-authorized nodes). Foreground RMS 0.0270100030550 and background 0.00139358901540 are worse than V45 0.0268974287654/0.00138091872024. Background peak adjacent error improves to 0.00640664851507 from V45 0.00656146359972, and background RMS regression shrinks substantially versus V63's 0.00165536945541; that mixed result cannot establish promotion. Both media checks pass. All V64b evaluation jobs are terminal.

## V65: source agreement intervals — validation pending

The opt-in joint source-interval objective minimizes squared distance outside each source row's held/interior agreement interval instead of forcing uncertain residuals to an exact point. Interval width is source held error × Strength × Spatial; this is an operational model-agreement width, not a calibrated confidence probability. No missing evidence is invented. Protection-only rows keep zero objective weight, and all row/source/adjacent-energy constraints and nonlinear acceptance checks remain unchanged. The convex ADMM residual proximal step handles the interval objective together with residual boxes and the adjacent-energy ball. Zero tolerances retain the previous solver path. `FRANKLUMA_PULSE_JOINT_SOURCE_INTERVAL` remains default-off. Solver contracts are running; no encoded evidence yet.

V65 four solver contracts pass after separating interval convergence from exact zero-energy ray restoration. The first combined fixture expected a nonzero restored direction in an exactly quiet aggregate; restoration conservatively returned zero for its finite-precision unconverged direction. The interval test now checks the coupled solver's reported residual tolerance independently, while the existing restoration fixture retains strict quiet rejection. This numerical limitation remains: a zero-energy group can prevent an approximate coupled ray from making progress; no constraint is relaxed to avoid it. Native candidate source/environment frozen at `.build/review-v33/source-interval-joint-fit-v65`.

V65 encoded evaluation completes and rejects promotion. LEGO RMS is 0.0353150277729 EV/main jump 0.125212613021 EV (V45 0.0351745573173/0.119842016987), worse than both V45 and V64b. Motion foreground RMS worsens to 0.0270772456874; background improves to 0.00133714826070 (V45 0.00138091872024, about 3.17% lower). Foreground peak adjacent error worsens to 0.119294212547; background peak improves to 0.00615486934667, but background p95 error worsens to 0.0266265959851. Both media verifiers pass. The main LEGO scene again has an active first fit followed by a zero feasible ray and rejected later trials. Treating uncertainty as intervals is mathematically coherent but does not establish real-video quality.

## V66: tighter convergence diagnostic — validation pending

A separately gated solve uses up to 2000 iterations and 1e-10 primal/dual stopping tolerance, rather than 400/1e-7. It changes no source qualifications, objective widths, renderer model, increment budgets or actual acceptance limits. This tests whether finite-iteration directions explain the zero-step barrier; it is not a mobile/performance recommendation or an assumed improvement. `FRANKLUMA_PULSE_JOINT_CONVERGED_FIT` remains default-off. Coupled interval convergence and tolerance validation contracts are running; encoded comparison is outstanding.

V66 tighter fixture initially failed: the inherited inner CG relative residual floor left approximately 1.97e-9 EV coupled error despite a requested 1e-10 outer tolerance. The inner stopping threshold now follows stricter requested outer precision; default 1e-7 calls retain exactly the old CG threshold. Four solver contracts then pass. Step diagnostics now expose primal and dual residuals as well as iteration count and post-restoration constraint violation; these are distinct convergence/feasibility evidence. A final metadata/convergence assertion run and the frozen native build are starting. Source/environment is at `.build/review-v33/converged-source-interval-v66`; no encoded improvement yet.

Goal paused at the user’s explicit request for evaluation. V66 encoded jobs/scoring/media verification are all terminal. LEGO RMS 0.0353136649239 EV/main jump 0.125207152096 EV is nearly V65 and worse than V45/V62. Motion foreground RMS 0.0270219883104 is worse than V45 0.0268974287654; background RMS 0.00134815474803 is below V45 0.00138091872024, but background p95 worsens to 0.0269067978664. Main solves still hit 2000 iterations; no convergence or promotion claim.

V67 source work was in progress when the user paused. An optional box penalty of 0.01 changes numerical conditioning without changing objective/constraints. The solver now reports/stops on the proper ADMM dual residual AᵀΔz + boxPenalty×Δv, and reports maximum iterate change separately. Earlier V66 logs labelled the latter dualResidual; interpret those historical labels as iterate-change diagnostics, not KKT residuals. Five focused tests passed, including analytical solution, source bounds, unknown-node abstention, tight convergence and invalid penalty rejection. V67 has no frozen native export evaluation and remains default-off. No additional implementation or evaluation jobs will be launched while paused.
