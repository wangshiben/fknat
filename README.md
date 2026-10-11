# fknat

> 相关链接详见: [urls.md](urls.md)
> 项目具体介绍如下/牢骚 : [introduction](introduction.md)

`fknat` 是基于 [`natP2pSDK`](https://github.com/wangshiben/natP2pSDK) 的双角色 TCP 端口转发工具。一个二进制既可以作为 NatClient，也可以作为 NatServer：

- Client 在本机监听随机或固定 TCP 端口，把该端口接受的连接通过 natP2p 网络转发到指定 NatServer NodeID。
- Server 注册自己的稳定 NodeID，接收 NatClient 隧道，并把每条逻辑流转发到本机端口或指定的 `IP/域名:端口`。
- natP2pSDK 负责 CA 准入、Relay 注册、节点握手、计费以及 KCP/TCP 底层路径；fknat 处理应用侧 TCP 代理，并在业务流进入隧道前按方向使用 Zstd 帧压缩。

面向部署人员的 NAT Client/NAT Server 独立说明见 [USAGE.md](USAGE.md)。

如果您懒得看 一大串的部署说明，可以看这个[快速上手](UseDemo.md)


## 使用说明

参考[使用说明](USAGE.md)，发布包在 release 中。


## 安全说明

节点身份密钥和扣费密钥是两种不同的密钥：

- 节点身份默认自动生成到用户配置目录中的 `fknat/client.identity` 或 `fknat/server.identity`，用于保持 NodeID 稳定。
- `--billing-key` 必须指向 CA Web 导出的扣费私钥 JSON 文件，文件只需可读即可。
- fknat 不会复制、打印或写入扣费私钥内容。不要把扣费私钥粘贴到 `--identity`，也不建议把密钥内容直接放在命令行参数中。
- production 安全档必须配置扣费私钥。

```bash
chmod 600 /secure/path/billing-key.json
```

## 构建

当前工程通过 `go.mod` 的本地 `replace` 使用 `/root/natP2pSDK`：

```bash
cd /root/fknat
go build -o bin/fknat .
```

SDK 发布为可获取的 Go 模块版本后，可以移除 `replace` 并更新对应版本。

## 交互式使用

直接运行会启动 Web 管理页（默认 `http://0.0.0.0:8088/`）：

```bash
./bin/fknat
```

需要终端配置向导时显式使用 `--interactive`：

```bash
./bin/fknat --interactive
```

向导会依次询问：

1. Client 或 Server 角色；
2. Index 地址、扣费密钥文件和节点身份文件；
3. Client 的目标 Server NodeID 与本地监听端口，或 Server 的实际应用地址。

Client 输入监听端口 `0` 或 `127.0.0.1:0` 时，系统会随机选择空闲端口，并在启动后打印实际地址。只输入 `8080` 等数字时默认监听 `127.0.0.1:8080`；如需局域网访问，可显式填写 `0.0.0.0:8080`。

Server 的实际应用地址可以只写本地端口，例如 `8080`，等价于 `127.0.0.1:8080`；也可以填写 `10.0.0.8:8080` 或 `[2001:db8::1]:8080`。

## 非交互示例

启动 Server，把流量交给本机 8080：

```bash
./bin/fknat \
  --non-interactive \
  --mode server \
  --index index.example.com:9000 \
  --billing-key /secure/server-billing-key.json \
  --target 127.0.0.1:8080
```

Server 启动后会打印 64 位 NodeID。然后启动 Client，随机监听一个本地端口：

```bash
./bin/fknat \
  --non-interactive \
  --mode client \
  --index index.example.com:9000 \
  --billing-key /secure/client-billing-key.json \
  --server-id '<Server 打印的 64 位 NodeID>' \
  --listen 127.0.0.1:0
```

也可以使用 `--relay relay.example.com:9000` 固定入口 Relay。Server 如需同时注册多个 Relay，可使用：

```bash
--relays relay-a.example.com:9000,relay-b.example.com:9000
```

最多支持三个服务 Relay。

## 本地开发模式

没有独立扣费密钥时，可以显式使用 SDK 的开发安全档：

```bash
./bin/fknat --security-profile development
```

开发档仍连接二进制内置的 `https://ca.fknat.top`，只用于受控测试，不能替代 production 准入和计费。需要自建 CA 的隔离测试应直接使用 SDK/框架测试入口；发布版 fknat 不提供 CA 重定向能力。

## Web 管理和多端口转发

fknat 启动后默认监听 `0.0.0.0:8088`，根路径会返回内置的 React 管理界面。React、React Router、CSS 和页面脚本全部编译进二进制，不依赖公网 CDN、Node.js 或额外的前端进程。可用 `--web-listen` 或 `FKNAT_WEB_LISTEN` 设置监听地址；Web 页面会显示这个地址，但不会允许在页面中修改，修改后需要重启进程。

页面提供两个路由：`/overview` 运行概览和 `/config` 节点配置。即使 NodeID、端口或扣费密钥路径还没有填写，Web 服务仍会启动并显示 `waiting_for_configuration`。完成配置后点击“保存并启动”，程序会原子写入 `~/.config/fknat/config.json`（可用 `--config` 或 `FKNAT_CONFIG_FILE` 指定），并自动启动或重启对应的 Client/Server 运行时。运行状态每 3 秒刷新；连接异常时使用“重试连接”，错误会同时显示在页面和进程日志中。

安装包的 `config/app.env` 只提供首次启动和缺省值；Web 保存后的 JSON 配置优先级更高。这样在页面中把 Server 切换为 Client（或反过来）后，服务重启仍会按 `data/config.json` 中保存的角色、映射和端口启动，不会被旧的 `FKNAT_MODE` 等环境值覆盖。

Web 管理界面默认启用登录保护。首次启动且没有现成认证配置时，程序会创建用户名 `admin`，随机生成一条初始密码，并将 bcrypt 哈希保存到配置文件；初始密码只在启动日志中显示一次。生产环境可以显式配置：

```bash
./fknat --web-user admin --web-password 'change-this-password' --web-listen 0.0.0.0:28090
```

安装包可以把相同字段写入 `config/app.env`：

```text
FKNAT_WEB_LISTEN=0.0.0.0:8088
FKNAT_WEB_USER=admin
FKNAT_WEB_PASSWORD=change-this-password
```

也可以使用 `FKNAT_WEB_USER` 与 `FKNAT_WEB_PASSWORD` 环境变量。密码会通过 bcrypt 保存为 `web_password_hash`，配置文件不会保存明文密码；登录后端通过 QuicFrameWork Session 建立会话并由框架自动下发 Cookie，前端不需要手动处理认证 Cookie。未登录访问运行和配置 API 会返回 HTTP 401。建议始终配合 HTTPS 反向代理或只监听受信任的管理网卡。

### Web 页面配置流程

在“节点配置”页面先选择运行模式，然后填写连接参数和业务规则：

- **Client**：填写目标 Server NodeID，添加本地 TCP/UDP 监听地址，并可指定 Server 转发端口；点击“保存并启动”后，本地应用访问监听地址即可进入隧道。
- **Server**：添加一个或多个真实后端 `host:port`，选择 TCP 或 UDP；收到远端流后 Server 直接连接这些后端，不会额外监听一个请求端口。
- **Index/Relay**：留空时使用 CA Web 自动发现；需要固定拓扑时填写对应 `host:port`。
- **扣费密钥路径**：只填写 CA Web 导出的 JSON 文件路径，Web API 不会上传或返回密钥内容。

Client 映射和 Server 转发端口都可以在页面中添加、编辑和删除；Server 规则会在“运行概览”和“转发端口预览”中同步显示。`waiting_for_configuration` 只代表业务配置尚未完成，不代表 Web 服务故障。

Client 页面支持添加、编辑和删除多个 TCP/UDP 映射，例如 `127.0.0.1:18080` → Server 的本机目标。Server 页面支持动态维护 TCP/UDP 转发端口，每条规则直接填写本机 `host:port` 目标和独立的“Server 路由键”；单个目标的路由键可填 `0`，多个同协议目标应填写不同路由键，并在 Client 映射中使用相同的 `remote_port`。每个隧道流在业务数据前带有版本化路由头（连接 ID、传输类型、路由键），Server 收到后直接连接本机目标并返回明确的接受或拒绝响应。UDP 使用一条隧道流承载一个请求/响应数据报，适用于 DNS 和常见请求响应型 UDP 服务。

Web 中的 `waiting_for_configuration` 表示 Web 控制台已启动，但节点运行条件还没有满足；选择角色、填写必要字段和映射后点击“保存并启动”即可触发运行。production 安全档还需要 CA Web 导出的扣费密钥路径。Server 收到远端流后会直接按协议连接本机转发端口，不会额外监听或请求一个 Server 端口。单个目标由默认路由直接连接；多个目标时 Client 映射的 Server 路由键必须与 Server 规则一致，例如 Server 配置 `1001 -> 127.0.0.1:18888`，Client 映射使用 `remote_port=1001`。

## 当前协议范围

fknat 支持本地 TCP/UDP 监听和 Server 端 TCP/UDP 后端。KCP 是 natP2p 网络中的底层传输路径，不表示本地端口是 UDP。应用 TCP 流在 Client→Server 和 Server→Client 两个方向分别封装为带方向标记的 Zstd 帧；不可压缩数据自动使用原文帧。UDP 映射采用一条隧道流承载一个请求/响应数据报；路由头和 SDK 控制面不会经过业务压缩。

## 吞吐调优

默认值偏向受控内存使用。高带宽时延积公网链路可以在 Client、Server 和 Relay 上一致设置以下环境变量：

| 变量 | 默认值 | 约束/作用 |
|---|---:|---|
| `TUNNEL_MAX_CHUNK` | 65536 | 单条 MUX DATA 的业务字节数，最小 1024 |
| `TUNNEL_STREAM_SEND_WINDOW` | 8 | 单逻辑流并发在途 DATA 数，最小 1 |
| `TUNNEL_SEND_WINDOW` | 32 | 整个 carrier 并发在途 DATA 数，最小 1 |
| `BNFS_KCP_SEND_WINDOW` | 256 | KCP 发送窗口，范围 32..65535 |
| `BNFS_KCP_RECEIVE_WINDOW` | 1024 | KCP 接收窗口，范围 32..65535 |
| `BNFS_KCP_SESSION_BUFFER_BYTES` | 4194304 | KCP socket 缓冲，范围 1..256 MiB |
| `BNFS_MAX_PENDING_BILLING_DATA_SENDS` | 16 | 单条 NAT 连接的计费数据发送槽，范围 1..4096；高 RTT/高带宽链路可按压测逐步提高 |

本次公网受控验证使用了 `TUNNEL_MAX_CHUNK=262144`、流窗口 32、carrier 窗口 128、KCP 发送/接收窗口 1536/6144 和 16 MiB socket 缓冲。放大窗口会增加每个活动会话的内存上限，应结合实际 RTT、丢包和并发数逐步调整。

## 验证

```bash
go test ./...
go build -o bin/fknat .
```

实际部署后可使用仓库内的有界传输长压脚本。下面的示例持续 30 分钟，每 40 秒启动一次 100–200 MiB 下载，并为每条成功传输校验 SHA-256：

```bash
BASE_URL=http://127.0.0.1:18081 \
OUTPUT_DIR=/tmp/fknat-transfer-soak \
DURATION_SECONDS=1800 \
INTERVAL_SECONDS=40 \
MIN_SIZE_MIB=100 \
MAX_SIZE_MIB=200 \
TRANSFER_TIMEOUT_SECONDS=600 \
bash scripts/transfer-soak.sh
```

`DURATION_SECONDS` 是发起新传输的调度窗口，不是所有传输共享的强制结束时间。到达该时间后脚本不再启动新任务，但会继续等待已启动任务各自的 `TRANSFER_TIMEOUT_SECONDS`，因此脚本总耗时最多可能接近两者之和。成功传输会校验 SHA-256；单条下载超时记为 `TIMEOUT`，下载前的校验和请求失败记为 `CHECKSUM_FAILED`。

## License

[MIT](LICENSE)
