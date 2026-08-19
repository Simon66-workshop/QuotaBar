# QuotaBar 1.8.11

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

The panel header should say **v1.8.11**. If it still says v1.8.10, quit QuotaBar and run `Start QuotaBar.command` again.

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

## 1.8.11

`--noproxy` was not enough under Clash fake-ip (198.18.x). Grok now DoH-resolves `cli-chat-proxy.grok.com` / `auth.x.ai` via 1.1.1.1 and pins `--resolve`. Failures show the real curl/HTTP line instead of "billing request failed".

## 1.8.10

Grok no longer uses URLSession. Billing and OIDC go through `/usr/bin/curl --noproxy '*'` so Clash on 127.0.0.1:7897 cannot intercept them. Disk names wrap to two lines on a 448pt panel so Macintosh HD / 2T扩展盘 / Backup盘 stay readable.

## 1.8.9

Grok billing and OIDC go **direct** (no system HTTP/SOCKS proxy). Clash on 127.0.0.1:7897 was turning `cli-chat-proxy` into `billing HTTP…` while Cursor still worked. Panel is 420pt so Macintosh HD / 2T扩展盘_OLD stay full names.

## 1.8.8

Audit leftovers: Disconnect wipes the QuotaBar slot in `~/.grok/auth.json` and ignores log/keychain revival until the next Sign in. Usage/disk `GridRow`s are inlined (no helper wrapper). Bar action and event monitors are mutually exclusive. Next service still goes through `UsageSource` only — no empty shells.

## 1.8.7

Audit fixes: glass host is 360pt (was 352, which clipped the 7-col table), overlapping refresh is queued instead of dropped after device login, bar only toggles on mouse-down, alerts re-arm after usage drops.

## 1.8.6

Grok billing now sends `x-xai-token-auth: xai-grok-cli` (required by cli-chat-proxy). Parse also accepts `used.val` / `monthlyLimit.val` money objects. Error Grok stays a row — it no longer opens the Connect form after a finished device login.

## 1.8.5

Panel is 360pt so the 7-track grid (letter · name · used · meter · left/free · window/I/O · hide) can breathe. Hide/Show relayouts the glass.

## 1.8.4

Usage and disk rows share one column grid (letter · name · used · bar · left/free · window/I/O). Capsule meters replace ProgressView so numbers line up. Section labels sit above the table, zebra rows help scanning.

## 1.8.2

Disk panel is a compact aligned table (D/E · used · free · I/O). Click a row for SMART; Hide stays on the row.

## 1.8.1

Audit: do not rebuild IOKit topology on hot-plug when the panel is closed. Cache DA kind per volume UUID. Ignore whole-disk / slice appeared noise; only volume path changes wake the bar.

## 1.8

External Fixed PCI-E / USB volumes are classified via DiskArbitration `DeviceInternal` + protocol (USB / Thunderbolt), not “ejectable”. The menu bar shows `D` for the hottest internal volume and a separate `E` for each external disk. Appear / disappear / volume-path callbacks update the bar immediately. Swift 6.3.3 compile: `contentRect`/`frameRect` are methods, `@MainActor` on the app, `PROC_ALL_PIDS` as `UInt32`, `MAXPATHLEN`.

## 1.7.1

Audit: Claude process scan only when a refresh is actually needed; argv match no longer treats a folder named `claude` as the CLI; KERN_PROCARGS2 argc is memcpy-safe; one DASession is reused; panel resize unconstrains before measuring and is debounced.

## 1.7

Disk rates use DiskArbitration BSD names + volume UUID (no fuzzy `disk3`/`disk30` prefix). Click **Health** on a disk to read SMART once — never on the timer. Connect form switches resize the glass panel. Claude-live detection walks process paths and `node …/claude` argv, and ignores Claude.app. No empty sixth service: Gemini consumer quota was retired.

## 1.6.1

Audit: lock token caches (parallel `loadAll` was racing), persist one provider without flushing the others, cache the Cursor sqlite token 20s, ignore auth-file FSEvents for 8s after a refresh so a write-back does not fire a second 5-way fetch, and only treat the `claude` CLI as live (not the desktop `Claude` app).

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
