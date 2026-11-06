# 网络请求路径

```text
Nintendo Switch (固定 IP: SWITCH_IP)
        |
        | DNS: ctest.cdn.n.nintendoswitch.cn
        v
OpenClash custom Hosts / dnsmasq
        |
        | 返回 ROUTER_LAN_IP
        v
Switch -> ROUTER_LAN_IP:80
        |
        | nftables DNAT（仅匹配指定 Switch IP）
        v
ROUTER_LAN_IP:HTTP_PORT
        |
        v
独立 uHTTPd + Ucode handler
        |
        | HTTP 200, text/plain, body: ok
        v
Switch 网络连接检测收到成功响应
```

## 组件职责

| 组件 | 职责 |
|---|---|
| OpenClash custom Hosts | 将国行检测域名解析到路由器 LAN IP |
| dnsmasq Rebinding 白名单 | 仅允许该检测域名返回私有 LAN 地址 |
| uHTTPd + Ucode | 返回本地检测所需的 HTTP 成功响应 |
| fw4 / nftables | 将指定 Switch 的 TCP 80 请求 DNAT 到本地 HTTP 端口 |
| procd | 管理 HTTP 服务并在开机时启动 |

## 安全边界

DNAT 规则同时限定源 IP、目标 IP 和目标端口。它不会把整个 LAN 的 TCP 80 请求都转发到本地服务。请为 Switch 设置 DHCP 静态租约，并确保配置文件中的 `SWITCH_IP` 与实际地址一致。
