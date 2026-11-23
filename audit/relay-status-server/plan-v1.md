# QuotaBar 1.8.28／41：「转发器连接状态」方案

**建议：复用 `66workshop.cn:443`，加一个鉴权的只读状态接口；QuotaBar 在现有菜单栏项目旁加一颗灯。** 绿灯只表示 ECS 侧连接证据正常，不代表飞书或企微消息已端到端送达。**灰色空心表示未知，不沿用上次的绿灯。**

本次只读检查了工作树 `main`（`5d40586`）和 [ECS 现状记录](../ecs-context.md)，未登录 ECS。仓库实际有一个跟踪中的 `.xcodeproj`，但本方案继续以 `swiftc`、`Start QuotaBar.command` 和 `QuotaBarTests` 为构建与验收路径，不要求 Xcode。

## A. 接口与状态判定

**`GET https://66workshop.cn/api/relay-status/v1`**。仅接受 HTTPS、Bearer 请求头；不接受查询参数、请求体或写入方法。响应为 `application/json`，`Cache-Control: no-store`，无浏览器跨域开放。v1 各级对象都禁止额外字段。

```json
{
  "schema_version": 1,
  "observed_at": "2026-11-22T17:15:00Z",
  "snapshot_age_s": 2,
  "feishu": {
    "state": "ok",
    "reason": "ready",
    "last_heartbeat_at": "2026-11-22T17:14:51Z"
  },
  "wecom": {
    "state": "degraded",
    "reason": "pong_late",
    "last_heartbeat_at": "2026-11-22T17:14:47Z"
  },
  "certificate": {
    "state": "ok",
    "expires_at": "2027-02-20T17:15:00Z",
    "days_remaining": 90
  }
}
```

- `schema_version` 固定为 `1`；时间统一为 UTC RFC 3339；`snapshot_age_s` 为服务端出响应时计算的非负整数。两路 `last_heartbeat_at` 均可为 `null`。连接状态只允许 `ok / degraded / down / unknown`；`reason` 是服务端固定枚举，**不是**源文件里的任意字符串。
- 证书状态为 `ok / expiring / expired / unknown`；查不到时日期、天数均为 `null`。剩余天数按完整 24 小时向下取整；还有效但不足一天显示「不足 1 天」，过期显示「已过期」。证书单独标色，**不把证书临期当成转发器断线**。

### 两路连接：按下表从上往下判定

| 优先级 | 证据 | 判定 |
|---|---|---|
| 1 | 对应 unit 的 `ActiveState=failed/inactive` 已确认 | **红** `unit_down`；有效停机 lease 可标 `paused_by_lease`，仍表示 ECS 这一路已停 |
| 2 | unit 已确认处于 `activating/reloading/deactivating` | **黄** `transitioning` |
| 3 | unit 状态拿不到；当前实例的心跳缺失、坏 JSON、时钟异常或只读到重启前的样本 | **灰** `source_unavailable`；保留可信的历史时间只供参考 |
| 4 | 当前实例的可信心跳 **>180 秒**，或企微有效 pong 年龄 **>180 秒** | **红** `heartbeat_stale` / `pong_stale` |
| 5 | 心跳 **>90 至 180 秒**；飞书 `connection_ready=false`；企微处于经确认的重连状态，或有效 pong 年龄 **>60 至 180 秒**；有效停机 lease 与运行状态冲突 | **黄** `heartbeat_late` / `reconnecting` / `pong_late` / `lease_conflict` |
| 6 | unit `active`、心跳 **≤90 秒**、lease 无阻断且证据齐全；飞书连接就绪得到可信确认，或企微为 `subscribed` 且有效 pong 年龄 **≤60 秒** | **绿** `ready` |
| 7 | 未验证的状态值、缺必要字段、lease 语义无法判断 | **灰** `source_unavailable` |

**采集口径：**飞书用 `heartbeat.timestamp`，不把 `ecs-status: ACTIVE` 当连接证据，也不把原 `blocked_not_production_ready` 改写成生产就绪。部署前要确认 `connection_ready` 是否随 ACK 超时失效、`heartbeat_ack` 的时间是否真对应 ACK；证据不足就不出绿。企微用**同一打开文件**的 `fstat` mtime 作为估算心跳时间，有效 pong 年龄为 `last_pong_age + 文件年龄`；不把 monotonic 当日历时间。校验心跳属于当前启动／服务实例；未来超过 5 秒、重启前旧样本或时间源互相矛盾则不出绿。lease 只读已知状态、到期时间和 `ecs_stopped`；它不是实际停机证明，也不能覆盖红灯。**缺 lease 是否等于「未接管」、心跳/pong 正常周期是什么，必须拿脱敏样本确认后才冻结阈值。**

**生成与缓存：**独立 root systemd timer 每 **30 秒**运行一次有超时的 oneshot，仅读固定文件和 unit 属性。用限长、类型校验、同一文件描述符读取；不跟随不受信任的链接，不透传原 JSON。生成的白名单快照原子替换至独立 `/run/quotabar-relay-status/`，记录本机启动与单调时间用于新鲜度校验。无特权 API 只读快照，经受权限约束的 Unix socket 接 nginx；每个请求**不读转发器文件、不查 systemd、不探测转发器**。快照超过 **75 秒**或启动标识不符即拒绝。证书通过已确认归 nginx 所有的本机 443，以网站域名作 SNI 读取实际加载的公有叶证书，不读私钥；在 **14 天内**为临期。它不证明公网边缘或所有访问路径的证书一致。

| HTTP | 含义 |
|---|---|
| `200` | 快照有效；其中某路可为 `unknown`，也可为业务 `down` |
| `400` / `405` | 请求形状无效／不支持的方法；`405` 带 `Allow: GET` |
| `401` | 缺 token、格式不对或 token 无效；统一响应与 Bearer challenge |
| `429` | 限速，带 `Retry-After: 30` |
| `503` | 快照缺失、损坏、过期或状态服务不可用；nginx 将该 location 的 upstream `502/504` 归一为 `503` |

错误只返回固定短码，不带状态快照、异常堆栈或内部地址。全体数据拿不到时不返回伪造的红灯。

## B. 鉴权与限速

- 用安全随机源生成 **32 字节** token，编码为无填充 Base64URL，只授权这一个 GET。ECS 持久层只存 SHA-256 校验值，`root:root 0600`，父目录 `0700`；用 systemd `LoadCredential=` 将校验值交给独立 API 进程，不把 token 放入 nginx 配置或环境变量。合法候选摘要用 [`hmac.compare_digest`](https://docs.python.org/3/library/hmac.html#hmac.compare_digest) 比较等长字节；轮换期固定比较新旧两个槽，不因首槽命中提前返回。
- 计划轮换：原子换入新校验值、保留旧值最多 **24 小时**；只重启新增 API 服务使其载入，更新 Mini 钥匙串并验证新 token，再撤销旧值。怀疑泄漏时立即撤销，不留重叠期。原 token 经获批的安全渠道录入，不进入命令行参数、shell 历史、日志、截图或仓库。
- Mini 以登录钥匙串的 **Generic Password** 保存：service `app.quotabar.mac.relay-status`，account `66workshop.cn/relay-status-v1`。用 `SecItemCopyMatching` 限定登录钥匙串，后台线程读取，不同步、不导出；自动轮询不反复弹授权框。核验当前 `swiftc` 候选的钥匙串 ACL；不以「允许所有应用访问」绕过。参考 [Apple 钥匙串实现说明](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)。
- nginx 精确 location 使用独立 [`limit_req`](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html) 区：**每 IP 12 次/分钟，burst 4；全路由 60 次/分钟，burst 10；超限直接 429**。不做 IP 白名单，不信任客户端自带的 `X-Forwarded-For`。本路径关闭普通 access log，不记录 Authorization 或原始请求；指标仅保留状态码计数。首版不启用 fail2ban，避免共享 NAT 或变动 IP 误封。全路由配额可能被耗尽，但影响限定在状态接口，不能拖进转发器。

## C. ECS 影响、交付与回滚

- **服务器 PR 独立**：`server/relay-status/` 交付采集器、Unix socket API、systemd/nginx 配置模板、安装与回滚脚本、Python 测试。脚本默认预检；不在 CI 或本轮接触 ECS。App 另开分支与 PR，用同一 v1 合约的合成 fixture 对测，不依赖服务部署。
- **获批安装后**只新增独立安装目录、凭据和运行目录、采集 timer/oneshot、无特权 API unit，以及 nginx `http` 限速片段和该 HTTPS vhost 的精确 location。不改安全组或监听端口，不改 Next.js、8443、`relay.slice`、ecs13 文件权限及任何生产 unit。root 采集器隔离生产路径为只读并限制运行时间；API 仅能访问脱敏快照和运行时校验值，不能读取原状态目录或发起公网连接。
- 开销目标：采集每分钟两次，每次超时 **5 秒**；几 KB 快照，API 内存预算 **32 MiB**，并发有界。以上是设计预算，不是已测数据。共享 nginx 仍有配置冲突、reload 和流量风险；先核实 443 所有者、include 顺序与限速继承，在隔离环境验证，再由授权运维执行 `nginx -t` 和平滑 reload。采集或 API 挂掉只应让状态接口返回 `503`。
- **回滚**：按安装清单撤销新增 location 和限速片段，`nginx -t` 后 reload；验证网站仍正常、状态 URL 不再返回状态数据。再停用新增 timer/API，收回该功能的凭据及运行文件。若 nginx 配置检查失败，不 reload。不停、不启、不重启任何 ecs13 unit。

## D. App 端改动

| 文件 | 职责 |
|---|---|
| 新增 `RelayStatusModels.swift`、`RelayStatusClient.swift` | v1 解析与状态映射、上海时间格式化；固定 HTTPS URL，临时 `URLSession`，禁止重定向、缓存、Cookie 和自定义 TLS 放行 |
| 新增 `RelayStatusKeychain.swift`、`RelayStatusStore.swift` | 登录钥匙串读取；独立单飞轮询、退避和到期计时。不接入 `UsageSource`，不阻塞配额刷新 |
| 新增 `RelayStatusSection.swift`；改 `MenuPanel.swift`、`QuotaBarApp.swift` | 两路状态加证书一节，计入现有 `bottom` 测量；小灯挂在**同一个** `NSStatusBarButton` 上 |
| 构建与版本 | 启动脚本显式加入新 Swift 文件；`Info.plist`、面板版本、脚本内 plist/提示及跟踪的工程元数据同步为 **1.8.28／41**；同步安装文档与测试断言 |

**轮询：**启动及唤醒后即时调度；正常每 **30 秒 ±3 秒**，请求总超时 **5 秒**。面板打开时若距上次尝试 ≥15 秒，可触发一次；不绕过单飞或退避。超时、5xx、坏响应走 **30 → 60 → 120 → 300 秒**带抖动退避；`429` 至少等 `Retry-After`，缺失时用 60 秒下限。`401` 暂停自动请求，更新钥匙串后手动刷新；离线期间不持续请求，网络恢复后重试但尊重服务端限速。成功后恢复正常节奏。

**显示：**首次、离线、超时、鉴权失败、限速、TLS/解析错误或快照过期，立即灰灯，面板显示具体原因。旧心跳可留在内存标「上次记录」，绝不沿用旧颜色。App 以响应的 `snapshot_age_s` 加请求耗时和本地单调经过时间执行 75 秒到期，不依赖 Mac 墙钟。有效快照汇总优先级为**红 > 黄 > 灰 > 绿**；只有两路都绿，菜单栏才绿。

**菜单栏：**用固定约 **8–10 pt** 的小图像槽，彩色实心／灰色空心，不往 `attributedTitle` 塞 emoji。保留 `G/O/AC/GO/D/E/M` 的文字、顺序、配额逻辑与原点击区域，并加 tooltip 和 VoiceOver 状态文本。系统菜单栏空间不足仍可能隐藏整个项目；验收要查刘海屏和拥挤布局，不能通过裁 token 达标。

## E. UI 草图与 PNG 预览

**设计简报：**沿用现有 **448 pt** 单层 `GlassBackdrop`（`.hudWindow`、`.behindWindow`），不套第二张玻璃卡。优先读状态，其次读心跳；右列固定、数字等宽、状态旁有文字。短屏复用现有滚动降级路径，状态变化不另触发布局跳动。

```text
菜单栏  [●  G 21 · O 15 · AC 19 · GO 35 · D 62 · E 41 · M 58]

┌────────────────────────────── QuotaBar v1.8.28 ┐
│  …现有用量…                                     │
│  转发器连接                       最后心跳 · 上海 │
│  ● 飞书    正常                   11-23 01:14:51 │
│  ● 企微    降级                   11-23 01:14:47 │
│    网站证书                          剩余 90 天 │
│  …现有磁盘／内存／底栏…                           │
└────────────────────────────────────────────────┘
```

新增 `QuotaBarTests/check-relay-status.sh`，按 `GoogleCheck.swift` 的模式，以 `swiftc -D QUOTABAR_COMPONENT_CHECK` 编译独立测试入口。用合成数据构造实际 SwiftUI 面板内容，`NSHostingView` 离屏布局、`cacheDisplay` 输出 PNG；不实例化 App delegate 或真实 `UsageStore`，不联网、不读钥匙串、不运行启动脚本。检查浅/深色、绿黄红灰、长错误文案、短窗滚动、尺寸和非空像素。输出前检查外盘真实挂载、可写和容量；现有 GO 候选脚本有专用 worktree 限制，不绕过。离屏使用确定性背景，**不能验收真实桌面背后的玻璃合成或菜单栏交互**。

## F. 开源参考对比

| 项目 | 数据获取 | 鉴权 | 三色语义 | 刷新／退避 | 借鉴 |
|---|---|---|---|---|---|
| [exelban/stats](https://github.com/exelban/stats) | 本机系统指标，按模块采样 | 本机采样无远端 token | 指标阈值，不是连接三色 | [模块可设采样周期](https://github.com/exelban/stats/blob/master/Modules/Sensors/settings.swift) | 菜单栏只放信号，详情进面板 |
| [CodexBar](https://github.com/steipete/CodexBar/blob/main/docs/status.md) | 独立拉取供应商状态源 | 公共状态源不复用配额凭据 | 事故级别；未知/未取到为灰 | [固定或自适应刷新、请求合并](https://github.com/steipete/CodexBar/blob/main/docs/refresh-loop.md) | 状态与配额独立，过时不冒充正常 |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma/wiki/Badge) | 服务端探测；公开 status page 或 SVG badge | 已发布页面/badge 不要求私有读 token | 常规状态 badge 主要是 Up/Down；证书 badge 可设临期阈值 | [监测间隔与重试间隔](https://github.com/louislam/uptime-kuma/blob/master/server/model/monitor.js) | 借证书阈值，不照搬公开暴露 |
| [Gatus](https://github.com/TwiN/gatus#api) | 定期探测；`GET /api/v1/endpoints/statuses` 读 JSON | 依部署，可配 Basic/OIDC；外部上报 Bearer 不是读 API 的凭据 | 单条结果主要是成功/失败 | 探测间隔、超时可配；客户端退避自定 | 读接口与采集分离 |
| [Healthchecks.io](https://healthchecks.io/docs/apiv2/) | 心跳 push；管理 API 查询 | 只读 `X-Api-Key`；读响应省略写入 URL | Up／Late／Down，另有 New／Paused | 按周期和 [Grace Time](https://healthchecks.io/docs/) 判迟到，不靠客户端重试 | 最接近本案：宽限期与只读字段裁剪 |

## G. 测试计划

- **服务器 Python `unittest`：**注入时钟、文件和 systemd fixture。覆盖白名单（用假 PID／secret／路径做泄露断言）、阈值 `60/90/180/75` 的等号与两侧、缺文件、截断/超大/坏 JSON、原子替换、重启残留、企微 mtime、lease 到期与冲突、证书临期与过期、token 缺失/错误/双槽轮换。验证比较使用定时安全原语且不提前退出，不用不稳定的微秒基准假装证明安全。
- **服务器隔离集成：**用合成输入验证 socket 权限、认证、405/429/503、无缓存、无泄露、采集停摆及回滚；对比生产配置模板外无变更。不得为测试停 ecs13。
- **App：**注入 transport、Keychain provider 和时钟，测解析、未知版本、色灯汇总、快照到期、断网/超时/401/429、单飞和唤醒。以纽约、UTC 两种本机测试时区验证**同一 UTC 输入得到相同上海时间**，不改系统时区。运行现有 token/PanelFit 回归和离屏 PNG 测试；后续获批才做真实菜单栏与材质审查。

## H. P0／P1 自查

- **P0｜不干预生产：**确认安装及回滚只作用于新功能；无 ecs13 写入、重启、探测流量、ACL 松绑或新 TCP 端口。nginx 配置冲突、负载或回滚未验证，不部署。
- **P0｜不误报绿：**先确认飞书 ACK 时效、企微状态与 pong 周期、mtime 写入方式、lease 缺失/过期语义；重启、快照陈旧、认证失败及 TLS 失败都不能保绿。
- **P0｜不泄露：**检查响应、错误页、nginx/API 日志、脚本和 App 日志；验证 socket 不可越权直读、token 不随重定向转发、轮换后旧 token 确实失效。
- **P1｜不挤占现有功能：**实测菜单栏 token、VoiceOver、短屏滚动、颜色对比与稳定布局；验证签名/重建后的钥匙串行为和服务器实际资源预算。离屏通过不代替真人视觉验收。

**本轮交付：方案。未改文件、未运行构建或测试、未生成 PNG、未创建分支或 PR。`NO_COMMIT` · `NO_PUSH` · `NO_DEPLOY` · 未重启任何服务。**

