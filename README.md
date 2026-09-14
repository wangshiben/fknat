# fknat

`fknat` 是基于 [`natP2pSDK`](../natP2pSDK) 的双角色 TCP 端口转发工具。一个二进制既可以作为 NatClient，也可以作为 NatServer：

- Client 在本机监听随机或固定 TCP 端口，把该端口接受的连接通过 natP2p 网络转发到指定 NatServer NodeID。
- Server 注册自己的稳定 NodeID，接收 NatClient 隧道，并把每条逻辑流转发到本机端口或指定的 `IP/域名:端口`。
- natP2pSDK 负责 CA 准入、Relay 注册、节点握手、计费以及 KCP/TCP 底层路径；fknat 处理应用侧 TCP 代理，并在业务流进入隧道前按方向使用 Zstd 帧压缩。

面向部署人员的 NAT Client/NAT Server 独立说明见 [NAT_USAGE.md](NAT_USAGE.md)。

## 安全说明

节点身份密钥和扣费密钥是两种不同的密钥：

- 节点身份默认自动生成到用户配置目录中的 `fknat/client.identity` 或 `fknat/server.identity`，用于保持 NodeID 稳定。
- `--billing-key` 必须指向 CA Web 导出的扣费私钥 JSON 文件。文件权限必须为 `0600` 或更严格。
- fknat 不会复制、打印或写入扣费私钥内容。不要把扣费私钥粘贴到 `--identity`，也不建议把密钥内容直接放在命令行参数中。
- CA Web 地址由发布二进制固定为 `https://ca.fknat.top`，不接受命令行参数或环境变量覆盖。
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

直接运行即可进入向导：

```bash
./bin/fknat
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

## 当前协议范围

fknat 暴露的是 TCP 监听端口和 TCP 后端。KCP 是 natP2p 网络中的底层传输路径，不表示本地端口是 UDP。应用 TCP 流在 Client→Server 和 Server→Client 两个方向分别封装为带方向标记的 Zstd 帧；不可压缩数据自动使用原文帧。UDP 应用代理仍需要 SDK 额外提供数据报会话语义后再实现，当前不会压缩 SDK 的 KCP/控制面数据包。

## 当前公网拓扑

部署参数按以下角色配置，CA Web 统一通过固定域名访问：

```text
NatClient (193) -> Client Relay (160) -> Server Relay (198) -> NatServer (192)
                                      \
                                       CA Web (https://ca.fknat.top)
```

Client 使用 `--relay <160-relay-address>`，Server 保持使用 `--relay <198-relay-address>`。Zstd 只位于 fknat 的业务 TCP 转发边界，不改变上述 Relay、KCP/UDP 或 CA 控制面的协议地址。

`scripts/real-50g/run.sh` 会启动只读监控页面，默认监听 `0.0.0.0:18090`；内网访问本机对应地址的 `/`，例如 `http://192.168.1.12:18090/`。页面提供运行选择、Client 进度、160/198 Relay 队列与服务状态、CA 健康和 Relay 资源采样，不展示凭据或原始日志。可用 `MONITOR_PORT` 修改端口。

## 累计计费凭证

Relay 不会逐包访问 CA Web。它先验证并累计端到端计费 Record，再在下列任一条件先满足时要求付款方双签一张累计凭证：

- 自上一张凭证后的认证 E2E Record 累计接近 50 MiB（52,428,800 bytes）；
- 首个尚未双签的 Record 已等待 1 分钟。

正常关闭时还会强制冲刷不足 50 MiB、也未满 1 分钟的尾单。双签凭证先进入 Relay 的持久 `waitSubmit` 队列，再由后台提交 CA；CA 暂时不可达不会进入逐包转发热路径。

单个原子 Record 仍最多为 1 MiB。若下一条 Record 会使累计值越过 50 MiB 上限，Relay 会在接收该 Record 前提交当前窗口，因此实测单张增量可能略低于 50 MiB。当前 SDK 还会把节点层 `[]byte` 放入 JSON 信封，JSON 的 base64 开销属于认证 E2E Record 字节，所以原始 TCP 文件大小与 CA 看到的累计字节不是严格 1:1。

压缩凭证频率会扩大信用敞口：单付款方、单 Relay、单 Session 最多可先产生约一个窗口的未双签流量，余额不足可能在下一次 CA 结算时才触发 cutoff。

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

2026-08-17 的旧策略 30 分钟过载测试和新 50 MiB/1 分钟策略受控验证见 [实测报告](REAL_TRANSFER_AND_BILLING_REPORT_2026-08-17.md)。

## License

[MIT](LICENSE)
