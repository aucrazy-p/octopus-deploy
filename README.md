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
| `uninstall` | 卸载服务与程序，并询问是否连数据一起删除（详见下） |
| `start` / `stop` / `restart` | 服务控制 |
| `status` | 服务状态 + 端口监听情况 |
| `logs` | 最近 100 行日志 |
| `passwd` | 重置后台管理员密码（忘密码不用重装） |
| `change-port` | 改监听端口并同步 systemd / Caddy |
| `setup-caddy` | 配域名 + 自动 HTTPS 反代（默认密码会被拒绝） |
| `backup` / `restore` | 备份 / 恢复 `data/` 目录 |
| `addr` | 打印访问地址 |
| `menu` | 强制进菜单 |

## 端口：默认随机高位端口

**默认不再是 8080**。首次安装会从 `30000–59999` 里随机取一个端口。原因很实际：8080 / 8000 / 3000 这些是全网扫描器的固定靶场，五位数随机端口被无差别扫段命中的概率低两三个数量级。

端口来源优先级从高到低：

1. 环境变量 `PORT=xxxx`
2. `/etc/octopus-deploy.conf` 里已记录的端口（升级时不会被改掉）
3. 随机生成

确定端口前会先停掉自己的服务（避免把自己当成占用者），然后用 `ss` / `lsof` / TCP 探测三级检测：

```
!! 端口 31057 已被占用（进程：nginx）
!! 已自动改用空闲端口 31058
==> 端口 31058 可用
```

从目标端口向上最多扫描 50 个，找不到才报错并提示手动指定 `PORT=xxxx`。

改端口随时可用菜单第 7 项或 `bash install.sh change-port`（会同步 systemd 与 Caddy）。

> 随机端口只是降低被扫到的概率，**不是安全措施**。真正的防线是强密码 + 下游 API Key。

## 安装后

```
程序：/opt/octopus/octopus
数据：/opt/octopus/data/{config.json,data.db}
配置：/etc/octopus-deploy.conf
服务：/etc/systemd/system/octopus.service
```

默认账号 `admin` / `admin`，**首次登录请立刻改密码**。

### 默认密码拦截

服务监听 `0.0.0.0`，出厂账号又是 `admin` / `admin`，一旦放行安全组就等于把管理后台挂在公网上等人登录。脚本会在两处主动检查（用真实登录请求判定：密码正确返回 `code:200`，错误返回 401）：

| 时机 | 行为 |
|---|---|
| 安装完成后 | 仍是默认密码 → 打印醒目警告，提示改密码 + 建下游 Key |
| `setup-caddy` 执行前 | 仍是默认密码 → **直接拒绝**，先改密码再来 |

公网 IP + 端口自用时，建议按这个顺序：

```bash
bash install.sh passwd     # 1. 改掉 admin/admin
# 2. 后台「API 密钥」里建一个强随机下游 Key，客户端用这个
# 3. 安全组只放行你常用的出口 IP，别用 0.0.0.0/0
```

> HTTP 明文下 API Key 和对话内容在链路上是可读的。家用宽带问题不大，公共 WiFi 下别用公网地址直接连。

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

## 卸载

菜单第 12 项或 `bash install.sh uninstall`。执行前会先列出要删的东西：

```
!! 即将卸载 Octopus：停止并删除服务、程序文件
!!   数据目录  /opt/octopus/data  （12M）
!!            含后台密码、渠道配置、上游 Key、对话记录
!!   配置文件  /etc/octopus-deploy.conf  （端口/域名）
是否连数据与配置一起删除（不可恢复）？[Y/n]:
```

- **直接回车 / 输 y** → 连 `/opt/octopus`（含 `data/`）和 `/etc/octopus-deploy.conf` 一起删掉，服务器上不留残留
- **输 n** → 只删程序和服务，数据与配置保留，屏幕会打印彻底清理用的 `rm -rf` 命令

非交互场景可以显式指定，不走提问：

```bash
bash install.sh uninstall --purge   # 全删（等价 PURGE=1）
bash install.sh uninstall --keep    # 保留数据（等价 PURGE=0）
```

> 没有可交互终端时（cron / 管道），脚本默认**保留**数据，避免误删。
> 如果曾用菜单 9 配过 HTTPS 反代，`/etc/caddy/Caddyfile` 里的站点块不会被自动删掉，需要手动清理。

## 说明

- 上游项目：[bestruirui/octopus](https://github.com/bestruirui/octopus)（AGPL-3.0）
- 本仓库只是部署包装脚本，不含上游代码
- 内存实测：空跑私有内存约 64MB，服务单元限制在 512MB
