# Keepsake

A personal iPhone app that saves photos and videos from Instagram, Threads and Facebook to your Photos library. (The Xcode target is still called `IGSaver`; the app shows up as **Keepsake**.)

## What it saves

| Platform | Supported | Login |
|---|---|---|
| Instagram | Posts, carousels, reels, stories, highlights, `/share/` links | Needed for stories, highlights and private accounts you follow |
| Threads | Public posts: photos, videos, carousels | Not needed |
| Facebook | Public reels, videos, photos, `fb.watch` and `/share/` links | Not needed. Stories and private posts aren't available |

## Features

- **Share sheet:** tap Share › Keepsake in any of the three apps. It saves right away, or shows a preview first if you turn off "Save automatically".
- **Best available quality:**
  - Downloads the highest-resolution video stream and merges it with the audio (no re-encoding).
  - Falls back to the standard file automatically if merging fails.
  - AV1 video is only used on iPhones that decode it in hardware.
- **Wi-Fi only:** downloads won't use mobile data, and Settings shows your current connection.
- **Dynamic Island and Lock Screen progress** for saves started in the app.
- **Library** of everything you saved, including share-sheet saves:
  - Search and filter by platform.
  - Open the original post, save again, or open Photos.
- **Optional "Keepsake" album** in Photos.
- **Deep link for Shortcuts:** `keepsake://save?url=<link>`.

## Building

Every push to `main` builds an unsigned IPA on GitHub's Mac runners (`.github/workflows/build-ipa.yml`) and publishes it to the `builds` branch:

- `IGSaver.ipa`
- `build.log`
- `status.txt`

Always check `build.log` for `** BUILD SUCCEEDED **`. `status.txt` can say `success` even when the build failed.

The build ad-hoc signs the app and share extension with their entitlements (`Config/sign-adhoc.sh`) so SideStore can set up the shared app group. SideStore then re-signs everything with your Apple ID.

**Running from Xcode instead:**
1. In each target's build settings, set `CODE_SIGNING_ALLOWED` to `YES`.
2. Pick your team.
3. Build to your phone.

## Project layout

- `App/`: the app's screens, Live Activity control, Instagram login and assets.
- `ShareExtension/`: the share-sheet card.
- `Widgets/`: the Dynamic Island / Lock Screen Live Activity.
- `Engine/`: link parsing, the Instagram/Threads/Facebook extractors, DASH quality selection, downloading, merging, saving to Photos and history. Used by both the app and the share extension.
- `Common/`: brand colours, the mark, and Live Activity data (all targets).
- `Config/`: Info.plists, entitlements and the signing script.

**When a platform changes its site:**

| Platform | File | Notes |
|---|---|---|
| Instagram | `Engine/InstagramExtractor.swift` | `postQueryDocID` rotates the most |
| Threads | `Engine/ThreadsExtractor.swift` | Media sits under `data.media` in the page's JSON |
| Facebook | `Engine/FacebookExtractor.swift` | Looks for `browser_native_hd_url` and `representations` |

## Personal use

Only save what you have the right to keep, and ask before reposting other people's work.
