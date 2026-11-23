# 上线前闸门：Ubuntu 22.04 隔离验收

**本轮未执行；不在 ECS 补测。** 使用无外网出口的可销毁 Ubuntu 22.04 VM，真实 systemd (PID 1)，与拟部署环境相同的 nginx/Python/systemd 包版本、内核/沙箱能力；只使用合成证书、摘要、源文件和 unit。容器里的普通用户 socket 或 mock 不计入通过。记录 OS、包版本、候选摘要、时间、各项结果和审核人，不记录 token、私有请求、生产配置。若没有该环境，标 `BLOCKED`。

## 合成站点

- 单独的 VM；无挂载生产目录、主机 socket、ECS 凭据/网络。确认 nginx 是本机 443 的唯一所有者。创建 root:root 0600 的 `/etc/quotabar-relay-status/ISOLATED-TEST-VM`，内容仅 `DISPOSABLE`。这个标记**不会**被生产安装脚本用于跳过检查。
- 使用默认 systemd nginx launcher，worker 为 `www-data`。在 `http` 级接入限速空 glob；创建仅监听 `443 ssl http2`、只声明 `server_name 66workshop.cn` 的合成 vhost，接入 HTTPS 空 glob。TLS 证书为仅在该 VM 使用的带对应 SAN 的合成自签叶，探针信任文件为 `/etc/nginx/quotabar-lab.crt`。用 `location = / { return 200 "quotabar-lab-site"; }` 和 `location / { return 404 "quotabar-lab-baseline-404"; }` 表示批准站点和非状态接口回退，另加独立默认 vhost。活跃路由模板和 systemd unit 必须与候选一致。
- 预置专用身份和配置目录，凭据只用探针的合成 Bearer（43 个 `A`；仅 VM 测试用）的 SHA-256。首轮可用手动安装相同 unit/snippets 验证数据路径；演练实际安装脚本时，使用仅在这台隔离 VM 生成的配置基线及**合成审批输入**测试脚本执行路径，不把它当验收报告、不带出 VM。在空 slot 时用 `nginx-gate.py inspect` 记录候选摘要与本机运行时包版本/架构摘要。真正 `isolation-pass.json` 必须在所有项均实测通过后由验收人生成；保持同一候选源不加旁路。收回或重置 VM 用 VM 快照，不接触任何生产账号或 unit。

## 必跑矩阵

| 报告键 | 实测、验收 |
|---|---|
| `load_credential` | 实际 systemd API 单元，打开真实 `LoadCredential` 传入的 0600 合成摘要；`probe-isolated-nginx.py active` 的合法鉴权须 200，缺 token 须 401，确认持续用无特权 UID 启动；无权限的直接读取不能替代此项。 |
| `socket_identities` | 探针实际以 `www-data` 成功连并鉴权、`nobody` 得到 EACCES。另从 `www-data` 和 `nobody` 分别证明不能读快照或持久摘要，仅 API 身份在 unit 内读凭据；检查 socket 和每级目录权限、计数与真实日志。 |
| `http1_http2_body` | 探针 `active` 用真实 TLS/ALPN：无体 GET 200、HTTP/1.1 显式长度及 chunked 非空请求 400、HTTP/2 显式长度和**不带 Content-Length 的 1/2 字节 DATA** 400。通过合成 curl trace 确认发送 DATA，不能只检查配置或伪造 API 头。验证 405/Allow、固定错误体、no-store。 |
| `rate_per_ip_global` | 同一探针分别用同源地址和多个回环源地址实际触发 429/Retry-After；通过另一源地址排除 per-IP 与全局混淆。只对合成站点运行。 |
| `install_interrupt` | 正常演练后从 VM 快照重复安装；用 VM 内 shell 调试器或暂停安装进程，在配置发布后、reload 前硬中断。另从已退役状态重装，在限速片段发布后、替换 410 前硬中断。原脚本不添加测试旁路。确认 worker 未被换代、站点正常、重装中断仍返回 410；再完成两阶段恢复，确认 410 与网站独立正常、凭据只在阶段 2 后移除。 |
| `rollback_before_confirmation` | 先在正常运行时试无/错回执，确保不拆后端。用 VM 本机暂停 nginx master，再执行阶段 1（Ubuntu 默认 reload helper 只发信号，可能返回 0）；拿到回执但旧 worker 仍在时试阶段 2，必须阻断，credential、unit、socket 保留。无回执或配置漂移也必须阻断；继续前解除暂停。 |
| `rollback_live_and_cleanup` | 演练实际脚本完成「安装 → 回滚 → 重装」。首次安装以 `active` 探针验收；阶段 1 后确认该 master 的旧 worker 已退出，再跑 `retired`：用 HTTP/1.1 和 HTTP/2 各自的新连接无 Authorization 验证网站 200 与状态 URL 的固定 no-store 410，同时 `www-data` 直连 API 仍 200。以当次回执拆后端，跑 `retired-clean`，确认 410 仍在、网站正常、仅本功能资源被收回。重新预置 VM 合成摘要，不手删 410；运行同一候选 `install.sh --apply`。在最终路由替换前暂停，确认新后端可直连而外层仍是 410；继续并确认新一代 worker，复跑 `active` 且确认网站仍正常。 |
| `systemd_change_freeze` | 在隔离 VM 按下列步骤验证共享锁、systemd 漂移和未批准站点变更确实阻断共享 reload；不能用静态检查代替。 |

### `systemd_change_freeze` 实测

1. 仅在该 VM 创建 root:root 0600 的 `/run/host-config-change.lock`；建立同名的合成受保护 units（至少覆盖校验器列出的 `relay-*`、`relay.slice`，nginx 用实际 VM 服务）。在批准窗口冻结其他写入，记录 VM 的 nginx master/worker 代际、合成 unit 状态及配置摘要；仅用这台 VM 自己的合成审批。各负例从已核准状态开始，恢复原文件后再继续，不通过重签漂移配置使负例变绿。
2. 在另一 VM 终端持有该文件的排他 `flock`。运行实际 `install.sh --apply` 或 `rollback.sh --remove-route`，必须非零退出，且无文件、unit 或 worker 变化。释放锁后验证正常路径可继续。
3. 在批准后修改一个合成受保护 unit 的 fragment，不运行 daemon-reload。验证 `nginx-gate.py systemd` 拒绝；再在阶段 1 已通过最后一次完整 nginx 检查、尚未调用 `nginx_reload` 时注入同样的漂移，确认最后的 systemd 检查阻止共享 nginx reload。另从安装快照在安装即将调用 `systemd_reload` 前注入该漂移，确认未执行 daemon-reload 或启动本功能 unit。用 VM 的命令调用/日志和实际 worker 代际确认，不以某条错误文案代替；不停止合成受保护 unit，不移除后端凭据。
4. 恢复 unit 原文件，再给无关 vhost 增加语法正确的未批准变更；运行实际阶段 1，确认拒绝共享 nginx reload、worker 未切换。恢复已核准文件，确认同一审批下正常阶段 1 能请求 reload，且新 TLS 连接和 worker 代际证实切换。记录各负例和正常对照的脱敏结果。

运行探针：`/usr/bin/python3 -IB tests/probe-isolated-nginx.py active` / `retired` / `retired-clean`。此外实测停止采集超过 75 秒后的 503、socket 不可用归一 503、真实日志无合成 Authorization/请求体泄漏、systemd 沙箱、耗时/内存、未改变其他 vhost。保留脱敏结果，任何一项未过不得批准。

`isolation-pass.json` 字段只允许：`platform` 为 `Ubuntu 22.04`，`candidate_sha256` 为该候选摘要，`runtime_sha256` 为隔离机包版本和架构摘要，以及 `/usr/bin/python3 -IB nginx-gate.py isolation-checks` 输出的上表八个结果键。仅在各项实测通过后填字符串 `PASS`；缺任一项都不得出具通过报告。报告只是验收摘要，运维需保留对应详细脱敏记录。生产 `nginx-review.json` 绑定报告原始字节的 SHA-256，以及经另行审批的现场基线、systemd 配置和 launcher；这两份文件不进仓库。缺少真机证据、管理窗口或审批时 `NO_DEPLOY`。
