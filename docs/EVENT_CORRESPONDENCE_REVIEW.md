# Event-centred correspondence review

Implemented `SurfaceTracking.trajectoryThrough`: seed a surface at the frame under examination and follow it independently backward and forward using the existing reciprocal match checks. Stop each direction at a cut or uncertain match. This recovers surfaces that were occluded at an interval's start without joining histories across occlusion. No image pixels are warped, blended or replaced, and the helper is not yet used by the automatic correction pipeline.

The persistent RGB diagnostic accepts `--anchor-event` to compare this sampling strategy with its original interval-start strategy. Both still require at least four tracked frames, support before/during/after the event, and the same spatial RGB consistency checks. More qualifying tracks would not by itself establish correct surface identities or clean-light targets.

## Results

Retained V62 source thumbnails, same 66 seed positions per anchor frame and previous intervals:

| Event | Original pulse / step qualified | Event-centred pulse / step qualified |
|---|---:|---:|
| LEGO 188, interval 184–192 | 0 / 0 | 0 / 0 |
| Fox 559, interval 550–566 | 5 / 2 | 5 / 2 |

Event-centred LEGO has 49 insufficient-persistence cases, eight dark/clipped cases and nine nonuniform pulse responses. Its pairwise measurements also reject ten uneven responses and seven dark/clipped cases. Fox has 22 insufficient-persistence cases; the qualified footprint counts do not improve. Seed coordinates are taken from different frames, so this is a coverage comparison, not a per-surface improvement claim.

Three synthetic controls, interval 28–44 at frame 36, 12 fps:

| Control | Pulse qualified | Step qualified |
|---|---:|---:|
| Clean moving subject | 58 | 58 |
| Local flicker with moving subject | 16 | 7 |
| Intentional lighting ramp | 58 | 58 |

In particular, an intentional ramp has extensive measurable response. Measurement acceptance is not permission to suppress that response. The correction target must still distinguish intended lighting from flicker, and respect Strength, Spatial and Colour controls.

The starting frame was a real diagnostic coverage limitation, but changing it does not solve the main LEGO flash. We should not promote this as a quality improvement, weaken consistency thresholds, or increase smoothing based on these counts. The next model investigation remains regional RGB response on reliably corresponding surfaces, distinguishing spatial light mixtures from changing material, occlusion and specular reflection. Earlier high-resolution experiments already showed that resolution alone did not recover the problematic LEGO region; repeating a general resolution sweep is not justified.

## Evidence

Frozen core sources, diagnostic source/binary, input hashes, JSON reports and stdout are retained in `.build/review-v35/event-correspondence`. These are thumbnail and retained-field diagnostics, not new exports. No media was promoted and automatic correction defaults remain unchanged.

Two new tests verify recovery after earlier occlusion, cut boundaries, exact translated coordinates and retained RGB exposure measurements. All 50 tracking tests passed, including the new cases and existing native guidance and identity protections. Xcode source membership and file references also pass validation.
