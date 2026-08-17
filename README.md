# QuotaBar

Mac menu bar extra for live Grok / Cursor / Grok Bot usage.

## Install

1. Download this repo as ZIP (green **Code** → **Download ZIP**).
2. Unzip. If macOS says the file is from the internet, right-click the folder → Open.
3. Double-click **`QuotaBar.xcodeproj`**.
4. If Xcode asks to trust / enable signing: choose **Sign to Run Locally** or pick your Apple ID.
5. Press **⌘R**.

QuotaBar appears on the right of the menu bar as `G 5 · C 0 · B 4`. No Dock icon.

## If Xcode still quits when opening the project

Your previous download used a broken project file. Use this updated repo, not the old ZIP.

Fallback:

1. Xcode → File → New → Project → macOS → App.
2. Product Name `QuotaBar`, Interface **SwiftUI**, language Swift.
3. Replace the generated files with the Swift sources in the `QuotaBar/` folder.
4. In target Signing, uncheck App Sandbox if present.
5. Add `-lsqlite3` under Other Linker Flags.
6. In Info, set Application is agent (UIElement) = YES.
7. ⌘R.

## What it reads

- Grok: `~/.grok/auth.json`
- Cursor + Grok Bot: Cursor local session (`state.vscdb`)

Needs macOS 14+ and Xcode. If Cursor shows `—`, open Cursor once, then run QuotaBar again.
