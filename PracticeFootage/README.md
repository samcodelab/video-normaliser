# FrankLuma practice footage

These local videos are deliberately outside the shipped app and are ignored by Git. Keep this attribution with the videos and with shared derivatives. Two downloaded base clips and three generated stress clips are currently in this folder; corrected audit movies are under `.build/practice/`.

## Downloaded base clips

| File | Creator and source | Licence | Local version |
| --- | --- | --- | --- |
| `LanaBanana-first-stop-motion.mov` | LanaBanana (film credits: Lana Genc), [Stop motion animation](https://commons.wikimedia.org/wiki/File:Stop_motion_animation.webm) | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) | Wikimedia's 640×360 MPEG-4 transcode; 16.32 seconds, 25 fps, 408 frames. Paper animation, shadows and scene/credit transitions. |
| `Holodropfilms-stopmotion.mov` | Holodropfilms, [Holodropfilms – stopmotion](https://commons.wikimedia.org/wiki/File:Holodropfilms_-_stopmotion.webm) | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) | Wikimedia's 640×360 MPEG-4 transcode; 23.84 seconds, 25 fps, 596 frames. Outdoor pixilation, moving people/vehicles and camera changes. |
| `Teja-clay-stop-motion.mov` | Teja Silaparasetty, [Stop-Motion Animation (Basic)](https://commons.wikimedia.org/wiki/File:Stop-Motion_Animation_(Basic).webm) | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | Wikimedia's 480×360 MPEG-4 transcode; 597 frames at 29 fps, 20.586 seconds, no audio. Clay and cotton-armature animation with changing shapes and shadows. Licence verified 6 October 2026; downloaded specifically for the v30 review. |

The base clips are useful varied-content checks, not verified examples of extremely bad natural flicker. They are lower-resolution transcodes, not camera originals. No author endorses FrankLuma.

Original download URLs:

- https://upload.wikimedia.org/wikipedia/commons/transcoded/b/b8/Stop_motion_animation.webm/Stop_motion_animation.webm.360p.mpeg4.mov
- https://upload.wikimedia.org/wikipedia/commons/transcoded/8/80/Holodropfilms_-_stopmotion.webm/Holodropfilms_-_stopmotion.webm.360p.mpeg4.mov
- https://upload.wikimedia.org/wikipedia/commons/transcoded/4/47/Stop-Motion_Animation_%28Basic%29.webm/Stop-Motion_Animation_%28Basic%29.webm.360p.mpeg4.mov

## Severe, explicitly synthetic variants

- `LanaBanana-added-exposure-flicker.mov`: derived from LanaBanana's clip with whole-frame exposure changes from −0.55 to +0.50 EV every two frames. Original remains untouched. Use Smooth flicker; compare with Steady scene within the paper-animation shot. Automatic cuts include additional boundaries during the near-black credit transition; review/merge those cuts where appropriate.
- `Holodropfilms-added-local-flashes.mov`: derived from Holodropfilms' clip with a repeating three-frame central flash of −0.80, +0.65 and −0.25 EV plus a contrast change. The radial mask leaves the outer frame less affected. This challenges local correction beside motion. It is not a white-balance or rolling-band test.
- `Holodropfilms-10min-repeat-stress.mov`: the Holodropfilms source repeated/truncated to 600 seconds, without audio, using a passthrough composition. It contains 15,000 video frames. This checks real long-video decoding/export, but not 4K quality, new scene diversity or unique ten-minute production footage.

All four short inputs were analysed and exported successfully on 5 October 2026. Native reanalysis preserved their frame counts, dimensions and source duration (including the slight duration change introduced by generating the synthetic variants). The ten-minute file also preserved all 15,000 frames and exactly 600 seconds through correction/export/reanalysis. Analysis plus correction took 37.66 seconds on this Mac; decoding is included, export is excluded from that timing. These are stability/integrity checks, not an objective score for visual flicker removal.

Open the files in FrankLuma, analyse, choose Side by side and loop a short affected section. Inspect skin, shadows, edges and highlights separately; a flat exposure graph does not prove those surfaces match.

## Reproduce the local audit

```sh
zsh scripts/build-practice-audit.sh
.build/practice/MakePracticeStress PracticeFootage/LanaBanana-first-stop-motion.mov PracticeFootage/new-global-stress.mov global
.build/practice/MakePracticeStress PracticeFootage/Holodropfilms-stopmotion.mov PracticeFootage/new-local-stress.mov local
.build/practice/MakeLongPractice PracticeFootage/Holodropfilms-stopmotion.mov PracticeFootage/new-10min-stress.mov
.build/practice/audit PracticeFootage/new-global-stress.mov .build/practice/new-global --export
```

The audit writes a contact sheet (original left, corrected right), reports automatic boundaries, and optionally exports/reanalyses `corrected.mp4`. Use a new output folder; existing movies are not overwritten. The severe-flash generator is intended for the downloaded 25 fps clips.

## Further research candidates

- [BurstDeflicker authors' repository](https://github.com/qulishen/BurstDeflicker) links to the [BurstFlicker dataset](https://www.kaggle.com/datasets/lishenqu/burstflicker), with flickering input and reference image sequences. It is a useful potential benchmark beyond stop motion. Dataset access/licensing and conversion still need checking; the code licence does not automatically license every media item. It has not been downloaded here.
- [CVPR 2023 All-In-One-Deflicker](https://github.com/ChenyangLEI/All-In-One-Deflicker) links to varied real-world flicker collections. Individual source rights must be checked before including footage in an app, screenshots or public examples. No models or code from either research project are included in FrankLuma.

The shipped review demo and Store screenshots continue to use original geometric artwork, without third-party footage or character brands.
