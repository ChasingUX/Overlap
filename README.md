# Overlap

A video and audio editor for Mac. Lay out clips, titles and backgrounds on a timeline, give the picture a canvas
shape and frame, clean up voices, find seamless loops, and export video or sound ready to post.

Overlap is a native macOS app, written in Swift with AppKit, SwiftUI, AVFoundation and Core Image. It needs
macOS 27.

**Install it:** download the latest version from <https://chasingux.github.io/Overlap/>. See [INSTALL.md](INSTALL.md)
for the one-time step macOS asks for. After that, Overlap updates itself.

## What it does

- **Timeline:** tracks of video, sound, images, titles and backgrounds. Trim, split, ripple delete, change speed
  with or without keeping pitch, fade in and out, and crossfade by overlapping two clips. Tracks can be muted,
  soloed and locked.
- **Picture:** a canvas that follows the first video, or any size you drag its edges to in the preview, at the first
  video's frame rate. A background of a mesh gradient, a color, your own image or one of the Mac's aerial wallpapers,
  which frames the picture with padding, a shadow and rounded corners. Each picture can be moved, scaled, rotated,
  cropped and color-adjusted.
- **Zooms:** right-click a video or image clip and choose Add Zoom. Zooms sit in a lane above the clip's track; drag a
  zoom's region in the preview, set its level, and choose Smooth or Dynamic easing and how much motion blur. Zooms
  close together pan from one region to the next, and recordings stay sharp because zooms use the source's pixels.
- **Titles:** ready-made styles (centered, lower third, caption, intro, end card, callout), typed, placed and sized
  on the canvas, with a shadow or plate to read over the picture, animations in and out, and one look for all.
- **Sound:** per-clip volume, Isolate voice to take out background noise, and a master volume. Exports can be
  brought to the loudness streaming services play at.
- **Loops:** finds where a video repeats, or the best places it can loop, and trims a clip to a loop.
- **Export:** MP4 or MOV in H.264 or HEVC, or sound alone as WAV, AIFF or M4A.
- **Projects:** each project is an `.overlap` package holding its media, autosaved, with File > Browse All Versions.

## Building

Open `Overlap.xcodeproj` in an Xcode that has the macOS 27 SDK and run the **Overlap** scheme. Sparkle, the only
dependency, comes through Swift Package Manager and resolves on the first build.

Run the tests with ⌘U, or from Terminal:

```bash
xcodebuild test -project Overlap.xcodeproj -scheme Overlap -destination 'platform=macOS'
```

Debug builds leave update checks off, so a development copy never replaces itself with a release.

## Layout

| Folder | What's in it |
|---|---|
| `Overlap/App` | App startup, the menu bar, updates, and debug-only self-checks |
| `Overlap/Document` | The `.overlap` document and its window |
| `Overlap/Model` | The project, its timeline, and the store the interface edits it through |
| `Overlap/Engine` | Playback and export: composition building, the Core Image compositor, sound, loudness, voice isolation |
| `Overlap/Media` | Importing and reading media: thumbnails, waveforms, and frame prints for finding loops |
| `Overlap/UI` | The window's interface: preview, timeline, panels and controls |
| `OverlapTests` | Tests for editing, rendering, sound, export and loops |
| `Config` | `Info.plist`, with the document type and update settings |
| `Scripts` | Making and publishing releases |
| `Pages` | The install page, published to GitHub Pages with each release |
| `Design` | Source art for the app icon |

## Releasing

Releases are signed without an Apple developer account and reach installed copies through Sparkle.
[RELEASING.md](RELEASING.md) covers the one-time setup and making and publishing a release.
