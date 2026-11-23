# QuotaBar Relay Status · 服务器组件

**仅本地候选，未部署。** 本目录不改 App、ecs13、`relay.slice`、网站监听端口、安全组或源文件权限。需要辉哥单独批准部署与回滚。绿灯只说明 ECS 观察到连接证据，**不**代表飞书/企微消息端到端送达，也不改变 `blocked_not_production_ready`。

## 架构与接口

- **采集器**：root oneshot，每 30 秒由独立 timer 触发，整次超时 5 秒。两次只读 `systemctl show` 将心跳夹在同一 unit 实例之间；检查 PID、启动单调时间与心跳时间。仅打开两份 `heartbeat.json` 和固定 ecs13 lease（另读本功能策略和 boot ID），不使用 `ecs-status.json`。逐级固定目录 fd，不跟随符号链接，拒绝硬链接、非普通文件、非预期权限和超过 64 KiB 的输入。JSON 严格解析；同一打开文件的 `fstat` 提供企微 mtime。没有对转发器发请求。
- **快照**：`/run/quotabar-relay-status/snapshot.json`，同目录临时文件 → fsync → 原子替换，`root:quotabar-status 0640`，上限 4 KiB。内含 boot ID 和 `CLOCK_BOOTTIME`，两者不出现在 HTTP。内容只允许公开 v1 字段及固定枚举；API 重新严格验证每层的键、类型和状态，不透传任何源字段或异常。
- **API**：静态非 root 用户 `quotabar-status`，无 Linux capability；只读快照与 systemd `LoadCredential=` 提供的 SHA-256 校验值，屏蔽原状态路径和持久凭据目录。地址族仅 AF_UNIX、`PrivateNetwork=yes`，4 个并发处理槽、2 秒总读头时限、8 KiB 请求头上限、32 MiB 内存预算（未实测）。套接字 `/run/quotabar-relay-status/api/status.sock` 为 `quotabar-status:www-data 0660`，父目录为同一所有者和组的 `2750`；nginx 组可连 socket，但不能读快照。API 没有请求日志，也不输出 Authorization。
- **nginx**：现有 HTTPS 443 vhost 的精确 `/api/relay-status/v1`，只把必要头交给 Unix upstream。每 IP **12r/m、burst 4**，全路由 **60r/m、burst 10**，立即拒绝超限。无 IP 白名单，不用请求的 X-Forwarded-For；必须确认继承的 real-IP 设置只信可信代理。该 location（含专用错页）关 access log、丢弃 error log；上游全局日志、诊断配置或选中 location 之前的 nginx 协议错误不受这个片段管控，必须单独审计。精确路由要求规范 Host 与 TLS SNI。query/别名及显式非空 body framing 在 rewrite 阶段拒绝；不带长度的 HTTP/2 DATA 在 nginx 缓冲层限长：超过一字节转固定 400，其余保留 nginx 计算出的实际长度送 API 拒绝。不可再关闭请求体转发或覆盖 upstream 的长度头。
- **证书**：采集器只连 `127.0.0.1:443`，SNI 固定为 `66workshop.cn`，从实际握手的公开叶证书获得 notAfter（本机现有 `openssl x509` 经 stdin 解析，不读私钥）。采集器因此不能用 PrivateNetwork；systemd IP 白名单只准回环，代码固定端口。探针可观察已过期的证书，不验证信任链、主机名覆盖或公网边缘；它不是 TLS 客户端安全检查。无法取得日期时证书独立灰，不影响两路状态。

只接收 GET + Bearer；无 query、请求体、重定向或 CORS。公开 v1 字段为 `schema_version`、UTC `observed_at`、整数 `snapshot_age_s`、`feishu`、`wecom`、`certificate`。200 可含灰/红状态；处理到本路由时错误为固定 JSON：400 `bad_request`、401 `unauthorized`（Bearer challenge）、405 `method_not_allowed`（`Allow: GET`）、429 `rate_limited`（`Retry-After: 30`）、503 `service_unavailable`。upstream 502/504 归一为 503；nginx 协议层拒绝（例如超大 request line）可能先于路由，不能用本片段保证错误形状。响应不可缓存。

200 响应另带 `QuotaBar-Green-For-Ms`：从服务端判定时刻起、响应内所有仍为绿的行中最短的剩余有效期（整毫秒向下取整，范围 0–75000）。只有一路为绿时仍返回该行的有效期；无绿行或不足 1 ms 时为 0。它受心跳、pong、lease 和快照新鲜期约束，不改变 v1 JSON，也不公开是哪条证据限制了时长或其原始值。客户端从本地单调请求起点扣除已花费的时间，缺头不保绿。

## 阈值与确认门槛

**待脱敏样本确认**（常量在 `common.py`，不因缺数据下调门槛）：

| 证据 | 绿 / 正常 | 黄 / 临期 | 红 |
| --- | --- | --- | --- |
| 当前实例心跳 | ≤90s | >90 且 ≤180s | >180s |
| 企微有效 pong 年龄 | ≤60s | >60 且 ≤180s | >180s |
| 本机叶证书剩余时间 | >14 天 | >0 且 ≤14 天 | ≤0；按完整 24 小时向下取整 |
| 快照时效 | 同一 boot、年龄 ≤75s 可读 | — | >75s、未来、boot 不符或缺损 → HTTP 503，不造业务红灯 |

unit 确认 failed/inactive 优先判红；活跃的有效停机 lease 仅解释已停，或对运行中的实例产生冲突黄，不替代观测。unit 过渡为黄。当前实例心跳缺失、来源不可用、时间矛盾、未来 >5 秒等为灰；可保留可信历史的时间，但不沿用旧绿。企微有效 pong 年龄是 `last_pong_age + 文件年龄`；`source_mono - last_pong_age >= unit.started` 不用墙钟容差。同文件的 mtime 与源 monotonic 对照，不能将 monotonic 当日历时间。飞书 timestamp 和 mtime 分别不得超前 5 秒以上，再比较二者差值。API 先按采集时刻验证绿灯证据，再以单调时钟经过的时间更新可信证据的年龄。即使 75 秒快照 TTL 尚未到期，也先判心跳或 pong 是否超过 180 秒转红，再判绿灯是否应转黄。已确认的停机、unit 过渡和来源未知状态不变，快照本身不改写。飞书还需 `connection_ready=true` 且为已验证的 `heartbeat_ack`。未知的 lease 或连接证据不能被当作「无阻断」或正常。

`source-policy.example.json` 的开关全关。在 `/etc/quotabar-relay-status/source-policy.json` 缺失或无效时采用此保守默认。可观察到可信超时/停机时仍会按规则显示黄/红。**只在脱敏样本与负责人确认后**，才可将对应项加到 root:root 0600 策略文件：

1. 飞书 ACK 是否实际刷新记录、ACK 超时后 `connection_ready` 是否及时失效、fstat mtime 与 timestamp 是否同一写入周期。
2. 企微 `monotonic` 是否与宿主 CLOCK_MONOTONIC 同基准，mtime 是否确实来自该样本的形成时间，文件是否按心跳写而非其他用途重写；`last_pong_age` 计时口径和经证实的 reconnect 枚举。不要猜 `boottime` 字段的含义。
3. lease `LEASE`、`ecs_stopped`、`expires_at` 的实际语义（过期时间仅接受 epoch 秒或整秒 UTC RFC 3339）。缺文件和已过期是否分别代表清除，要各自确认；读失败/破损绝不等同于缺文件。核实文件路径各级是真实目录，不能为工具放宽源权限。

## 部署闸门（须辉哥批准）

1. **先隔离验收，不触碰 ECS。** 按 [Ubuntu 22.04 隔离验收](tests/ISOLATED-LINUX.md) 使用匹配版本和合成输入。缺失、未通过或不对应当前候选的隔离记录会阻断安装。
2. **获批后由运维准备**：预置专用系统用户及同名组 `quotabar-status`（无登录 shell、无其他组），预置 `/etc/quotabar-relay-status` 为 root:root 0700。只将校验文件以 root:root 0600 原子置入 `verify.json`，按需加入已批准的 `source-policy.json`。不修改转发器账号、组和 ACL。必要时可在隔离机验证 `systemd-analyze verify` 等静态检查；不因检查失败放宽 sandbox。
3. **共享 nginx 的唯一手动接线**（先评审 vhost、include 顺序、已有 location、缓存与继承的日志/鉴权/安全头）。空 glob 先检查语法；不可把 HTTPS 片段挂到 HTTP vhost、其他域名或默认 vhost。模板如下：
   - 在现有 `http { }` 中一次：`include /opt/quotabar-relay-status/nginx/http/*.conf;`
   - 只在现有 `66workshop.cn` 的 HTTPS 443 server 中一次：`include /opt/quotabar-relay-status/nginx/https/*.conf;`

   获批窗口内由运维确认当前线上配置与待审磁盘配置一致（仅允许上述两个空 include 的惰性接线）。`nginx -T` 只读磁盘，**不是已加载配置的证明**。审查 systemd nginx unit/启动参数、继承的 rewrite、real-IP、日志、鉴权、安全头、以及 `-T` 不展开的证书等外部引用。配置、外部引用和其它 nginx 发布须在检查至 reload 窗口冻结；不要将脚本的功能锁当作共享站点发布锁。
4. **只接受已批准配置版本**：首次安装在空 slot 时，在目标主机的获批窗口执行 `/usr/bin/python3 -IB nginx-gate.py inspect`；已完成回滚的重装可用 `inspect-retired` 保留 410 地采集同口径摘要。命令只输出五个摘要，不写批准文件。确认完整配置、systemd 基线和 launcher 后，把输出及核准的隔离报告原始字节的 `isolation_report_sha256` 写入专用目录中 root:root 0600 的 `nginx-review.json`；隔离报告为同目录的 `isolation-pass.json`。不要把配置内容或凭据写进证据。脚本以完整 `nginx -T` 文件序列、相同 launcher 和候选摘要验证基线，且目标 deb 包版本和架构摘要必须与隔离机相符，再检查**唯一**合法 include 上下文，添加后只允许这两个文件的精确字节差异；不支持/无法证明的 nginx 拓扑中止。当前仅支持 Ubuntu 默认 nginx 启停参数、默认配置路径。不能靠为了通过而重签未评审磁盘配置。
5. **先 dry-run，再单独获批执行**：`./install.sh` 和 `./rollback.sh` 默认不调用 systemd/nginx、不写文件。实际安装 `./install.sh --apply` 先检查审查门槛及既有文件，再启动新增组件，验证快照和 socket；紧接 reload 前再次验证完整配置、两个片段和 include 上下文。它不编辑共享 vhost，也不会启停 `relay-*`。安装后用独立新连接确认网站和状态路由，不能用 reload 命令退出码代替。


### Token 建立、轮换与撤销

单独获批后，在**运行 QuotaBar 的 Mini 上用对应登录用户**操作，不用 sudo。将 `OUTPUT_DIR` 指向一个新建、所有者为当前用户、权限 0700 且路径各级无链接及无组/全员写权限的绝对目录；然后在仓库根目录利用本机现有 macOS SDK 编译钥匙串写入助手：

```sh
build="$(mktemp -d "${TMPDIR%/}/qb-keychain.XXXXXX")" &&
xcrun --sdk macosx swiftc -module-cache-path "$build/module-cache" \
  server/relay-status/write-login-keychain.swift -o "$build/write-login-keychain" &&
  python3 -B server/relay-status/generate-token.py \
    --keychain-writer "$build/write-login-keychain" --output-dir "$OUTPUT_DIR"
```

仅用上面从已审源代码编译的助手。它通过匿名管道接收不填充的 Base64URL token（32 字节随机源），写入登录钥匙串的指定 Generic Password 项（service `app.quotabar.mac.relay-status`、account `66workshop.cn/relay-status-v1`），不读取旧密码、不放宽 ACL。核验当前 QuotaBar 候选的读取授权；不选「允许所有应用访问」。普通磁盘输出只有新建的 **0600** `verify.json`（仅校验值及轮换元数据），不创建明文文件，也不通过命令参数、环境变量或输出传递 token。获批后只传 `verify.json` 给 ECS。若命令失败或中断，不发布该次输出，先核对钥匙串和校验文件的状态。

计划轮换用新输出目录、`--previous-credential <旧verify.json的绝对路径> --overlap-hours <1到24>`，计时从生成开始；新旧候选都做两次等长 `hmac.compare_digest`，旧槽到期即拒绝。原子上传校验文件后，仅重启新增的 `quotabar-status-api.service` 以载入凭据。验证新 token 后，将旧槽 `previous_sha256`、`rotated_at`、`previous_until` 原子置为 null，重新加载该 API，再验证旧 token 为 401。怀疑泄漏时直接无重叠生成并撤销；轮换期间保持可信系统时钟。不要让实际 token 出现在测试、curl 参数或验证报告里。

### 回滚

1. **退役路由**：获批执行 `./rollback.sh --remove-route`。记录旧 worker，隔离校验完整退役配置，再原子发布专用 410 并重验基线后请求 reload；旧 worker 排空前限速片段可以留在盘上。即使 reload 返回成功，也不碰 timer、API、运行文件或凭据。检查失败不 reload；遇到失败或中断不猜测在线配置，保留后端。
2. **独立验收**：确认同一 nginx master 的旧 workers 已全部退出。分开建立新 TLS 连接，确认网站关键页正常，且原状态 URL 在**不带 Authorization** 时返回专用 410、固定正文 `{"error":"status_retired"}` 和 `Cache-Control: no-store`。另用获准的 Unix socket 直连独立确认后端仍健康。404 fallback、502、503 或已挂掉的 API 都不能当退役证据。仅保留脱敏时间、状态、基线摘要和验收人。
3. **拆后端**：只有上述确认通过后才执行 `./rollback.sh --remove-backend --confirmed-live RECEIPT`。再次核对完整基线、回执与 worker 代际后，才停用本功能 unit、删除运行文件、摘要和限速片段。保留专用 410、用户、源策略、锁和审查证据，防止旧客户端的 Authorization 落入网站 fallback。再次确认网站正常、旧 URL 仍返回同一 410。没有验收或有漂移就保持后端。

### 重装

无需也不要删除 410。完成两阶段回滚后，确认只剩精确的退役目录、HTTP slot 空且无残留本功能 unit 或运行目录。重新预置凭据摘要，按当前候选重走获批闸门，再执行 `./install.sh --apply`。脚本先准备并核验快照、API socket 和隔离候选，之后先发布不影响 410 的限速片段，最后原子替换 410 为代理路由，再重验并请求 reload。用新连接确认网站和状态路由，不能用 reload 退出码代替。

安装在 reload 前失败时，优先检查暂存片段，之后仍按两阶段回滚。硬中断可能遗留专用目录内的暂存文件；先核实归属、日志与 live nginx，再续阶段 1。若核准配置已变化，重新走审查流程，不硬删或绕过。任何阶段都不触碰生产转发器。

## 测试与遗留风险

从仓库根目录执行 `python3 -B server/relay-status/tests/run.py`。入口将整个测试套件的临时文件放在一个自动清理的私有目录：优先用路径够短、祖先可信的 `TMPDIR`，否则使用符合相同约束的 `$HOME`（例如 Ubuntu 默认 /tmp 为 1777 时）；两者都不合适时，先指定满足条件且在仓库外的 `TMPDIR`。1777 祖先仍是负例，生产校验不变。测试用合成输入、Unix socket、本机证书探针 mock；没有 TCP 请求或真实钥匙串访问。nginx 的传输层行为不由 Python 测试推断；429/502/504 的路由映射测试仅检查模板，不是线上限速验收。

仍须隔离 Linux 证实 systemd 沙箱、证书和 socket uid/gid、nginx 完整配置/继承、真实限速与回滚、5 秒采集和 32 MiB 进程预算。全局额度在大量请求或共享 NAT 下可能先耗尽，但仅影响该路由；不加 fail2ban 或 IP 锁定。30 秒轮询不保证捕捉所有瞬时断线，且采集器失联最多要到 75 秒才拒绝快照。生产源语义未核实前不开放相应绿灯开关。以上不构成生产就绪或部署批准。
