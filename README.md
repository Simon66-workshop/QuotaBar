# QuotaBar 1.4

Mac menu bar extra for live Grok / Cursor / Grok Bot / ChatGPT usage, plus local and external disks.

**Do not open `QuotaBar.xcodeproj`.** That path is retired.

## Install (no Xcode)

1. Download ZIP: green **Code** → **Download ZIP**
2. Unzip
3. Right-click **`Start QuotaBar.command`** → **Open**
4. macOS may ask to allow a script — choose Open
5. First run only: if asked to install **Command Line Tools**, accept. That is a small Apple installer, not the Xcode app.
6. After it finishes, double-click `Start QuotaBar.command` again

QuotaBar appears on the right of the menu bar as `G 5 · C 0 · B 4 · O 12 · D 42`. No Dock icon.

- **G** Grok SuperGrok Heavy weekly
- **C** Cursor Ultra monthly
- **B** Grok Bot (Sand) weekly
- **O** ChatGPT / Codex (5-hour + weekly)
- **D** fullest mounted disk used %

- **Left-click** the bar → glass panel
- **Right-click** the bar → native menu (always works even if the panel fails)

The panel header should say **v1.4.1**. If it still says v1.3.x or v1.4, quit QuotaBar and run `Start QuotaBar.command` again.

Later launches: just double-click `Start QuotaBar.command` again.

## What it reads

- Grok: `~/.grok/auth.json` + in-app device login (writes the file itself)
- Cursor + Grok Bot: Cursor local session (`state.vscdb`)
- ChatGPT: `~/.codex/auth.json` after `codex login` (refreshes the token itself)
- Disks: mounted local + external volumes (auto add/remove), capacity, read/write rate, status

If Cursor shows `—`, open Cursor once, then start QuotaBar again.

If ChatGPT shows `—`, run `codex login` once in Terminal, then click Refresh.

Plug in a USB / Thunderbolt disk and it appears in the panel; eject it and it disappears. Alerts fire on mount, eject, and when a disk crosses 80 / 90 / 95% full.

## 1.4.1

Resource audit: disk I/O only while the panel is open, skip no-op UI publishes, single-flight usage refresh, cache IOKit topology and auth-file walks.

## 1.4

- ChatGPT / Codex usage (5h + weekly + credits)
- Local and external disk capacity
- Auto-detect add / remove
- Live transfer rate and disk status
- Disk-full and disk-mount alerts

## 1.3.2

Safari OAuth used to kill the menu-bar click. Local + global monitors, rebuild the status item after the browser opens, never `NSApp.activate`.
