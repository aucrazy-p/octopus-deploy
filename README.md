# octopus-deploy

Octopus（LLM 网关）的一键部署 / 管理脚本。**不用 Docker**，直接跑 upstream 官方预编译二进制 + systemd。

适配 Debian/Ubuntu/CentOS 等带 systemd 的 Linux，自动识别 x86_64 / arm64 / arm / 386。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/octopus-deploy/main/install.sh)
```

带终端运行时是**交互菜单**；在管道/CI 里则直接执行安装。

也可以直接给参数一键装：

```bash
# 指定端口（若被占用会自动避让）
PORT=9000 bash install.sh install

# 非交互安装
curl -fsSL https://raw.githubusercontent.com/aucrazy-p/octopus-deploy/main/install.sh | sudo bash -s install
```

## 管理菜单

```
====== Octopus 管理菜单 ======
 1) 安装 / 更新 install
 2) 状态 status
 3) 启动 start
 4) 停止 stop
 5) 重启 restart
 6) 查看日志 logs
 7) 更改端口 change-port
 8) 重置后台密码 passwd
 9) 对外 HTTPS setup-caddy
10) 备份数据 backup
11) 恢复数据 restore
12) 卸载 uninstall
 0) 退出
==============================
```

## 子命令

| 命令 | 作用 |
|---|---|
| `install` / `update` | 安装或升级（数据目录保留） |
| `uninstall` | 卸载程序与服务，数据保留 |
| `start` / `stop` / `restart` | 服务控制 |
| `status` | 服务状态 + 端口监听情况 |
| `logs` | 最近 100 行日志 |
| `passwd` | 重置后台管理员密码（忘密码不用重装） |
| `change-port` | 改监听端口并同步 systemd / Caddy |
| `setup-caddy` | 配域名 + 自动 HTTPS 反代 |
| `backup` / `restore` | 备份 / 恢复 `data/` 目录 |
| `addr` | 打印访问地址 |
| `menu` | 强制进菜单 |

## 端口占用自动避让

默认用 `8080`。安装前会先停掉自己的服务（避免把自己当成占用者），然后用 `ss` / `lsof` / TCP 探测三级检测：

```
!! 端口 8080 已被占用（进程：nginx）
!! 已自动改用空闲端口 8081
==> 端口 8081 可用
```

从目标端口向上最多扫描 50 个，找不到才报错并提示手动指定 `PORT=xxxx`。

改端口随时可用菜单第 7 项或 `bash install.sh change-port`。

## 安装后

```
程序：/opt/octopus/octopus
数据：/opt/octopus/data/{config.json,data.db}
配置：/etc/octopus-deploy.conf
服务：/etc/systemd/system/octopus.service
```

默认账号 `admin` / `admin`，**首次登录请立刻改密码**。

客户端（Cherry Studio / Cline / OpenAI SDK 等）统一配：

```
base_url: http://<服务器IP>:<端口>/v1
api_key:  <在后台「密钥」页创建的下游 Key>
model:    你在「分组」里定义的组名
```

> 记得放行安全组 / 防火墙端口，否则外网访问不到。

## 常用操作

```bash
systemctl status octopus
journalctl -u octopus -f
bash install.sh backup          # 备份到 /root/octopus-data-<时间>.tar.gz
```

升级只需重跑 `install`：会拉最新 release、替换二进制、重启服务，`data/` 原样保留。

## 说明

- 上游项目：[bestruirui/octopus](https://github.com/bestruirui/octopus)（AGPL-3.0）
- 本仓库只是部署包装脚本，不含上游代码
- 内存实测：空跑私有内存约 64MB，服务单元限制在 512MB
