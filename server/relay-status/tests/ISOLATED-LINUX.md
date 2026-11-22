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
| `install_interrupt` | 先跑完整安装/撤销并还原 VM 快照。第二轮在创建候选文件后、reload 前中断安装（可用 VM 内 shell 调试器或暂停安装进程，原脚本不添加测试旁路）；演练至少一个片段已经移入后的硬中断。观测没有意外切换 worker 或生产路径变更。再跑两阶段恢复，证明站点正常、状态 URL 回到基线、凭据只在阶段 2 后移除。另让无关 vhost 发生一个语法正确的未批准变更，确认拒绝 reload；恢复基线后才继续。 |
| `rollback_before_confirmation` | 先在正常运行时试无/错回执，确保不拆后端。用 VM 本机暂停 nginx master，再执行阶段 1（Ubuntu 默认 reload helper 只发信号，可能返回 0）；拿到回执但旧 worker 仍在时试阶段 2，必须阻断，credential、unit、socket 保留。无回执或配置漂移也必须阻断；继续前解除暂停。 |
| `rollback_live_and_cleanup` | 确认该 master 的旧 worker 已退出，再用 `probe-isolated-nginx.py inactive` 从 HTTP/1.1 和 HTTP/2 新连接确认网站 200 与状态 URL 已回到批准 404，同时 `www-data` 直连 API 仍 200。之后以当次回执拆后端并复测站点和回退；验证只收回本功能资源。 |

运行探针：`/usr/bin/python3 -IB tests/probe-isolated-nginx.py active` / `inactive`。此外实测停止采集超过 75 秒后的 503、socket 不可用归一 503、真实日志无合成 Authorization/请求体泄漏、systemd 沙箱、耗时/内存、未改变其他 vhost。保留脱敏结果，任何一项未过不得批准。

`isolation-pass.json` 字段只允许：`platform` 为 `Ubuntu 22.04`，`candidate_sha256` 为该候选摘要，`runtime_sha256` 为隔离机包版本和架构摘要，上表七个键均为字符串 `PASS`。报告只是验收摘要，运维需保留对应详细脱敏记录。生产 `nginx-review.json` 绑定报告原始字节的 SHA-256，以及经另行审批的现场基线和 launcher；这两份文件不进仓库。缺少真机证据、管理窗口或审批时 `NO_DEPLOY`。
