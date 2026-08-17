# QuotaBar

Mac menu bar extra for live Grok / Cursor / Grok Bot usage.

**Do not open `QuotaBar.xcodeproj`.** That path is retired.

## Install (no Xcode)

1. Download ZIP: green **Code** → **Download ZIP**
2. Unzip
3. Right-click **`Start QuotaBar.command`** → **Open**
4. macOS may ask to allow a script — choose Open
5. First run only: if asked to install **Command Line Tools**, accept. That is a small Apple installer, not the Xcode app.
6. After it finishes, double-click `Start QuotaBar.command` again

QuotaBar appears on the right of the menu bar as `G 5 · C 0 · B 4`. No Dock icon.

Later launches: just double-click `Start QuotaBar.command` again.

## What it reads

- Grok: `~/.grok/auth.json`
- Cursor + Grok Bot: Cursor local session

If Cursor shows `—`, open Cursor once, then start QuotaBar again.
