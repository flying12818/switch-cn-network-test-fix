# 故障排查

按“DNS → HTTP → 防火墙 → Switch”顺序检查，不要一开始就改动多个组件。

## 1. DNS 没有解析到路由器 LAN IP

在 Windows 上执行：

```cmd
nslookup ctest.cdn.n.nintendoswitch.cn 192.168.1.1
```

将 `192.168.1.1` 换成自己的路由器 LAN IP。预期结果是该域名返回路由器 IP。

检查：

- `config.conf` 中的 `ROUTER_LAN_IP` 是否正确。
- `/etc/openclash/custom/openclash_custom_hosts.list` 是否包含域名映射。
- `openclash.config.custom_host` 是否为 `1`。
- OpenClash 是否已重新加载。
- dnsmasq 是否存在该域名的 Rebinding 白名单。

查看配置：

```sh
uci -q get openclash.config.custom_host
uci -q show 'dhcp.@dnsmasq[0].rebind_domain'
cat /etc/openclash/custom/openclash_custom_hosts.list
```

## 2. 日志出现 DNS Rebinding 告警

典型日志：

```text
possible DNS-rebind attack detected: ctest.cdn.n.nintendoswitch.cn
```

只对白名单域名放行，不建议关闭全局 Rebinding Protection：

```sh
uci add_list 'dhcp.@dnsmasq[0].rebind_domain=/ctest.cdn.n.nintendoswitch.cn/'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

历史日志中可能保留添加白名单之前的告警。要结合重新查询 DNS 的结果判断当前状态，不能仅凭旧日志认定仍被拦截。

## 3. uHTTPd Ucode 模块或回调错误

确认模块文件：

```sh
ls -l /usr/lib/uhttpd_ucode.so
```

如缺失，可尝试：

```sh
opkg update
opkg install uhttpd-mod-ucode
```

本项目使用的处理文件必须采用 uHTTPd Ucode 模板格式，核心结构为：

```ucode
{% 
'use strict';

global.handle_request = function(env) {
    // response
};
%}
```

如果缺少模板包裹或 `global.handle_request`，可能出现：

```text
The ucode handler declares no handle_request() callback.
```

## 4. 8081 端口没有监听

执行：

```sh
/etc/init.d/switch-ctest status
ps | grep '[u]httpd'
netstat -lnpt | grep ':8081'
logread | grep -i switch-ctest | tail -n 50
```

也可以重启专用服务：

```sh
/etc/init.d/switch-ctest restart
```

正常情况下，路由器会有两个 uhttpd 进程：一个是原有 LuCI 管理界面，另一个监听本项目的 8081 端口。这是预期现象。

## 5. 为什么不直接让模拟服务监听 80 端口？

iStoreOS 的 LuCI/uHTTPd 通常已经使用 TCP 80/443。如果另起服务监听同一地址和端口，会发生端口冲突，影响路由器管理界面。

本项目让独立服务监听 `ROUTER_LAN_IP:8081`，再使用 nftables DNAT，只转发指定 Switch 发往路由器 TCP 80 的请求。不要为了本项目停止或覆盖原有管理界面服务。

## 6. nftables 规则未加载或计数器不增加

检查：

```sh
fw4 check
uci -q show firewall.switch_ctest
nft list chain inet fw4 dstnat_lan
```

核对规则的源地址、目标地址和端口：

- 源地址必须是 Switch 当前固定 IP。
- 目标地址必须是路由器 LAN IP。
- 目标 TCP 端口必须是 80。

在 Switch 上重新执行网络连接测试，然后再次查看 `counter packets`。计数器增加表示规则命中。

如果 `fw4 check` 同时输出其他已有组件（例如 DockerNAT）的兼容性提示，应先看最终检查是否通过，以及本项目的规则是否实际出现在 nftables 链中。不要未经判断就修改 Docker 配置。

## 7. Windows 能访问 8081，但 Switch 测试仍失败

Windows 直接访问 8081 只证明本地 HTTP 服务可用，并不能单独证明 Switch 的完整流量路径正常。依次确认：

1. Switch 使用的 DNS 确实返回路由器 LAN IP。
2. Switch 的 DHCP 保留地址与 `SWITCH_IP` 一致。
3. Switch 请求命中了 `dstnat_lan` 中的 DNAT 规则。
4. 8081 服务仍处于监听状态。

可先在 Windows 执行：

```powershell
curl.exe -i -A "NX NIFM/00" -H "Host: ctest.cdn.n.nintendoswitch.cn" http://192.168.1.1:8081/
```

替换为自己的路由器 IP。预期响应包含 `HTTP/1.1 200 OK` 和正文 `ok`。

## 8. dnsmasq 重启时出现 udhcpc no lease

某些网络环境下，重启相关服务时日志可能同时出现 DHCP 客户端未获得租约的提示。不要只根据这一行判断 DNS 服务是否失败；应进一步确认 dnsmasq 是否恢复监听、域名查询是否得到预期结果，以及 DHCP 客户端是否确实需要 WAN 地址。

## 9. 一键诊断

在路由器上执行：

```sh
sh scripts/diagnose.sh config.conf
```

脚本只读取并显示服务、DNS、OpenClash、nftables 和日志状态，不会修改配置。分享诊断结果到公开 Issue 前，请检查并遮盖公网 IP、设备名称或其他不希望公开的信息。

## 10. 服务检测成功不代表国行在线服务恢复

本地服务只模拟系统连接测试所需的 HTTP 成功响应。它不会恢复腾讯已停止运营的国行 eShop、账号服务、在线游戏匹配、下载或其他官方服务。不要将“网络连接测试成功”描述为“国行在线服务恢复”。
