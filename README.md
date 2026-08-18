# QuotaBar 1.3

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

- **Left-click** the bar → glass panel
- **Right-click** the bar → native menu (always works even if the panel fails)

Later launches: just double-click `Start QuotaBar.command` again.

## What it reads

- Grok: `~/.grok/auth.json` + in-app device login (writes the file itself)
- Cursor + Grok Bot: Cursor local session (`state.vscdb`)

If Cursor shows `—`, open Cursor once, then start QuotaBar again.

## 1.3

- Panel host retain + no `.transient` (bar click was dead)
- Right-click fallback menu
- Colored bar numbers when usage is high
- Remaining % + copy summary / copy device code
- Account row (re-sign in / disconnect) when Grok is linked
- Soft-fail token refresh; paste-only tokens work
- Debounced `~/.grok` watcher
