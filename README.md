# QuotaBar

Mac menu bar extra for live Grok / Cursor / Grok Bot usage.

## Install on your Mac

1. Click the green **Code** button → **Download ZIP**
2. Unzip
3. Open `QuotaBar.xcodeproj` in Xcode
4. Signing & Capabilities → select your Apple ID
5. Press **⌘R**

QuotaBar appears on the right of the menu bar as `G 5 · C 0 · B 4`.
No Dock icon.

It reads local sessions:

- Grok: `~/.grok/auth.json`
- Cursor + Grok Bot: Cursor `state.vscdb`

Needs macOS 14+ and Xcode. If Cursor shows `—`, open Cursor once, then run QuotaBar again.
