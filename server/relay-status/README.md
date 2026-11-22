# QuotaBar Relay Status · 服务器组件

**仅本地候选，未部署。** 本目录不改 App、ecs13、`relay.slice`、网站监听端口、安全组或源文件权限。需要辉哥单独批准部署与回滚。绿灯只说明 ECS 观察到连接证据，**不**代表飞书/企微消息端到端送达，也不改变 `blocked_not_production_ready`。

## 架构与接口

- **采集器**：root oneshot，每 30 秒由独立 timer 触发，整次超时 5 秒。两次只读 `systemctl show` 将心跳夹在同一 unit 实例之间；检查 PID、启动单调时间与心跳时间。仅打开两份 `heartbeat.json` 和固定 ecs13 lease（另读本功能策略和 boot ID），不使用 `ecs-status.json`。逐级固定目录 fd，不跟随符号链接，拒绝硬链接、非普通文件、非预期权限和超过 64 KiB 的输入。JSON 严格解析；同一打开文件的 `fstat` 提供企微 mtime。没有对转发器发请求。
- **快照**：`/run/quotabar-relay-status/snapshot.json`，同目录临时文件 → fsync → 原子替换，`root:quotabar-status 0640`，上限 4 KiB。内含 boot ID 和 `CLOCK_BOOTTIME`，两者不出现在 HTTP。内容只允许公开 v1 字段及固定枚举；API 重新严格验证每层的键、类型和状态，不透传任何源字段或异常。
- **API**：静态非 root 用户 `quotabar-status`，无 Linux capability；只读快照与 systemd `LoadCredential=` 提供的 SHA-256 校验值，屏蔽原状态路径和持久凭据目录。地址族仅 AF_UNIX、`PrivateNetwork=yes`，4 个并发处理槽、2 秒总读头时限、8 KiB 请求头上限、32 MiB 内存预算（未实测）。套接字 `/run/quotabar-relay-status/api/status.sock` 为 `quotabar-status:www-data 0660`，父目录为同一所有者和组的 `2750`；nginx 组可连 socket，但不能读快照。API 没有请求日志，也不输出 Authorization。
- **nginx**：现有 HTTPS 443 vhost 的精确 `/api/relay-status/v1`，只把必要头交给 Unix upstream。每 IP **12r/m、burst 4**，全路由 **60r/m、burst 10**，立即拒绝超限。无 IP 白名单，不用请求的 X-Forwarded-For；必须确认继承的 real-IP 设置只信可信代理。该 location（含专用错页）关 access log、丢弃 error log；上游全局日志、诊断配置或选中 location 之前的 nginx 协议错误不受这个片段管控，必须单独审计。精确路由里的 query/别名和非空 body framing 在 rewrite 阶段直接拒绝，不消耗限速额度，也不到 API。
- **证书**：采集器只连 `127.0.0.1:443`，SNI 固定为 `66workshop.cn`，从实际握手的公开叶证书获得 notAfter（本机现有 `openssl x509` 经 stdin 解析，不读私钥）。采集器因此不能用 PrivateNetwork；systemd IP 白名单只准回环，代码固定端口。探针可观察已过期的证书，不验证信任链、主机名覆盖或公网边缘；它不是 TLS 客户端安全检查。无法取得日期时证书独立灰，不影响两路状态。

只接收 GET + Bearer；无 query、请求体、重定向或 CORS。公开 v1 字段为 `schema_version`、UTC `observed_at`、整数 `snapshot_age_s`、`feishu`、`wecom`、`certificate`。200 可含灰/红状态；处理到本路由时错误为固定 JSON：400 `bad_request`、401 `unauthorized`（Bearer challenge）、405 `method_not_allowed`（`Allow: GET`）、429 `rate_limited`（`Retry-After: 30`）、503 `service_unavailable`。upstream 502/504 归一为 503；nginx 协议层拒绝（例如超大 request line）可能先于路由，不能用本片段保证错误形状。响应不可缓存。

## 阈值与确认门槛

**待脱敏样本确认**（常量在 `common.py`，不因缺数据下调门槛）：

| 证据 | 绿 / 正常 | 黄 / 临期 | 红 |
| --- | --- | --- | --- |
| 当前实例心跳 | ≤90s | >90 且 ≤180s | >180s |
| 企微有效 pong 年龄 | ≤60s | >60 且 ≤180s | >180s |
| 本机叶证书剩余时间 | >14 天 | >0 且 ≤14 天 | ≤0；按完整 24 小时向下取整 |
| 快照时效 | 同一 boot、年龄 ≤75s 可读 | — | >75s、未来、boot 不符或缺损 → HTTP 503，不造业务红灯 |

unit 确认 failed/inactive 优先判红；活跃的有效停机 lease 仅解释已停，或对运行中的实例产生冲突黄，不替代观测。unit 过渡为黄。当前实例心跳缺失、来源不可用、时间矛盾、未来 >5 秒等为灰；可保留可信历史的时间，但不沿用旧绿。企微有效 pong 年龄是 `last_pong_age + 文件年龄`；同文件的 mtime 与源 monotonic 对照，不能将 monotonic 当日历时间。飞书需可信的当前实例 timestamp、同文件 mtime 相符、`connection_ready=true` 且为已验证的 `heartbeat_ack`。未知的 lease 或连接证据不能被当作「无阻断」或正常。

`source-policy.example.json` 的开关全关。在 `/etc/quotabar-relay-status/source-policy.json` 缺失或无效时采用此保守默认。可观察到可信超时/停机时仍会按规则显示黄/红。**只在脱敏样本与负责人确认后**，才可将对应项加到 root:root 0600 策略文件：

1. 飞书 ACK 是否实际刷新记录、ACK 超时后 `connection_ready` 是否及时失效、fstat mtime 与 timestamp 是否同一写入周期。
2. 企微 `monotonic` 是否与宿主 CLOCK_MONOTONIC 同基准，mtime 是否确实来自该样本的形成时间，文件是否按心跳写而非其他用途重写；`last_pong_age` 计时口径和经证实的 reconnect 枚举。不要猜 `boottime` 字段的含义。
3. lease `LEASE`、`ecs_stopped`、`expires_at` 的实际语义（过期时间仅接受 epoch 秒或整秒 UTC RFC 3339）。缺文件和已过期是否分别代表清除，要各自确认；读失败/破损绝不等同于缺文件。核实文件路径各级是真实目录，不能为工具放宽源权限。

## 部署闸门（须辉哥批准）

1. **先隔离验收，不触碰 ECS。** 使用 Ubuntu 22.04 同版本的 Python/systemd/nginx、合成文件和模拟 unit。核对现有二进制、443 确属 nginx、loopback:443 SNI 是同一网站、systemd 的 mount 与 IP 隔离 BPF 实际生效、源文件 UID/mode、www-data worker 组（不能为此改生产 worker 用户）。验收权限、速率（分开压每 IP 与全局）、401/405/429/503、安装前后 `nginx -t`、回滚演练、日志与共享网站无回归。用不同非特权用户实际验证 socket/快照/凭据权限以及无请求/鉴权泄露。
2. **获批后由运维准备**：预置专用系统用户及同名组 `quotabar-status`（无登录 shell、无其他组），预置 `/etc/quotabar-relay-status` 为 root:root 0700。只将校验文件以 root:root 0600 原子置入 `verify.json`，按需加入已批准的 `source-policy.json`。不修改转发器账号、组和 ACL。必要时可在隔离机验证 `systemd-analyze verify` 等静态检查；不因检查失败放宽 sandbox。
3. **共享 nginx 的唯一手动接线**（先评审 vhost、include 顺序、已有 location、缓存与继承的日志/鉴权/安全头）。空 glob 先检查语法；不可把 HTTPS 片段挂到 HTTP vhost、其他域名或默认 vhost。模板如下：
   - 在现有 `http { }` 中一次：`include /opt/quotabar-relay-status/nginx/http/*.conf;`
   - 只在现有 `66workshop.cn` 的 HTTPS 443 server 中一次：`include /opt/quotabar-relay-status/nginx/https/*.conf;`

   脚本只验证片段被载入，不能证明所处 vhost 是唯一正确的。审查继承的 server 级 rewrite、real-IP、日志、自定义 error_page 和安全头（nginx 旧版本的 `add_header` 继承会受本地声明影响）；如果不能保持 HTTPS/vhost 边界、HSTS 等原安全要求，**不执行上线**。不得为通过验收禁用原网关保护。
4. **先演练，再执行**：`./install.sh` 和 `./rollback.sh`（也可显式 `--dry-run`）仅打印计划；不调用 systemd 或 nginx，不写文件。获批由 root 执行 `./install.sh --apply`：安装前 `nginx -t` 失败即中止；发现同名安装目标也中止。先启新增 collector、API/timer，检查快照与 socket 权限，再载入两个片段，通过 `nginx -t` 后只平滑 reload nginx。脚本不会编辑网站 vhost 文件或 stop/start/restart 任一 `relay-*` unit。上线后独立验收真实 HTTPS、状态口与网站；检查 nginx reload 生效，而非只看退出码。验收失败按下方路径回滚。

### Token 建立、轮换与撤销

在可信本地机器准备一个所有者为当前用户、权限 0700、无链接的绝对目录，再运行 `./generate-token.py --output-dir <绝对目录>`。输出仅是两个新建 **0600** 文件：`token`（32 字节随机源、不填充的 Base64URL）和 `verify.json`（仅校验值及轮换元数据）。不把 token 写入命令行、stdout、历史、日志、仓库、截图或 nginx。通过获批安全渠道录入 Mini 钥匙串；ECS 上只保存 `verify.json`。不要把整个 bundle 复制到 ECS。

计划轮换用新输出目录、`--previous-credential <旧verify.json的绝对路径> --overlap-hours <1到24>`，计时从生成开始；新旧候选都做两次等长 `hmac.compare_digest`，旧槽到期即拒绝。原子上传校验文件后，仅重启新增的 `quotabar-status-api.service` 以载入凭据。验证新 token 后，将旧槽 `previous_sha256`、`rotated_at`、`previous_until` 原子置为 null，重新加载该 API，再验证旧 token 为 401。怀疑泄漏时直接无重叠生成并撤销；轮换期间保持可信系统时钟。不要让实际 token 出现在测试、curl 参数或验证报告里。

### 回滚

运行 `./rollback.sh` 看计划；获批后 root 执行 `./rollback.sh --apply`。它先移走本功能两个 nginx 片段，检查并 reload nginx；配置检查或 reload 报错会恢复片段，并保留状态 unit。成功后只停止/禁用本功能新增的 timer/API/collector，删除对应 unit、tmpfiles、安装包、运行文件与 SHA-256 凭据；保留专用用户、已审核策略、空 include 和锁文件。务必复查网站和状态 URL，另行批准后可清理空 include/专用身份。任何阶段都不触碰生产转发器。

如果脚本在 reload 前失败，安装脚本将启用片段移回 staging；可用获批回滚收回已阶段性安装的文件。若 reload 结果不明确，**先保留 API 并核实 live nginx**。如果回滚在成功 reload 后中断并留下 `rollback-*.conf`，脚本会拒绝盲目重试；运维先核对 live nginx 不再挂路由和暂存文件归属，再将暂存文件归入同一安装树下的 `staged-*.conf`、重新执行回滚。共享配置修改、语法失败或未知文件不能强删。诊断请在本机做，不输出生产配置或凭据。

## 测试与遗留风险

从仓库根目录执行 `python3 -m unittest discover -s server/relay-status/tests -v`。测试用合成输入、Unix socket、本机证书探针 mock；没有 TCP 请求。nginx 的传输层行为不由 Python 测试推断；429/502/504 的路由映射测试仅检查模板，不是线上限速验收。

仍须隔离 Linux 证实 systemd 沙箱、证书和 socket uid/gid、nginx 完整配置/继承、真实限速与回滚、5 秒采集和 32 MiB 进程预算。全局额度在大量请求或共享 NAT 下可能先耗尽，但仅影响该路由；不加 fail2ban 或 IP 锁定。30 秒轮询不保证捕捉所有瞬时断线，且采集器失联最多要到 75 秒才拒绝快照。生产源语义未核实前不开放相应绿灯开关。以上不构成生产就绪或部署批准。
