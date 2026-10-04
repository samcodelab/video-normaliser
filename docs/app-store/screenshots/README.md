# Mac App Store screenshots

Upload 01-comparison.png through 04-export.png in that order. Each PNG is 2560×1600 (16:10), matching Apple's Mac screenshot specifications.

The raw captures are genuine native UI from the isolated sandboxed release-check build of current FrankLuma source. It uses the original included geometric demo (640×360, 24 fps, silent), no personal media or filenames. The comparison is frame 2/96 with 100% correction. Later captures show a manually added scene boundary at frame 12, 1.5× timeline zoom, expanded reference controls, and the real H.264 export Save panel. The five format choices were verified in the native format menu and hosted export tests; the capture API records the Save window without the floating popup menu.

`scripts/prepare-store-screenshots.swift` places the source screenshots on a dark canvas with truthful captions, preserves their aspect ratio and clips the rounded window corners. No controls or correction results are redrawn. Run from the repository root:

```sh
swift -module-cache-path .build/store-screenshot-module-cache scripts/prepare-store-screenshots.swift
```

These are initial English submission assets. They were visually inspected; final listing upload and Apple validation remain pending.

[Apple's Mac screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
