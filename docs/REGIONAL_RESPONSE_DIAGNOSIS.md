# Regional response diagnosis after project restructuring

The project now has physical responsibility folders, matching Xcode groups, complete Swift test membership and one source manifest for standalone native correction harnesses. `python3 scripts/validate-project.py` checks source membership and file references against disk.

## Correction changes

Added opt-in quiet-colour gate diagnostics without changing acceptance decisions. Added `CommonIlluminationComponent.stepPixels`, a two-frame RGB response measurement using the existing reciprocal spatial holdout and full-interior checks. This separates a pairwise response measurement from three-frame temporal curvature. It is diagnostic evidence only: uniform material changes can also pass, so persistent correspondence and independent illumination evidence remain necessary before correction.

The persistent RGB audit now reports pairwise step evidence alongside its existing pulse evidence. Both measurements are conditioned on the same persistent trajectory and valid three-frame footprints. This is not a comparison with a less restrictive two-frame tracker.

## Measurements

Using retained V62 fields and source thumbnails, with no field refit or export:

| Clip and interval | Seeds | Persistent geometry failures | Qualified pulse footprints | Qualified step footprints |
|---|---:|---:|---:|---:|
| Fox, frames 550–566, event 559 | 66 | 24 | 5 | 2 |
| LEGO, frames 184–192, event 188 | 66 | 47 | 0 | 0 |

Fox's two qualified step footprints measured RGB exposure changes approximately `[-0.843, -0.694, -1.109]` and `[-0.812, -0.690, -1.116]` EV. Their held errors were 0.022 and 0.035 EV. Neither measurement supplies a clean-light target or sufficient independent donor coverage. Among Fox footprints surviving geometry, 35 failed pairwise spatial uniformity and five had dark/clipped channels. LEGO had ten pairwise spatial-uniformity failures and nine dark/clipped failures after geometry filtering.

The quiet-colour prototype still changes zero frames in both retained clips. Fox gate diagnostics include spatial held-response failures, geometry rejection and insufficient independent donors. “Held” means withheld spatial parts of a footprint; it does not require a temporal return to the original light level. A persistent step can pass these checks when its spatial response is uniform.

These results do not justify lowering thresholds or promoting the prototype. The next correction model work must improve source correspondence and represent regional RGB lighting response on supported surfaces, then validate its proposed gains through the actual renderer. This must include clean-motion controls, intended lighting changes, slider settings below 100%, clipping, and unsupported regions. No new user mode or slider was added, and automatic correction defaults remain unchanged.

## Validation and evidence

- Xcode app and test target compiled; 17 focused Xcode tests passed, including scene detection/fixtures and RGB continuity/evidence checks.
- 30 selected Swift Package tests passed (preview timing, documents, scenes and quiet-colour correction); a later five-test run including the new pairwise evidence check also passed.
- Xcode membership matches all 16 application and 22 test Swift files; every group-relative reference exists.
- The full Xcode run was intentionally stopped during the expensive bundled-demo processing test. This is not a full-suite pass.
- Native audit executables compiled and completed the two diagnostic event runs. No candidate media was promoted or app distribution replaced.

Evidence lives in `.build/project-layout-review/correction`: `provenance.json`, `fox-step-559.json`, `lego-step-188.json`, and `fox-gates` / `lego-gates` reports. Gate stdout is retained in `/tmp/frank-fox-gates.log` and `/tmp/frank-lego-gates.log`. Binary provenance distinguishes the quiet-audit compiled before the later step helper from the persistent-step binary compiled afterward.
