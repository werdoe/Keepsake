# Keepsake

A personal iPhone app that saves photos and videos from Instagram, Threads and Facebook to your Photos library. (The Xcode target is still called `IGSaver`; the app shows up as **Keepsake**.)

## What it saves

| Platform | Supported | Login |
|---|---|---|
| Instagram | Posts, carousels, reels, stories, highlights, profiles (latest posts), `/share/` links | For stories, highlights and private accounts you follow |
| Threads | Posts, reposts and quote posts, profiles, `/share/` links | Only for private accounts you follow |
| Facebook | Reels, videos, photos, `fb.watch` and `/share/` links; stories (experimental) | Only for friends-only or private posts and stories |
| TikTok | Videos without the watermark (best quality), photo slideshows, sounds; short links | Not needed |

Logged-in and TikTok pages load in a hidden web view (`Engine/WebCapture.swift`). It captures the media data the site loads for itself and passes TikTok's browser check.

## Features

- **Share sheet:** tap Share › Keepsake to save right away, or preview first. It asks before saving something you already have.
- **Best quality:**
  - Downloads the highest-resolution stream (DASH or TikTok's `bitrateInfo`) and merges in the audio.
  - Falls back to the standard file if that fails.
- **Save to Photos, Files or both.** Files go in On My iPhone › Keepsake, sorted by platform. The optional Keepsake album and Wi-Fi only still work.
- **Captions:**
  - The caption and source link are written into each photo's details (IPTC/EXIF).
  - Optionally, saves keep the post's original date in Photos.
  - Long-press a caption to copy it, or copy all its hashtags.
- **Save Audio:** a video's sound or a TikTok sound, as .m4a in Files › Keepsake › Audio.
- **Background downloads** keep going after you leave the app. Swiping it away in the app switcher still cancels them.
- **Dynamic Island and Lock Screen progress**, including during batch saves.
- **Batch Save:** paste many links, or type several Instagram usernames to save everyone's current stories. You can skip ones you've already saved.
- **Duplicate warnings:** "You saved this 2 days ago".
- **Library:**
  - Search and filter by platform.
  - Face ID lock.
  - Back up to or restore from one file (keep it in iCloud Drive). Automatic iCloud sync isn't available to sideloaded apps.
- **Widgets:**
  - Recent saves and a Paste & Save button on the home screen or Lock Screen.
  - A Control Center button (iOS 18).
  - A "Paste & Save" action in Shortcuts, which can also go on the Action button.
- **Deep links:** `keepsake://save?url=…`, `keepsake://paste`, `keepsake://library`.

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
- `Widgets/`: the Live Activity, the recent-saves widget and the Control Center control.
- `Intents/`: the Paste & Save App Intent, shared by the app and widgets.
- `Engine/`: link parsing, the Instagram/Threads/Facebook extractors, DASH quality selection, downloading, merging, saving to Photos and history. Used by both the app and the share extension.
- `Common/`: brand colours, the mark, and Live Activity data (all targets).
- `Config/`: Info.plists, entitlements and the signing script.

**When a platform changes its site:**

| Platform | File | Notes |
|---|---|---|
| Instagram | `Engine/InstagramExtractor.swift` | `postQueryDocID` rotates the most |
| Threads | `Engine/ThreadsExtractor.swift` | Media sits under `data.media` in the page's JSON |
| Facebook | `Engine/FacebookExtractor.swift` | Looks for `browser_native_hd_url` / `progressive_urls` and `representations` |
| TikTok | `Engine/TikTokExtractor.swift` | Reads `webapp.video-detail.itemInfo.itemStruct` |

## Personal use

Only save what you have the right to keep, and ask before reposting other people's work.
