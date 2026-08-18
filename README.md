# QuotaBar 1.6

Mac menu bar extra for live Grok / Cursor / Grok Bot / ChatGPT / Claude Code usage, plus local and external disks.

**Do not open `QuotaBar.xcodeproj`.** That path is retired.

## Install (no Xcode)

1. Download ZIP: green **Code** → **Download ZIP**
2. Unzip
3. Right-click **`Start QuotaBar.command`** → **Open**
4. macOS may ask to allow a script — choose Open
5. First run only: if asked to install **Command Line Tools**, accept. That is a small Apple installer, not the Xcode app.
6. After it finishes, double-click `Start QuotaBar.command` again

QuotaBar appears on the right of the menu bar. Unconnected services stay off the bar.

- **G** Grok SuperGrok Heavy weekly
- **C** Cursor Ultra monthly
- **B** Grok Bot (Sand) weekly
- **O** ChatGPT / Codex (5-hour + weekly)
- **A** Claude Code (5-hour + 7-day)
- **D** fullest visible disk used %

- **Left-click** the bar → glass panel (details, connect, hide disks)
- **Right-click** the bar → short native menu (refresh / copy / alerts / quit)

The panel header should say **v1.6**. If it still says v1.5.x, quit QuotaBar and run `Start QuotaBar.command` again.

Later launches: just double-click `Start QuotaBar.command` again.

## What it reads

- Grok: `~/.grok/auth.json` + in-app device login (writes the file itself)
- Cursor + Grok Bot: Cursor local session (`state.vscdb`)
- ChatGPT: `~/.codex/auth.json` after `codex login` (refreshes the token itself)
- Claude: `~/.claude/.credentials.json` and the `Claude Code-credentials` keychain after `claude` login
- Disks: mounted local + external volumes (auto add/remove), capacity, read/write rate, status

If Cursor shows `—`, open Cursor once, then start QuotaBar again.

If ChatGPT shows `—`, run `codex login` once in Terminal, then click Refresh.

If Claude shows `—`, run `claude` once in Terminal, then click Refresh.

Plug in a USB / Thunderbolt disk and it appears in the panel; eject it and it disappears. Hide Time Machine or VM disks from the panel — they stay off the bar until you Show them again.

The bar only turns orange / red on a token that is actually high (85%+ services, 90%+ disks). A normal 60–80% day stays neutral.

## 1.6

Unconnected services fold into one **Connect** cell (segmented Grok / ChatGPT / Claude) so the glass panel no longer clips. `UsageSource` is the slot for the next provider — add a `LaneKey` + source, do not add another fetch in `UsageStore`. If the `claude` / `Claude` process is running, QuotaBar will not rotate the Claude refresh token.

## 1.5.1

Audit: Grok-not-connected no longer occupies the bar; usage alerts match the 85/95 and 90/96 color thresholds; IOKit mount/wake rebuilds are debounced; APFS parent walk no longer leaks io_objects; Claude persist never invents `~/.claude/.credentials.json`; unused providers skip their HTTP calls; disk timer is 12s closed / 3s open.

## 1.5

- Claude Code 5h + 7d from local login
- Menu bar hides unconnected services
- Hide individual disks (Time Machine / VM)
- Disks sorted by just-mounted, then fullest
- Short right-click menu
- IOKit: single-key Statistics, match/terminate notifications, APFS BSD walk, no 90s topology poll

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
