# 国行 Nintendo Switch 联网检测修复（iStoreOS / OpenWrt）

在 iStoreOS/OpenWrt 路由器上运行本地 HTTP 检测响应服务，通过 OpenClash DNS、dnsmasq Rebinding 白名单和 nftables DNAT，修复国行 Nintendo Switch 的网络连接测试失败问题（例如部分用户遇到的 `2110-3127`）。

> [!IMPORTANT]
> **本项目只修复 Switch 系统的网络连接检测，不会恢复腾讯已经停止运营的国行 Nintendo Switch eShop、在线游戏、账号或其他官方网络服务。**
>
> 不需要破解 Switch，也不需要修改 Switch 系统文件。

## 功能

- 为国行检测域名 `ctest.cdn.n.nintendoswitch.cn` 配置本地 DNS 映射。
- 使用独立 uHTTPd + Ucode 返回 HTTP `200 OK` 和 `ok`。
- 不占用路由器原有 LuCI/uHTTPd 的 TCP 80 端口。
- 只将指定 Switch IP 发往路由器 TCP 80 的流量 DNAT 到本地 HTTP 端口。
- 仅对白名单域名添加 dnsmasq Rebinding 例外，不关闭全局保护。
- 使用 procd 管理服务并设置开机启动。
- 提供卸载脚本和只读诊断脚本。

## 工作原理

```text
Switch
  | DNS 查询国行检测域名
  v
OpenClash custom Hosts -> ROUTER_LAN_IP
  |
  | HTTP 请求 ROUTER_LAN_IP:80
  v
nftables DNAT（仅匹配指定 Switch IP）
  |
  v
独立 uHTTPd：ROUTER_LAN_IP:8081
  |
  v
HTTP 200 OK，正文 ok
```

详细流程见 [docs/NETWORK_FLOW.md](docs/NETWORK_FLOW.md)。

## 适用环境

本项目以以下真实测试环境整理：

| 项目 | 测试配置 |
|---|---|
| 游戏机 | 国行 Nintendo Switch，原版系统 |
| 路由器系统 | iStoreOS 24.10.8 |
| 防火墙 | firewall4 / nftables |
| DNS | OpenClash + dnsmasq |
| HTTP | uHTTPd + uhttpd-mod-ucode |

其他 OpenWrt 衍生系统可能存在包名、OpenClash 配置结构或 fw4 行为差异，尚不能保证完全兼容。

## 安装前准备

1. 路由器使用 iStoreOS/OpenWrt，且启用 firewall4/nftables。
2. 已安装并正常运行 OpenClash，使用其自定义 Hosts 功能。
3. Switch 与路由器处于同一 LAN。
4. 为 Switch 设置 DHCP 静态租约，确保 IP 地址固定。
5. 能通过 SSH 以 root 身份登录路由器。

### 网络参数

先复制配置模板：

```sh
cp config.example config.conf
```

编辑 `config.conf`，按实际网络修改：

```sh
ROUTER_LAN_IP="192.168.1.1"
SWITCH_IP="192.168.1.155"
HTTP_PORT="8081"
TEST_DOMAIN="ctest.cdn.n.nintendoswitch.cn"
OPENCLASH_HOSTS_FILE="/etc/openclash/custom/openclash_custom_hosts.list"
```

说明：

- `ROUTER_LAN_IP`：路由器 LAN 地址。
- `SWITCH_IP`：Switch 的固定 LAN 地址。
- `HTTP_PORT`：本地 HTTP 监听端口，默认 8081。应选择未被占用的端口。
- `TEST_DOMAIN`：国行检测域名，通常无需修改。
- `OPENCLASH_HOSTS_FILE`：OpenClash 自定义 Hosts 文件路径。

**不要直接使用模板中的示例 IP。** 必须确认路由器和 Switch 的实际地址，并让 `SWITCH_IP` 与 DHCP 静态租约一致。

## 安装

将整个项目目录放到路由器上，进入项目目录。例如：

```sh
cd /root/switch-cn-network-test-fix
cp config.example config.conf
vi config.conf
```

确认参数后执行：

```sh
sh scripts/install.sh
```

如果配置文件放在其他路径，可显式指定：

```sh
sh scripts/install.sh /path/to/config.conf
```

安装脚本会检查必要组件，并执行以下操作：

1. 备份原有 `/etc/config/firewall`、`dhcp`、`openclash` 和 Hosts 文件（存在时）。
2. 创建 Ucode HTTP 响应处理器。
3. 在 OpenClash 自定义 Hosts 中添加检测域名映射；若发现同域名映射到不同 IP，会停止并提示，不会覆盖。
4. 开启 OpenClash 自定义 Hosts。
5. 为目标域名添加 dnsmasq Rebinding 白名单。
6. 创建只匹配指定 Switch 的 nftables DNAT 规则。
7. 注册 firewall4 include。
8. 创建并启用 procd 服务。

初次安装前，请确认 `/usr/lib/uhttpd_ucode.so` 存在。若缺少，可在路由器执行：

```sh
opkg update
opkg install uhttpd-mod-ucode
```

本项目不会自动替你更改软件源或升级路由器系统。

## 验证

### 1. 检查服务

```sh
/etc/init.d/switch-ctest status
netstat -lnpt | grep ':8081'
```

正常情况下，8081 应监听在配置的路由器 LAN IP 上。

### 2. 检查 DNS

在 Windows CMD 中执行（将地址换成自己的路由器 LAN IP）：

```cmd
nslookup ctest.cdn.n.nintendoswitch.cn 192.168.1.1
```

预期解析结果为路由器 LAN IP。

### 3. 检查 HTTP 响应

在 Windows PowerShell 或 CMD 中执行：

```powershell
curl.exe -i -A "NX NIFM/00" -H "Host: ctest.cdn.n.nintendoswitch.cn" http://192.168.1.1:8081/
```

预期响应包含：

```http
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 2
Cache-Control: max-age=0, no-cache, no-store
Pragma: no-cache
X-Organization: Nintendo

ok
```

### 4. 检查 DNAT

在路由器执行：

```sh
nft list chain inet fw4 dstnat_lan
```

然后在 Switch 上执行网络连接测试，再次查看该规则的 `counter packets`。计数增加说明请求命中了转发规则。

### 5. 检查开机启动

```sh
ls -l /etc/rc.d/S99switch-ctest
/etc/init.d/switch-ctest status
```

建议在方便时重启路由器，再重复检查服务和端口监听。

## 诊断

运行只读诊断脚本：

```sh
sh scripts/diagnose.sh
```

也可以指定配置文件：

```sh
sh scripts/diagnose.sh /path/to/config.conf
```

诊断脚本会汇总服务进程、端口、OpenClash Hosts、dnsmasq Rebinding、DNS 查询、fw4/nftables 和相关日志，不会主动修改配置。

遇到问题时，先按 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) 的 DNS → HTTP → DNAT → Switch 顺序排查。

## 卸载

在项目目录执行：

```sh
sh scripts/uninstall.sh
```

卸载脚本会停止并禁用本项目服务、删除本项目命名的 firewall include、撤销本项目添加的 Rebinding 白名单和 Hosts 映射，并在开关仍保持本项目设置的 `1` 时，将 OpenClash custom Hosts 开关恢复到安装前的值（如果安装前存在该值）。如果卸载前该开关已被手动改成其他值，脚本会保留当前值。

原始配置备份会保留在：

```text
/root/switch-ctest-backup-时间戳/
```

**卸载脚本要求安装状态文件 `/etc/switch-ctest/state` 存在。** 如果该文件丢失，脚本会拒绝猜测哪些 DNS/Hosts 设置属于本项目，以免误删其他配置。

## 安全与边界

- 请使用 Switch 的 DHCP 静态租约，避免 IP 变化导致 DNAT 规则不再命中。
- 不要关闭全局 DNS Rebinding Protection；本项目只添加单域名例外。
- 不要停止或替换路由器原有 LuCI/uHTTPd 服务。
- 不要把公网地址、设备标识或完整路由器配置未经检查地发布到公开 Issue。
- HTTP 响应中的 `X-Organization: Nintendo` 是模拟检测响应所用的字段，并不表示本服务由 Nintendo 官方提供或认可。
- 本项目不提供、不代理，也不恢复任何 Nintendo/Tencent 在线业务。

## 已验证结果

作者在 iStoreOS 24.10.8 环境中完成了以下实测：

- DNS 将国行检测域名解析到路由器 LAN IP。
- 本地 uHTTPd 返回 HTTP 200，正文为 `ok`。
- Switch 的 TCP 80 请求命中 nftables DNAT 规则。
- 国行 Switch 原版系统的网络连接测试成功。
- 服务进程由 procd 管理，开机启动链接已创建。

目前不代表已在所有 OpenWrt 版本、所有 OpenClash 版本或所有网络拓扑中验证。

## 目录结构

```text
switch-cn-network-test-fix/
├── README.md
├── config.example
├── .gitignore
├── scripts/
│   ├── install.sh
│   ├── uninstall.sh
│   └── diagnose.sh
└── docs/
    ├── NETWORK_FLOW.md
    └── TROUBLESHOOTING.md
```

## 反馈与贡献

欢迎提交 Issue，建议提供：

- iStoreOS/OpenWrt 版本。
- OpenClash 版本及 DNS 模式。
- DNS 查询结果。
- HTTP 测试结果。
- `fw4 check` 和相关 nftables 规则输出。
- `scripts/diagnose.sh` 输出（发布前请遮盖敏感信息）。

请不要上传完整 `/etc/config`、公网 IP、密码、订阅链接或其他敏感配置。

## License

本项目采用 [MIT License](LICENSE) 开源许可证。

你可以自由使用、复制、修改和分发本项目，但需要保留原始版权声明和许可证文本。使用本项目产生的风险由使用者自行承担。
