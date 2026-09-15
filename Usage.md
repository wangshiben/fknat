fknat 2026.09.15-r27 使用说明
===========================

fknat 是 NAT Client/NAT Server 共用的 TCP 转发程序。正式版固定使用
https://ca.fknat.top，并可在未指定 Index 和 Relay 时从 CA Web 自动发现入口。

一、选择文件
------------

- Linux x86-64：文件名包含 linux-amd64 或 amd64.deb/x86_64.rpm。
- Linux ARM64：文件名包含 linux-arm64、arm64.deb 或 aarch64.rpm。
- Windows 64 位：文件名包含 windows-amd64.zip。
- macOS Intel：文件名包含 darwin-amd64；Apple Silicon 使用 darwin-arm64。
- binaries 目录是可直接执行的裸二进制；installers 目录是后台服务安装包。

二、准备 CA Web 扣费密钥
-----------------------

1. 登录 CA Web 用户中心。
2. 生成并下载扣费密钥 JSON。
3. 将文件放入安装目录的 config/billing-key.json。

该文件决定节点消费归属。建议每个实际节点使用独立扣费密钥，以便单独吊销和审计。
它不是节点身份文件，不能拿来替代 FKNAT_IDENTITY_FILE。请勿公开、提交或打印私钥内容。

三、推荐安装方式
----------------

Linux DEB（Debian/Ubuntu）：

sudo apt install ./fknat_2026.09.15-r27_amd64.deb

Linux RPM（RHEL/Rocky/Alma/Fedora）：

sudo dnf install ./fknat-*.x86_64.rpm

Linux 便携包：

tar -xzf fknat-2026.09.15-r27-linux-amd64.tar.gz
cd fknat-2026.09.15-r27-linux-amd64
sudo ./install.sh

Linux 默认安装目录为 /opt/fknat。安装后服务会在后台等待配置，不会在
CONFIGURED=0 时启动 fknat 业务进程。

macOS：

tar -xzf fknat-2026.09.15-r27-darwin-arm64.tar.gz
cd fknat-2026.09.15-r27-darwin-arm64
sudo ./install.sh

macOS 默认安装目录为 /usr/local/lib/fknat，通过 LaunchDaemon 后台运行。

Windows：解压对应 zip，在“以管理员身份运行”的 PowerShell 中执行：

Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1

Windows 默认安装目录为 %ProgramData%\FkNat\fknat，通过计划任务后台运行。

四、配置 NAT Server
-------------------

先把 billing-key.json 放到 config 目录。Linux 示例：

sudo install -m 600 /安全路径/ca-billing-xxx.json /opt/fknat/config/billing-key.json
sudo /opt/fknat/control.sh edit-config

在现有 config/app.env 中至少确认以下值：

CONFIGURED=1
BNFS_SECURITY_PROFILE=production
BNFS_BILLING_KEY_FILE=config/billing-key.json
FKNAT_IDENTITY_FILE=data/server.identity
FKNAT_MODE=server
FKNAT_INDEX_ADDRESS=
FKNAT_RELAY_ADDRESS=
FKNAT_RELAY_ADDRESSES=
FKNAT_RELAY_COUNT=1
FKNAT_FORWARD_TARGET=127.0.0.1:8080

FKNAT_FORWARD_TARGET 是被代理的真实 HTTP/TCP 服务。Index 和 Relay 均留空时走
CA Web 自动发现；需要固定拓扑时才填写 host:port。保存后重启并查看日志：

sudo /opt/fknat/control.sh restart
sudo /opt/fknat/control.sh status
sudo /opt/fknat/control.sh logs

日志会输出该 NAT Server 的 64 位 NodeID。NAT Client 配置需要使用这个 NodeID。

五、配置 NAT Client
-------------------

Client 建议安装在另一台机器，并使用另一份扣费密钥。在 config/app.env 中至少确认：

CONFIGURED=1
BNFS_SECURITY_PROFILE=production
BNFS_BILLING_KEY_FILE=config/billing-key.json
FKNAT_IDENTITY_FILE=data/client.identity
FKNAT_MODE=client
FKNAT_INDEX_ADDRESS=
FKNAT_RELAY_ADDRESS=
FKNAT_LISTEN_ADDRESS=127.0.0.1:18081
FKNAT_SERVER_NODE_ID=<NAT Server 输出的 64 位 NodeID>

重启服务后，本地应用访问 127.0.0.1:18081，连接会经 Relay 转发到 Server 的
FKNAT_FORWARD_TARGET。只有确实需要局域网其他机器访问时，才把监听地址改成
0.0.0.0:18081，并同步配置主机防火墙。

六、直接运行裸二进制
---------------------

Linux/macOS 先赋予执行权限，并限制密钥权限：

chmod 755 ./fknat-2026.09.15-r27-linux-amd64
chmod 600 ./billing-key.json

Server（默认自动发现 Index/Relay）：

./fknat-2026.09.15-r27-linux-amd64 \
--non-interactive \
--mode server \
--billing-key ./billing-key.json \
--identity ./server.identity \
--target 127.0.0.1:8080

Client：

./fknat-2026.09.15-r27-linux-amd64 \
--non-interactive \
--mode client \
--billing-key ./billing-key.json \
--identity ./client.identity \
--server-id '<Server NodeID>' \
--listen 127.0.0.1:18081

不带参数直接运行会进入交互向导。使用 --help 查看全部参数，使用 --version
确认版本。裸二进制不会自动注册为后台服务，长期运行优先使用 installers 中的包。

七、日志、服务管理与卸载
-----------------------

Linux：

sudo /opt/fknat/control.sh {start|stop|restart|status|logs|edit-config}
sudo /opt/fknat/uninstall.sh

macOS 将 /opt/fknat 替换为 /usr/local/lib/fknat。Windows 在安装目录运行：

.\control.ps1 status
.\control.ps1 logs
.\control.ps1 restart
.\uninstall.ps1

日志保存在安装目录的 log 子目录。普通卸载保留 config、data 和 log；彻底清除会
删除身份、扣费队列和日志，仅应在确认不需要恢复时使用：Unix 使用
PURGE=1 ./uninstall.sh，Windows 使用 .\uninstall.ps1 -Purge。

八、重要注意事项
----------------

- data/*.identity 必须持久保存；删除或替换会改变 NodeID。
- 不要把 billing-key.json 当作 identity 文件使用。
- --relay 用于固定单个 Relay；Server 的 --relays 可配置最多三个 Relay，两者不能并用。
- 排障时先检查 CA Web、TCP/UDP Relay 端口、密钥权限、Server NodeID 和后端端口。

完整性校验：在完整发布目录执行 sha256sum -c SHA256SUMS；解压全平台总包后执行
sha256sum -c ARTIFACT_SHA256SUMS。Windows 可用 Get-FileHash -Algorithm SHA256
<文件> 后与清单比对。
