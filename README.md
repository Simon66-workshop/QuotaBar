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

- **Grok**: `~/.grok/auth.json` (and Keychain). Grok CLI 0.2.111 often prints "Signed in" but does not write disk — use **Sign in with Grok** inside the panel; QuotaBar runs the same OIDC device flow and writes `auth.json` itself.
- **Cursor + Grok Bot**: Cursor local session (`state.vscdb`)

If Cursor shows `—`, open Cursor once, then start QuotaBar again.

## Panel

Click the menu bar title to open the glass panel. Click outside (or the title again) to close. Alerts fire at ≥80% usage.
