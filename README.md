# fknat

`fknat` 是基于 [`natP2pSDK`](../natP2pSDK) 的双角色 TCP 端口转发工具。一个二进制既可以作为 NatClient，也可以作为 NatServer：

- Client 在本机监听随机或固定 TCP 端口，把该端口接受的连接通过 natP2p 网络转发到指定 NatServer NodeID。
- Server 注册自己的稳定 NodeID，接收 NatClient 隧道，并把每条逻辑流转发到本机端口或指定的 `IP/域名:端口`。
- natP2pSDK 负责 CA 准入、Relay 注册、节点握手、计费以及 KCP/TCP 底层路径；fknat 只处理应用侧 TCP 代理。

## 安全说明

节点身份密钥和扣费密钥是两种不同的密钥：

- 节点身份默认自动生成到用户配置目录中的 `fknat/client.identity` 或 `fknat/server.identity`，用于保持 NodeID 稳定。
- `--billing-key` 必须指向 CA Web 导出的扣费私钥 JSON 文件。文件权限必须为 `0600` 或更严格。
- fknat 不会复制、打印或写入扣费私钥内容。不要把扣费私钥粘贴到 `--identity`，也不建议把密钥内容直接放在命令行参数中。
- production 安全档必须同时配置 CA URL 和扣费私钥。

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
2. Index 地址、CA Web API URL、扣费密钥文件和节点身份文件；
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
  --ca https://ca.example.com \
  --billing-key /secure/server-billing-key.json \
  --target 127.0.0.1:8080
```

Server 启动后会打印 64 位 NodeID。然后启动 Client，随机监听一个本地端口：

```bash
./bin/fknat \
  --non-interactive \
  --mode client \
  --index index.example.com:9000 \
  --ca https://ca.example.com \
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

没有正式 CA 和扣费密钥时，只能显式使用 SDK 的开发安全档：

```bash
./bin/fknat --security-profile development
```

开发档仅用于受控测试，不能替代 production 准入和计费。

## 当前协议范围

fknat 暴露的是 TCP 监听端口和 TCP 后端。KCP 是 natP2p 网络中的底层传输路径，不表示本地端口是 UDP。UDP 应用代理需要 SDK 额外提供数据报会话语义后再实现。

## 验证

```bash
go test ./...
go build -o bin/fknat .
```

## License

[MIT](LICENSE)
