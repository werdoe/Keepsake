# IGSaver

A personal iPhone app: paste an Instagram post, reel, story or highlight link, then save the photos and videos to your Photos library.

## What it handles

| Link | Example | Login needed? |
|---|---|---|
| Post (single or carousel) | `instagram.com/p/ABC123…` | No for public accounts (best effort), yes for private accounts you follow |
| Reel / IGTV | `instagram.com/reel/ABC123…` | Same as posts |
| Story (one, or all current) | `instagram.com/stories/username/3456…` | Yes |
| Highlight | `instagram.com/stories/highlights/1789…` or `instagram.com/s/…` | Yes |
| Share links | `instagram.com/share/…` | Resolved automatically |

You can paste the whole shared text. The app finds the link in it and ignores the rest.

## Install on your iPhone (one-time, about 10 minutes)

You need **Xcode 16 or newer** on the Mac.

1. **Open the project.** Double-click `IGSaver.xcodeproj`.
2. **Add your Apple ID to Xcode** if you haven't already. Go to Xcode › Settings › Accounts, then click **+** and choose Apple ID.
3. **Set signing.**
   - In the left sidebar, click the blue **IGSaver** project icon.
   - Select the **IGSaver** target, then open the **Signing & Capabilities** tab.
   - Under **Team**, pick your name (Personal Team).
   - If Xcode says the bundle identifier isn't available, change `com.rai.igsaver` to something unique, for example `com.rai.igsaver.mine`.
4. **Connect your iPhone** with a cable and tap **Trust** on the phone.
5. **Turn on Developer Mode** on the iPhone. Go to Settings › Privacy & Security › Developer Mode, switch it on and restart. The option only appears after the phone has been connected to Xcode once.
6. **Run the app.** At the top of the Xcode window, choose your iPhone as the run destination, then press **▶** (or ⌘R).
7. **Trust the app the first time.** If the iPhone says "Untrusted Developer", go to Settings › General › VPN & Device Management, tap your Apple ID, then tap **Trust**.

**How long the install lasts:** with a free Apple ID, the app stops opening after 7 days. Plug the phone in and press ▶ again to renew it. A paid Apple Developer account ($99/yr) makes it last a year.

## Using it

1. In Instagram, tap the **Share** (paper-plane) icon, then **Copy link**.
2. Open IGSaver and tap **Paste**. The app fetches the media right away.
3. Tap **Save all** to save everything, or tap one tile to preview it and save just that one.

**For stories and highlights:**
- Tap the person icon (top right) once and log in on Instagram's own login page. The app keeps the login.
- Your password goes only to Instagram. The app stores the session cookie, the same way Safari does.
- Consider using a spare Instagram account. Instagram sometimes flags accounts that download a lot.

## When something goes wrong

- **"Instagram wants you to be logged in"**: Instagram often blocks logged-out fetches, even for public posts. Log in and try again.
- **"Instagram wants to confirm it's you"**: open the login screen from the person icon and complete Instagram's check there.
- **"limiting requests"**: you've fetched a lot in a short time. Wait a few minutes.
- **Something that used to work stops working**: Instagram changes its internal web API every few months.
  - All the Instagram-specific code is in `IGSaver/InstagramClient.swift`.
  - Ask Claude Code to "update InstagramClient.swift for Instagram's current web API".
  - The logged-out post fetch depends on `postQueryDocID`, which is the value that changes most often.

## Files

- `IGSaver/InstagramLink.swift`: recognises and parses links.
- `IGSaver/InstagramClient.swift`: fetches post, reel, story and highlight media.
- `IGSaver/PhotoSaver.swift`: downloads files and adds them to Photos.
- `IGSaver/LoginView.swift`: Instagram login in a web view, plus log out.
- `IGSaver/ContentView.swift` and `IGSaver/DownloaderModel.swift`: the screens.
- `project.yml`: a spare project definition, only needed if the `.xcodeproj` ever gets corrupted.
  - To regenerate the project: `brew install xcodegen`, then run `xcodegen` in this folder.

This app is for personal use only. Only save content you have the right to keep, and don't repost other people's work without permission.
