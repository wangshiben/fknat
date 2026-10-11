# fknat 使用说明

本文档面向发布包安装、NAT Client/NAT Server 配置、Web 控制台操作和故障排查。

fknat 是 NAT Client/NAT Server 共用的 TCP/UDP 转发程序：

- `server` 注册稳定的 NAT Server NodeID，把隧道流量转发到本机业务服务。
- `client` 在本机监听 TCP/UDP 端口，把连接转发到指定 NAT Server。

正式版 CA Web 地址固定为 `https://ca.fknat.top`。Index 和 Relay 未显式配置时，
程序通过 CA Web 自动发现入口。发布版不提供 `--ca` 参数，也不允许通过
`FKNAT_CA_URL` 覆盖 CA 地址。

## 1. 发布包和文件选择

发布包中的 `binaries` 目录存放可以直接运行的裸二进制，`installers` 目录存放
后台服务安装包和对应的压缩包。

- Linux x86-64：文件名包含 `linux-amd64`、`amd64.deb` 或 `x86_64.rpm`。
- Linux ARM64：文件名包含 `linux-arm64`、`arm64.deb` 或 `aarch64.rpm`。
- Windows 64 位：文件名包含 `windows-amd64.zip`。
- macOS Intel：文件名包含 `darwin-amd64`。
- macOS Apple Silicon：文件名包含 `darwin-arm64`。

## 2. 准备身份和 CA Web 扣费密钥

在 CA Web 用户中心生成并下载扣费私钥 JSON，然后将它放入安装目录的
`config/billing-key.json`。该文件决定节点消费归属；建议每个实际节点使用独立
扣费密钥，以便单独吊销和审计。扣费密钥不是节点身份文件，不能替代
`FKNAT_IDENTITY_FILE`，不要公开、提交或打印其内容。

Linux 上可以这样准备目录和权限：

```bash
sudo install -d -m 700 /var/lib/fknat
sudo install -m 600 /安全路径/ca-billing-xxx.json /etc/fknat/billing-key.json
```

身份文件首次运行时会自动创建，之后必须持久保存。删除或替换身份文件会改变
NodeID；NAT Client 的 `--server-id` 必须使用当前 NAT Server 身份对应的 64 位
NodeID。

## 3. 安装发布包

### Linux DEB（Debian/Ubuntu）

```bash
sudo apt install ./fknat_2026.09.15-r27_amd64.deb
```

### Linux RPM（RHEL/Rocky/Alma/Fedora）

```bash
sudo dnf install ./fknat-*.x86_64.rpm
```

### Linux 便携包

```bash
tar -xzf fknat-2026.09.15-r27-linux-amd64.tar.gz
cd fknat-2026.09.15-r27-linux-amd64
sudo ./install.sh
```

Linux 默认安装到 `/opt/fknat`。安装后服务在 `CONFIGURED=0` 时只在后台等待
配置，不会启动 NAT 业务进程。

安装器还会把 `fknat` 注册为全局命令（通常位于 `/usr/local/bin/fknat`）。安装完成
后无需进入安装目录即可查看帮助、编辑配置和管理后台服务：

```bash
fknat
sudo fknat edit-config
sudo fknat restart
sudo fknat status
sudo fknat logs
```

`fknat run ...` 可以调用同一份裸二进制在前台运行，`fknat --help` 会显示完整的
二进制参数。卸载时，安装器只会删除自己创建的全局命令链接。

### macOS

```bash
tar -xzf fknat-2026.09.15-r27-darwin-arm64.tar.gz
cd fknat-2026.09.15-r27-darwin-arm64
sudo ./install.sh
```

macOS 默认安装到 `/usr/local/lib/fknat`，通过 LaunchDaemon 在后台运行。
macOS 安装器同样会创建 `/usr/local/bin/fknat` 全局命令。

### Windows

解压对应架构的 zip，在“以管理员身份运行”的 PowerShell 中执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

Windows 默认安装到 `%ProgramData%\FkNat\fknat`，通过计划任务在后台运行。
Windows 安装器会把 `fknat.cmd` 所在目录加入系统 PATH；重新打开终端后即可直接
使用 `fknat` 命令。

## 4. 配置文件和 Web 控制台

直接运行裸二进制或安装包服务都会提供 Web 管理页，默认监听
`0.0.0.0:8088`。Web 页面包含两个路由：`/overview` 运行概览和 `/config` 节点
配置。根路径会显示登录页。

即使 NodeID、端口或扣费密钥尚未填写，Web 服务也会启动并显示
`waiting_for_configuration`。这表示业务配置还没有完成，不表示 Web 服务故障。
在页面中填写必要字段和映射后点击“保存并启动”，程序会原子写入配置并自动启动
或重启对应的 Client/Server 运行时。运行状态每 3 秒刷新；连接异常时使用“重试
连接”，错误会同时显示在页面和进程日志中。

首次启动且没有认证配置时，程序默认创建 Web 用户 `admin`，并随机生成密码；
初始密码只在启动日志中显示一次。密码以 bcrypt 哈希保存，配置文件不会保存明文。
登录会话由 QuicFrameWork Session 管理，浏览器自动保存后端下发的 Cookie；未登录
访问运行和配置 API 会返回 HTTP 401。生产环境建议配合 HTTPS 反向代理，或只监听
受信任的管理网卡。

命令行配置 Web 认证和监听地址：

```bash
./fknat \
  --web-listen 0.0.0.0:28090 \
  --web-user admin \
  --web-password 'change-this-password'
```

安装包可以把同样的字段写入 `config/app.env`：

```env
FKNAT_WEB_LISTEN=0.0.0.0:8088
FKNAT_WEB_USER=admin
FKNAT_WEB_PASSWORD=change-this-password
```

`FKNAT_WEB_LISTEN` 只在进程启动时生效，Web 页面不能修改监听地址；修改后需要
重启服务。`FKNAT_WEB_USER` 和 `FKNAT_WEB_PASSWORD` 也可以通过环境变量传入。
配置文件默认是 `~/.config/fknat/config.json`，可用 `--config` 或
`FKNAT_CONFIG_FILE` 指定。

安装包的 `config/app.env` 仅作为首次启动和缺省配置；Web 保存到 `data/config.json`
后，JSON 中已有字段优先于环境变量。修改角色、映射或转发端口后无需同步改写
`FKNAT_MODE` 等旧环境值，重启服务会继续使用 JSON 配置。

## 5. 配置 NAT Server

Server 的作用是注册 NodeID，并把收到的逻辑流连接到本机后端服务。安装包使用
`config/app.env` 时，至少确认以下字段：

```env
CONFIGURED=1
BNFS_SECURITY_PROFILE=production
BNFS_BILLING_KEY_FILE=config/billing-key.json #此字段为扣费私钥文件，在ca web上登录自己的账号导出 
FKNAT_IDENTITY_FILE= #第一次启动不用写此字段，此字段是NODE的身份标识文件，如果没写就默认生成
FKNAT_MODE=server
FKNAT_INDEX_ADDRESS=
FKNAT_RELAY_ADDRESS=
FKNAT_RELAY_ADDRESSES=
FKNAT_RELAY_COUNT=1
FKNAT_FORWARD_TARGET=127.0.0.1:8080
```

`FKNAT_FORWARD_TARGET` 是真实 HTTP/TCP 服务地址。Index 和 Relay 都留空时，程序
使用 CA Web 自动发现；需要固定拓扑时才填写 `host:port`。

安装服务后重启并查看日志：

```bash
sudo /opt/fknat/control.sh edit-config
sudo /opt/fknat/control.sh restart
sudo /opt/fknat/control.sh status
sudo /opt/fknat/control.sh logs
```

日志会输出该 NAT Server 的 64 位 NodeID，将它填写到 NAT Client 的
`FKNAT_SERVER_NODE_ID` 或 `--server-id`。

直接运行裸二进制时，可以使用以下命令：

```bash
./fknat \
  --non-interactive \
  --mode server \
  --billing-key ./billing-key.json \
  --identity ./server.identity \
  --target 127.0.0.1:8080
```

`--target` 支持以下形式：

```text
8080                    等价于 127.0.0.1:8080
:8080                   等价于 127.0.0.1:8080
10.0.0.8:443            指定 IPv4/域名服务
[2001:db8::1]:443       指定 IPv6 服务
```

Server 也可以在 Web 页面中添加多个转发端口。每条规则包含协议（TCP/UDP）、独立的
Server 路由键和本机转发目标（`host:port`）。单个目标的路由键可以填 `0`；多个同协议
目标应填写不同路由键，并在 Client 映射中使用相同的 `remote_port`。Server 收到流后直接
连接目标，不会额外监听请求端口。未列入规则的请求会被拒绝，Client 页面会显示拒绝原因
并提供重试按钮。

### 多 Relay Server

同一个 NAT Server 最多注册三个服务 Relay：

```bash
./fknat \
  --non-interactive \
  --mode server \
  --index index.example.com:9000 \
  --relays relay-a.example.com:9000,relay-b.example.com:9000 \
  --relay-count 2 \
  --billing-key /etc/fknat/server.billing-key.json \
  --identity /var/lib/fknat/server.identity \
  --target 127.0.0.1:8080
```

`--relay` 与 `--relays` 不能同时使用，`--relay-count` 范围为 `1..3`。

## 6. 配置 NAT Client

Client 建议安装在另一台机器，并使用另一份扣费密钥。安装包的
`config/app.env` 至少包含：

```env
CONFIGURED=1
BNFS_SECURITY_PROFILE=production
BNFS_BILLING_KEY_FILE=config/billing-key.json
FKNAT_IDENTITY_FILE=data/client.identity
FKNAT_MODE=client
FKNAT_INDEX_ADDRESS=
FKNAT_RELAY_ADDRESS=
FKNAT_LISTEN_ADDRESS=127.0.0.1:18081
FKNAT_SERVER_NODE_ID=<NAT Server 输出的 64 位 NodeID>
```

重启服务后，本地应用访问 `127.0.0.1:18081`，连接会经 Relay 转发到 Server 的
`FKNAT_FORWARD_TARGET`。只有确实需要局域网其他机器访问时，才把监听地址改成
`0.0.0.0:18081`，并同步配置主机防火墙。

裸二进制 Client 示例：

```bash
./fknat \
  --non-interactive \
  --mode client \
  --billing-key ./billing-key.json \
  --identity ./client.identity \
  --server-id '<Server NodeID>' \
  --listen 127.0.0.1:18081
```

`--listen` 支持以下形式：

```text
18081                   等价于 127.0.0.1:18081
127.0.0.1:0             随机选择空闲端口
0.0.0.0:18081           允许其他主机访问本机端口
```

需要多个映射或 UDP 时，推荐在 Web 页面添加映射。UDP 映射使用一条隧道流承载一个
请求/响应数据报，适合 DNS 等请求响应型服务。TCP 和 UDP 请求都会携带连接 ID、协议
类型和 Server 路由键的路由头，由 Server 的允许列表校验后再拨号后端；例如 Server
配置路由键 `1001` 指向 `127.0.0.1:18888` 时，Client 映射的 `remote_port` 也填写 `1001`。

## 7. Index、Relay 和连接行为

- 指定 `--relay` 时，固定从该 Relay 注册和拨号。
- 不指定 `--relay` 时，先连接 `--index`，由框架发现可用 Relay。
- `--index` 也留空时，通过 CA Web 获取可用入口。
- 底层默认同时支持 KCP 和 TCP；链路异常时框架自动切换。
- 应用侧 TCP 流在两个方向按业务边界使用 Zstd 帧压缩，不压缩 KCP、控制面和路由头。
- Client 断线后按 `--reconnect-delay` 重建隧道，拨号按 `--dial-attempts` 和
  `--retry-delay` 重试。

生产环境建议保持默认 KCP/TCP 框架参数，先验证稳定性再调整并发。

## 8. 常用参数和环境变量

| 参数 | 默认值 | 说明 |
|---|---:|---|
| `--dial-attempts` | 12 | Client 单次拨号尝试次数 |
| `--retry-delay` | 3s | Client 拨号重试间隔 |
| `--reconnect-delay` | 3s | 隧道失效后的重连间隔 |
| `--max-sessions` | 128 | Server 最大并发会话数 |
| `--accept-queue` | 128 | Server 已认证会话等待队列 |
| `--relay-count` | 1 | Server 自动选择的 Relay 数量，范围 `1..3` |
| `--web-listen` | `0.0.0.0:8088` | Web 管理地址 |
| `--web-user` | `admin` | Web 管理用户名 |
| `--web-password` | 首次启动随机生成 | Web 管理密码，至少 8 个字符 |
| `--config` | 用户配置目录下 `fknat/config.json` | JSON 配置文件路径 |

对应的环境变量包括 `FKNAT_INDEX_ADDRESS`、`FKNAT_RELAY_ADDRESS`、
`FKNAT_RELAY_ADDRESSES`、`FKNAT_IDENTITY_FILE`、`FKNAT_LISTEN_ADDRESS`、
`FKNAT_SERVER_NODE_ID`、`FKNAT_WEB_LISTEN`、`FKNAT_WEB_USER`、
`FKNAT_WEB_PASSWORD` 和 `FKNAT_CONFIG_FILE`。安全档使用
`BNFS_SECURITY_PROFILE`，扣费密钥使用 `BNFS_BILLING_KEY_FILE`。环境变量不能
修改内置 CA 地址。

## 9. 交互式运行和服务管理

直接运行 `./fknat` 会启动 Web 管理页。需要终端配置向导时使用
`--interactive`；向导会询问角色、Index、扣费密钥、身份文件、Relay、NodeID 或
后端地址，但不会询问或修改 CA 地址。systemd、容器和自动化部署应使用
`--non-interactive`，缺少必填参数时程序会立即失败。

```bash
./fknat --version
./fknat --help
./fknat --interactive
./fknat --non-interactive --mode server --billing-key ./billing-key.json
```

Linux 服务管理：

```bash
sudo /opt/fknat/control.sh {start|stop|restart|status|logs|edit-config}
sudo /opt/fknat/uninstall.sh
```

macOS 将 `/opt/fknat` 替换为 `/usr/local/lib/fknat`。Windows 在安装目录运行：

```powershell
.\control.ps1 status
.\control.ps1 logs
.\control.ps1 restart
.\uninstall.ps1
```

日志保存在安装目录的 `log` 子目录。普通卸载保留 `config`、`data` 和 `log`；
彻底清除身份、扣费队列和日志时再使用：

```bash
PURGE=1 ./uninstall.sh
```

```powershell
.\uninstall.ps1 -Purge
```

## 10. 快速验收

```bash
./fknat --version
./fknat --ca https://example.invalid
getent ahosts ca.fknat.top
curl -fsS https://ca.fknat.top/readyz
```

`--ca` 示例应因未知参数失败。推荐按以下顺序验收：

1. 确认 CA Web、Index 和 Relay 的 TCP/UDP 端口真实可达。
2. 启动 NAT Server，记录日志中的 NodeID。
3. 启动 NAT Client，确认显示就绪状态和本地监听地址。
4. 通过 Client 监听端口访问后端 HTTP 服务。
5. 使用 100–200 MB 随机文件多次验证响应长度和 SHA-256。
6. 在传输中重启 Relay 或阻断 UDP，确认会话能够恢复或自动切换 TCP。

## 11. 故障定位和完整性校验

排查顺序：

1. 检查 `ca.fknat.top` 解析和 CA Web 健康状态。
2. 检查 Index/Relay 地址以及 TCP/UDP 端口可达性。
3. 检查 `billing-key` 文件是否存在且当前进程可读。
4. 确认 NAT Server 打印的 NodeID 与 Client 的 `--server-id` 完全一致。
5. 确认 NAT Server 的 `--target` 或转发端口可以从本机连接。
6. 检查 Client/Server 日志中的注册、拨号、重连和后端连接错误。

若均未解决，请查看位于下面路径的log反馈至issue或TG群组:

```pwd
  • Linux：/opt/fknat/log/
  • macOS：/usr/local/lib/fknat/log/
  • Windows：%ProgramData%\FkNat\fknat\log\
```
