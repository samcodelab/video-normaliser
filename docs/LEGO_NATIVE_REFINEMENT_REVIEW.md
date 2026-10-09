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
