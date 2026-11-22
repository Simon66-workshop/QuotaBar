# QuotaBar 1.8.28

Mac menu bar extra for live usage. **G** is the shared weekly pool (X Subscription Super: Grok, Cursor, and Grok Bot). **GO** is Google Gemini model quota from the official Antigravity CLI. ChatGPT / Codex, Claude, local and external disks, and local RAM stay on the bar.

**Do not open `QuotaBar.xcodeproj`.** That path is retired.

## Install (no Xcode)

1. Download ZIP: green **Code** → **Download ZIP**
2. Unzip
3. Right-click **`Start QuotaBar.command`** → **Open**
4. macOS may ask to allow a script — choose Open
5. First run only: if asked to install **Command Line Tools**, accept. That is a small Apple installer, not the Xcode app.
6. After it finishes, double-click `Start QuotaBar.command` again

QuotaBar appears on the right of the menu bar. Existing unconnected services stay off the bar; unavailable Google periods stay visible as dashes under **GO**.

- **G** shared weekly pool — Grok, Cursor, and Grok Bot (one figure, the Grok billing percentage)
- **O** ChatGPT / Codex (5-hour + weekly)
- **AC / AT / AF** Claude current session, this week, and Fable this week (AF hidden when that limit is absent)
- **GO** Google / Antigravity — separate **used** percentages for Gemini Models **5h** (current) and **W** (weekly), without `%` on the bar (e.g. `GO 5h:80  W:25`); Argon and third-party quotas stay separate in the panel
- **D** fullest visible disk used %
- **E** each external disk
- **M** local RAM used % (for example, `M 63%`)

Cursor and Grok Bot are not separate bar, tooltip, or panel items.

- **Left-click** the bar → glass panel (details, connect, hide disks)
- **Right-click** the bar → short native menu (refresh / copy / alerts / quit)

The panel header should say **v1.8.28** (build **41**). If it still says an older version, quit QuotaBar and run `Start QuotaBar.command` again. **For this local upgrade review, do not install or launch it; use the candidate-only build below.**

Later launches: just double-click `Start QuotaBar.command` again.

## What it reads

- Grok: `~/.grok/auth.json` + in-app device login (writes the file itself). This percentage is the shared weekly pool, shown as **G**. Cursor and Grok Bot are not polled on their own.
- ChatGPT: `~/.codex/auth.json` after `codex login` (refreshes the token itself)
- Claude: Claude Desktop first. The signed-in Claude.app session lives in `~/Library/Application Support/Claude/` (`Network/Cookies` or `Cookies`, plus `config.json` when it has an oauth token cache). The cookie key is the login-keychain item **Claude Safe Storage** (read with `/usr/bin/security`, never written to a log). QuotaBar calls the same `claude.ai` usage endpoint Settings → Usage uses and shows Current session (AC), This week (AT), and Fable this week (AF) when that window is in the payload. The menu bar prints them as `AC 19  AT 82  AF 94`. A missing window, including Fable on non-Max plans, is left out. There is no plain usage-percent file to read. Claude Code oauth (`Claude Code-credentials`, `~/.claude/.credentials.json`) is only a fallback when that login already exists. A terminal `claude` login is not required.
- Memory: local Mach VM statistics and physical RAM; no extra permission or entitlement
- Google: only the already-signed-in Antigravity CLI's read-only `/usage` JSON, specifically `command.data.groups`. QuotaBar does not discover Google credentials, log in, read Google auth files or Keychain, invoke `gemini`, or call another quota endpoint. See GO below.
- Disks: mounted local + external volumes (auto add/remove), capacity, read/write rate, status

If ChatGPT shows `—`, run `codex login` once in Terminal, then click Refresh.

If Claude stays under Connect, open Claude Desktop while signed in, then click Refresh. The first read can ask for the Keychain item Claude Safe Storage — click **Allow**, not Always Allow (Always Allow trusts `/usr/bin/security` for every app). QuotaBar asks once per launch. After Deny or a timed-out prompt it does not ask again until you click Refresh. Pasting Claude Code credentials is optional. A connected account leaves Connect and shows in Usage, including **AC**, **AT**, and **AF** on the menu bar.

Plug in a USB / Thunderbolt disk and it appears in the panel; eject it and it disappears. Hide Time Machine or VM disks from the panel — they stay off the bar until you Show them again.

Quota figures only turn orange / red on a token that is actually high (85%+ services, 90%+ disks / RAM). A normal 60–80% day stays neutral.

## 1.8.28 — 转发器连接

The dot before the existing quota tokens reports the two relay connections: green only when
both are healthy; red for a confirmed outage; amber for degradation; hollow gray for
unknown, missing, or stale status. The panel shows Feishu and WeCom heartbeat times in
Asia/Shanghai and the website certificate separately. A green dot does **not** prove
end-to-end message delivery. Certificate expiry does not change the relay dot.

The feature is opt-in. Without a matching generic password in the **login** keychain it
shows **未配置** and does not call the endpoint. Once the service owner provides the scoped
v1 token and the approved QuotaBar binary is installed, confirm the **default** keychain
is **login** in Keychain Access before using this command (it writes to the default
keychain). Keep `-w` as the last option: macOS prompts for the token, so it is not an
argument or a shell history entry.

```sh
security add-generic-password -U \
  -s app.quotabar.mac.relay-status -a 66workshop.cn/relay-status-v1 \
  -T "" -T "$HOME/Applications/QuotaBar.app/Contents/MacOS/QuotaBar" -w
```

If the login keychain is not the default, provision the item directly in the **login**
keychain using Keychain Access. Trust only the verified QuotaBar executable, not all apps
(`-A`). If an update via `-U` preserves an old ACL, check that specific item's Access
Control in Keychain Access. An unavailable/locked keychain or an ACL denial prevents a
fetch; never relax the ACL to all apps. Rebuilt or re-signed candidates may need a new
ACL check. After changing credentials use **Refresh** (or **Refresh now**); HTTP 401
pauses automatic polling until then. A dedicated child mode of the same QuotaBar
executable suppresses Keychain prompts without changing the main process's
interaction policy. The child returns status or a fixed error, never the credential.
The relay only sends the token as a Bearer header to
`https://66workshop.cn/api/relay-status/v1`; redirects are refused. QuotaBar does not
log, export, or save the token outside the login keychain.

Offline verification (synthetic responses, no real Keychain access or QuotaBar launch):
`QUOTABAR_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash QuotaBarTests/check-relay-status.sh`.

## 1.8.25 — GO (Google / Antigravity)

The only GO source is the [official Antigravity model quota command](https://antigravity.google/docs/cli/commands/usage/) (`/quota` is its alias):

```sh
"/Volumes/2T扩展盘/Agent文件/gemini-cli/antigravity/bin/agy" -p "/usage" --output-format json
```

This Mini1 path is intentionally absolute; no PATH search or alternate provider is used. QuotaBar invokes it without a shell, with closed stdin and discarded stderr, from `/` (not a project directory). QuotaBar enforces the 65-second deadline in the parent without adding CLI arguments. The child inherits only allowlisted inputs for the existing local session, CLI runtime (including any existing auto-update opt-out), and proxy. API keys, the [ADC selector](https://antigravity.google/docs/enterprise/#setting-up-application-default-credentials-adc) `AGY_ADC_AUTH`, Google Cloud credential/project/location overrides, and other environment variables are not inherited. The parent environment and the wrapper's process-level proxy are unchanged; no system proxy, network, timezone, or login setting is changed. No extra dependencies are required.

- The official value is `remaining_fraction` (0–1). Each bucket's **used % = 100 × (1 − remaining_fraction)**, rounded to the nearest whole percent for display. **Left** is its complementary remaining percentage. GO follows existing service colors: orange at 85% used, red at 95% used.
- **GO** shows distinct **5h** and **W** used figures, independently colored. Each comes from the corresponding `window: "5h"` or `window: "weekly"` bucket in **Gemini Models**. GO never shows a blended value or borrows a number from any other window or group. A missing or ambiguous period shows a dash without hiding a valid other period.
- The panel puts **Current usage (5h)** above **Weekly limit** for each group. Each supplied row has its own labeled **used** and **left** percentages and reset; a missing row says **Not provided**, without a number or reset. UTC `reset_time` is shown as local date and time with timezone; the machine timezone is unchanged. Hover a row for its official name and bucket ID. The tooltip and copied summary show the same details; additional official buckets remain separately labeled.
- **Gemini 4 Argon** stays separate. When it returns only weekly, its current row says **Not provided**. If a named group returns an empty bucket array, both rows say **Not provided**, without affecting valid figures from other groups. **Claude and GPT models** is explicitly Antigravity-only, never Claude AC/AT/AF or Codex O. Neither group drives GO. Group descriptions are available on hover; quota for individual models is not invented.
- `/credits`, AI Studio / API-key billing, token totals, human-readable `response`, and raw request counters are **not** used to calculate GO.
- Missing CLI, process failure, a 65-second outer timeout, non-`SUCCESS`, missing/invalid `command.data.groups`, invalid fractions/reset times, or duplicate identities show both GO periods as dashes and the panel as **Unavailable**, not 0% or cached success. If other groups are valid but Gemini Models has no unambiguous 5h/weekly window, the other groups remain visible. No login form or automatic OAuth flow is added. Restore the existing CLI/session separately, then click **Refresh**.
- GO shares the existing 90-second service refresh and single-flight refresh queue. Output is memory-only, capped at 1 MiB; raw stdout/stderr and credentials are never logged or persisted by this feature. Existing Claude, Codex, Grok shared-pool, disk, and RAM logic remains intact.

### Local verification / candidate only (no install or launch)

On this upgrade worktree, all artifacts and compiler caches go to the mounted external volume:

```sh
BASE="/Volumes/2T扩展盘/Agent文件/QuotaBar-GO-upgrade-20261119"
CACHE="$BASE/candidate/sdk26-module-cache"
QUOTABAR_TEST_OUT="$BASE/candidate/quotabar-tests" \
  QUOTABAR_MODULE_CACHE="$CACHE" bash QuotaBarTests/run.sh
QUOTABAR_MEMORY_CHECK_OUT="$BASE/candidate/quotabar-memory-check" \
  QUOTABAR_MODULE_CACHE="$CACHE" bash QuotaBarTests/check-memory.sh
QUOTABAR_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  QUOTABAR_MODULE_CACHE="$CACHE" bash QuotaBarTests/build-candidate.sh
QUOTABAR_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  QUOTABAR_MODULE_CACHE="$CACHE" bash QuotaBarTests/check-google.sh
# Optional: same check-google.sh command with --live runs /usage once.
```

`build-candidate.sh` is restricted to this Mini1 worktree and checks that the external volume is mounted. It compiles via `swiftc` (the current non-Xcode build path) to `$BASE/candidate/QuotaBar.app`, using canonical version metadata, without quitting, replacing, signing, or opening the installed app. **Do not open the candidate during this review.**

Mini1's current default CLT 6.4 / macOS 27 SDK is missing the `SwiftUIMacros` plugin needed by existing `@State` code. The commands above explicitly select the already-installed macOS 26.5 SDK for this process only. `QUOTABAR_SDK` is also supported by the normal launcher, without changing `xcode-select`, installing tools, or weakening a check. The default SDK 27 build remains an environment blocker; successful compilation against SDK 26.5 does not prove that SDK 27 is fixed. Compiler caches use canonical absolute paths to avoid duplicate-module errors from mixing `worktree/../candidate` with `candidate`.

Tests use a synthetic, non-account fixture of the official envelope, malformed/error fixtures, and local fake processes for timeout, exit, size, stdin, and environment behavior; they do not call a network or access credentials. Existing AC/AT/AF, O, G, disk, RAM, and panel-fit regression checks still run. A component-only renderer and optional live Google smoke check are described in `QuotaBarTests/check-google.sh`; neither starts a menu-bar instance. Offline render evidence does not constitute full-app interaction acceptance or independent human review.

The upgrade is additive and reversible with `git revert <GO-upgrade-commit>` after review (base `d17b76a2b93e0a8c1e40675f86d3f5caf4382941`). No Google credential or quota state is migrated. Candidate files are separate from the installed 1.8.24 app; reverting the code does not require touching that running app. Commit / push / PR are not deployment or approval to replace it.

## 1.8.24

Local RAM is shown as **M** beside the disks, with a used / total GB line in the panel, native menu, tooltip, and copied summary. RAM shares the existing disk poll (12s with the panel closed, 3s open); no extra timer, subprocess, permission, entitlement, or RAM alert is added. Failed samples show `M —` / `Unavailable`, not zero or a stale value. Colors use the disk occupancy bands (orange at 90%, red at 96%); they do **not** represent macOS memory pressure.

`host_statistics64(HOST_VM_INFO64)` supplies `vm_statistics64`: used bytes = `(active_count + wire_count + compressor_page_count) * host_page_size`; total bytes = `ProcessInfo.processInfo.physicalMemory`. This follows the requested Activity Monitor-style Memory Used formula, not `total - free`. Inactive, free, and speculative pages are not added; speculative pages are already included in the kernel's free count. Purgeable pages receive no separate adjustment (in particular, no subtraction from active). The compressor contributes its actual physical footprint, not `total_uncompressed_pages_in_compressor`. GB labels use binary units (1 GB = 1,073,741,824 bytes), so 16 GiB of RAM displays as 16.0 GB.

Run `bash QuotaBarTests/run.sh` for regression tests and `bash QuotaBarTests/check-memory.sh` for a live comparison using the app's RAM sampler, `vm_stat`, and read-only `memory_pressure`. The pressure tool's free percentage is a different metric, not the complement of **M**; small sampling-time differences in page counts are expected.

## 1.8.23

While the panel is open it refits to the height of its content: a refresh, a disk appearing or leaving, a copied note, an expanded row, or a connect form. Bursts of those changes settle together, and a sub-point difference does not move the window. The top edge stays under the menu-bar item. The tallest the panel grows is the visible frame of the screen that holds the status item, minus the menu bar and a safety margin. Past that, the usage list scrolls and the header, account, disks, and footer stay put. On a shorter screen the whole panel scrolls instead of clipping.

## 1.8.22

Claude, Codex, and disk letters are back on the menu bar, tooltip, and panel, including their login reads, auth watchers, and polling. Grok, Cursor, and Grok Bot are one **G** item: the shared weekly pool (the Grok billing percentage). The panel row carries a short caption, and the panel height follows its content.

## 1.8.21

The menu bar showed only the shared weekly Grok pool. Claude, Codex, Cursor, and Grok Bot stayed off the bar and out of the panel. Those sources were not polled. Disks stayed in the panel and stayed off the bar. 1.8.22 puts Claude, Codex, and disks back.

## 1.8.20

- Menu bar: Claude marks get a little room, `AC 19  AT 82  AF 94` instead of `AC19 AT82 AF94`.
- `Start QuotaBar.command` now builds for macOS 14 (`-target arm64-apple-macos14.0`), so a newer toolchain cannot stamp a higher minimum macOS than the Mac it runs on.

## 1.8.19

The menu bar shows Claude as three figures: AC current session, AT this week, and AF Fable this week. Each figure keeps its own 85/95 colour. AF is omitted when that weekly limit is not in the payload. The Usage panel lists each figure with its percent and reset time.

## 1.8.18

Claude Safe Storage is read with one keychain query. After Deny or a timed-out prompt, QuotaBar stops asking until you click Refresh, and a one-time Allow lasts until QuotaBar quits. QuotaBar no longer refreshes every provider each time Claude.app writes to its Application Support folder.

## 1.8.17

Claude Usage reads the Claude Desktop session first (Settings → Usage: Current session, This week, and Fable or another named bucket when the payload includes it). Rebuild on the Mini by double-clicking `Start QuotaBar.command`. The panel header should say **v1.8.17**. Claude Code oauth remains a fallback when those credentials already exist. The desktop token cache is read-only so QuotaBar does not rotate Claude.app's refresh token.

## 1.8.16

Claude shows in Usage after a local Claude Code login, with Current session / This week detail rows (and Fable this week when the oauth usage payload has that window). The keychain is read via `/usr/bin/security` so the row is not stuck on Connect. The main percent is the tighter of the 5-hour session and the 7-day week.

## 1.8.15

Settings → Usage weekly pool (21% = Chat + Builder + Imagine) is not `config.creditUsagePercent` (API credits, often 0). Fetch full billing + grok.com GetGrokCreditsConfig, pick the payload with currentPeriod / product mix.

## 1.8.14

Billing `creditUsagePercent: 0` is a real number (G 0), not a parse miss. 200 payloads no longer collapse to G —. Last result (HTTP / keys / used, no token) is written to `~/.grok/quotabar-status.txt`.

## 1.8.13

A 4-byte `{}` auth.json was treated as a session, so G sat on — and never called billing. Empty files are ghosts: G leaves the bar, keychain/logs are still searched, and a ghost file auto-starts device login (Clash proxy). Explicit Disconnect now deletes an empty auth.json instead of leaving `{}`.

## 1.8.12

This Mini cannot reach grok.com direct. Grok curl now uses the system Clash proxy (HTTP/SOCKS, typically 127.0.0.1:7897). `--noproxy` is gone — it timed out. Cursor still uses URLSession.shared.

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
