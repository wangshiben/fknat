# fkNat 使用说明

本文档面向部署 `fkNat` 的 NAT 端应用人员。一个 `fkNat` 二进制支持两种角色：

- `server`：注册 NAT Server NodeID，把隧道流量转发到本机业务服务。
- `client`：在本机监听 TCP 端口，把连接转发到指定 NAT Server。

发布版内置 CA Web 地址：

```text
https://ca.fknat.top
```

`--ca` 不存在，`FKNAT_CA_URL` 不能覆盖内置地址。生产模式必须提供 CA Web 导出的扣费私钥。

## 1. 公共准备

准备独立的身份文件和扣费密钥：

```bash
install -d -m 700 /var/lib/fknat
chmod 600 /etc/fknat/billing-key.json
```

- `--identity`：节点身份文件。首次运行不存在时自动生成，之后必须持久化。
- `--billing-key`：CA Web 导出的扣费私钥 JSON，权限必须为 `0600` 或更严格。
- `--index`：Index 的 `host:port` 地址。
- `--relay`：固定入口 Relay；不填时由 Index 发现。

身份文件变化会导致 NodeID 变化。NAT Client 的 `--server-id` 必须使用当前 NAT Server 身份对应的 64 位 NodeID。

## 2. NAT Server

NAT Server 把收到的逻辑流转发给 `--target` 指定的本地业务服务：

```bash
./fkNat \
  --non-interactive \
  --mode server \
  --index index.example.com:9000 \
  --relay relay.example.com:9000 \
  --billing-key /etc/fknat/server.billing-key.json \
  --identity /var/lib/fknat/server.identity \
  --target 127.0.0.1:8080
```

启动后记录程序打印的 64 位 NodeID，并交给 NAT Client。

`--target` 支持：

```text
8080                    等价于 127.0.0.1:8080
:8080                   等价于 127.0.0.1:8080
10.0.0.8:443            指定 IPv4/域名服务
[2001:db8::1]:443       指定 IPv6 服务
```

### 多 Relay Server

同一 NAT Server 可注册到多个服务 Relay：

```bash
./fkNat \
  --non-interactive \
  --mode server \
  --index index.example.com:9000 \
  --relays relay-a.example.com:9000,relay-b.example.com:9000 \
  --relay-count 2 \
  --billing-key /etc/fknat/server.billing-key.json \
  --identity /var/lib/fknat/server.identity \
  --target 127.0.0.1:8080
```

`--relay` 与 `--relays` 不能同时使用，最多配置三个 Relay。`--relay-count` 范围是 `1..3`。

## 3. NAT Client

NAT Client 在本机监听一个 TCP 端口：

```bash
./fkNat \
  --non-interactive \
  --mode client \
  --index index.example.com:9000 \
  --relay relay.example.com:9000 \
  --billing-key /etc/fknat/client.billing-key.json \
  --identity /var/lib/fknat/client.identity \
  --server-id <NAT_SERVER_NODE_ID> \
  --listen 127.0.0.1:18081
```

`--listen` 支持：

```text
18081                   等价于 127.0.0.1:18081
127.0.0.1:0             随机选择空闲端口
0.0.0.0:18081           允许其他主机访问本机端口
```

Client 启动后会打印实际监听地址。访问该地址的 TCP 连接都会转发到目标 NAT Server 的 `--target`。

## 4. 连接与协议行为

- 指定 `--relay`：固定从该 Relay 注册和拨号。
- 不指定 `--relay`：先连接 `--index`，由框架发现可用 Relay。
- 底层默认同时支持 KCP 和 TCP；链路异常时框架自动切换。
- 应用侧是 TCP。fknat 在业务 TCP 流边界按方向使用 Zstd 帧压缩，不压缩 KCP/控制面数据。
- Client 断线后会按 `--reconnect-delay` 重建隧道；拨号会按 `--dial-attempts` 和 `--retry-delay` 重试。

生产环境建议保持默认 KCP/TCP 框架参数，先验证稳定性再调整并发。

## 5. 常用参数

| 参数 | 默认值 | 说明 |
|---|---:|---|
| `--dial-attempts` | 12 | Client 单次拨号尝试次数 |
| `--retry-delay` | 3s | Client 拨号重试间隔 |
| `--reconnect-delay` | 3s | 隧道失效后的重连间隔 |
| `--max-sessions` | 128 | Server 最大并发会话数 |
| `--accept-queue` | 128 | Server 已认证会话等待队列 |
| `--relay-count` | 1 | Server 自动选择的 Relay 数量，范围 1..3 |

参数也可以通过当前程序支持的环境变量设置，例如 `FKNAT_INDEX_ADDRESS`、`FKNAT_RELAY_ADDRESS`、`FKNAT_IDENTITY_FILE`；环境变量只用于普通运行参数，不能修改 CA 地址。

## 6. 交互式和自动化启动

直接运行 `./fkNat` 会进入交互向导。向导会询问角色、Index、扣费密钥、身份文件、Relay、NodeID 或后端地址；CA 地址只显示内置值，不再询问。

systemd、容器和自动化部署应使用 `--non-interactive`。缺少必填参数时程序会立即失败，不会等待输入。

## 7. 快速验收

```bash
./fkNat --version
./fkNat --ca https://example.invalid       # 应失败：未知参数
getent ahosts ca.fknat.top
curl -fsS https://ca.fknat.top/readyz
```

推荐验收顺序：

1. 确认 Index/Relay 已真实就绪。
2. 启动 NAT Server，记录 NodeID。
3. 启动 NAT Client，确认显示 `Client 已就绪` 和本地监听地址。
4. 通过 Client 监听端口访问后端 HTTP 服务。
5. 使用 100–200 MB 随机文件多次验证响应长度和 SHA-256。
6. 在传输中重启 Relay 或阻断 UDP，确认会话能恢复或自动切换 TCP。

## 8. 故障定位

1. `getent ahosts ca.fknat.top`、`curl https://ca.fknat.top/readyz`；
2. Index/Relay 地址和 TCP/UDP 端口可达性；
3. `billing-key` 权限是否为 `0600`；
4. NAT Server 打印的 NodeID 是否与 Client 的 `--server-id` 一致；
5. NAT Server 的 `--target` 是否本机可连接；
6. Client/Server 日志中的注册、拨号、重连和后端连接错误。

不要通过替换 CA 地址、删除身份文件或关闭生产准入来绕过问题。
