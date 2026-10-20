#!/usr/bin/env bash
# Octopus 一键部署 / 管理脚本（含交互菜单）
#
# 用法：
#   交互（有菜单）：
#     bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/octopus-deploy/main/install.sh)
#   一键（环境变量）：
#     PORT=9000 bash install.sh install
#   子命令：
#     bash install.sh install | update | uninstall | start | stop | restart | status | logs
#                     passwd | change-port | setup-caddy | backup | restore | addr | menu
#
# 说明：
#   - 安装 upstream 官方预编译二进制（bestruirui/octopus），不依赖 Docker
#   - 端口：默认随机取 30000-59999 的高位端口（避开 8080 这类被全网重点扫描的端口），
#     被占用时自动向上找空闲端口；也可用 PORT=xxxx 指定
#   - 数据目录 /opt/octopus/data，备份/升级都不会碰它
#   - 交互读取统一走 /dev/tty，解决 curl|bash 场景下菜单无输入的问题
#   - 对外开放（setup-caddy 等）前会检测后台是否还是默认密码 admin/admin，是则拒绝，
#     避免把管理后台以出厂密码直接暴露到公网

set -euo pipefail

UPSTREAM="bestruirui/octopus"
BIN="octopus"
APP_DIR="${APP_DIR:-/opt/octopus}"
DATA_DIR="$APP_DIR/data"
CONF_FILE="/etc/octopus-deploy.conf"
SERVICE_FILE="/etc/systemd/system/octopus.service"
SERVICE_NAME="octopus"
PORT_SCAN_MAX=50

# ---------- 通用工具 ----------
# _V 必须先置空再 read：Ctrl-D / EOF 时 read 不赋值，set -u 下直接读 $_V 会报 unbound
if [ -e /dev/tty ]; then
  _ask() { local p="$1" _V=""; read -r -p "$p" _V < /dev/tty || true; printf '%s' "$_V"; }
else
  _ask() { local p="$1" _V=""; read -r _V || true; printf '%s' "$_V"; }
fi
info(){ echo -e "\033[32m==>\033[0m $*"; }
warn(){ echo -e "\033[33m!!\033[0m $*"; }
err(){ echo -e "\033[31m✗\033[0m $*" >&2; }

need_root(){
  [ "$(id -u)" = "0" ] || { err "需要 root 权限，请用 sudo 运行"; exit 1; }
}

need_systemd(){
  command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ] || {
    err "未检测到 systemd，本脚本依赖 systemd 托管服务"; exit 1; }
}

# 判断某个包是否已装（有些包没有同名可执行文件，比如 ca-certificates）
has_pkg(){
  if command -v dpkg >/dev/null 2>&1 && dpkg -s "$1" >/dev/null 2>&1; then return 0; fi
  if command -v rpm  >/dev/null 2>&1 && rpm -q  "$1" >/dev/null 2>&1; then return 0; fi
  return 1
}

pkg_install(){
  local p missing=""
  for p in "$@"; do
    if command -v "$p" >/dev/null 2>&1 || has_pkg "$p"; then continue; fi
    missing="$missing $p"
  done
  [ -n "$missing" ] || return 0
  info "安装依赖:$missing"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq $missing
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q $missing
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q $missing
  else
    warn "无法自动安装依赖:$missing，请手动安装"; return 1
  fi
}

detect_arch(){
  local a s; a="$(uname -m)"; s="$(uname -s)"; ASSET=""
  case "$s" in
    Linux)
      case "$a" in
        x86_64|amd64)  ASSET="octopus-linux-amd64.zip" ;;
        aarch64|arm64) ASSET="octopus-linux-arm64.zip" ;;
        armv7l|armv6l) ASSET="octopus-linux-arm.zip" ;;
        i386|i686)     ASSET="octopus-linux-386.zip" ;;
        *) err "不支持的架构: $a"; exit 1 ;;
      esac ;;
    *) err "仅支持 Linux；Windows/macOS 请到 Releases 手动下载"; exit 1 ;;
  esac
}

# 生成 30000-59999 的随机端口。
# 目的不是安全边界，而是躲开扫描器的靶场：8080/8000/3000 这些是全网扫描常客，
# 五位数随机端口的命中概率低两三个数量级，能挡掉绝大多数无差别扫段。
gen_port(){
  printf '%s' $(( 30000 + RANDOM % 30000 ))
}

# ---------- 端口检测 ----------
port_in_use(){
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && return 0
    return 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    return 1
  fi
  # 兜底：直接连一下
  timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$p" >/dev/null 2>&1
}

port_owner(){
  local p="$1" out=""
  command -v ss >/dev/null 2>&1 && out="$(ss -lntp 2>/dev/null | awk -v p=":$p" '$4 ~ p"$"')"
  if [ -n "$out" ]; then
    echo "$out" | grep -oE 'users:\(\("[^"]+"' | head -1 | sed 's/.*("//'
  else
    echo "未知进程"
  fi
}

# 从 START 向上找第一个空闲端口；找不到返回 1
pick_free_port(){
  local p="${1:-$(gen_port)}" n=0
  while [ "$n" -lt "$PORT_SCAN_MAX" ]; do
    [ "$p" -gt 65535 ] && return 1
    port_in_use "$p" || { echo "$p"; return 0; }
    p=$((p+1)); n=$((n+1))
  done
  return 1
}

# ---------- 默认密码检测 ----------
# 用真实登录请求判定：密码正确返回 {"code":200,...}，错误返回 401。
# 注意走 localhost，只看服务端实际行为，不去解析数据库里的哈希。
is_default_password(){
  local p="${1:-${PORT:-}}" body
  [ -n "$p" ] || return 1
  body="$(curl -s -m 6 -X POST "http://127.0.0.1:$p/api/v1/user/login" \
          -H 'content-type: application/json' \
          -d '{"username":"admin","password":"admin"}' 2>/dev/null || true)"
  printf '%s' "$body" | grep -q '"code":200'
}

# 对外开放前的闸门：仍是出厂密码就拦住
guard_default_password(){
  # 注意：这里不要再写 local p="$1" port="$p"，
  # bash 的 local 会先把右侧全部展开再统一赋值，$p 会读到外层同名变量，
  # 导致检测的端口和提示的端口对不上。只用一个变量。
  local port="${1:-${PORT:-}}"
  if ! port_in_use "$port"; then
    err "端口 $port 没有监听，服务未运行，无法确认密码状态"
    warn "请先执行：bash $0 install   或   bash $0 start"
    return 1
  fi
  if is_default_password "$port"; then
    echo
    err "拒绝操作：后台密码仍是出厂默认 admin/admin"
    warn "服务监听 0.0.0.0:$port，一旦对外开放，任何人都能登录后台"
    warn "接管你的全部渠道、上游 Key 与对话记录"
    warn "请先改密码：bash $0 passwd    （或在菜单选 8）"
    echo
    return 1
  fi
  return 0
}

# ---------- 配置 ----------
load_cfg(){
  # 绝不 source 配置文件：里面含用户手输的域名，source 会把
  # 值里的 $(...)/反引号当命令执行。改为纯文本解析，值永远只是字符串。
  if [ -f "$CONF_FILE" ]; then
    local line k v
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in ''|'#'*) continue ;; esac
      k="${line%%=*}"
      v="${line#*=}"
      # 去掉写入时可能带的成对单引号
      case "$v" in
        \'*\') v="${v#\'}"; v="${v%\'}";;
      esac
      case "$k" in
        PORT)   [ -n "$v" ] && PORT="$v" ;;
        DOMAIN) DOMAIN="$v" ;;
      esac
    done < "$CONF_FILE"
  fi
  # 端口必须是纯数字，防止被改坏后带去 systemd
  case "${PORT:-}" in ''|*[!0-9]*) PORT="" ;; esac
  # 配置里没有可用端口时给一个随机高位端口；PORT 一旦赋值，本次运行内不再变化
  [ -n "${PORT:-}" ] || PORT="$(gen_port)"
  DOMAIN="${DOMAIN:-}"
}

save_cfg(){
  # 值统一用单引号包裹并转义内部的单引号：即便有人手动 source 这个文件，
  # 内容也只是字面量，不会被执行。
  {
    printf 'PORT=%s\n' "${PORT:-}"
    printf "DOMAIN='%s'\n" "$(printf '%s' "${DOMAIN:-}" | sed "s/'/'\\\\''/g")"
  } > "$CONF_FILE"
  chmod 600 "$CONF_FILE"
}

service_addr(){
  if [ -n "${DOMAIN:-}" ]; then
    printf 'https://%s' "$DOMAIN"
  else
    local ip
    ip="$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
          || hostname -I 2>/dev/null | awk '{print $1}')"
    printf 'http://%s:%s' "${ip:-<本机IP>}" "$PORT"
  fi
}

show_addr(){
  load_cfg
  local pwline
  if port_in_use "$PORT"; then
    if is_default_password "$PORT"; then
      pwline=" 账号：admin / admin   ← 仍是默认密码，公网暴露前必须修改"
    else
      pwline=" 账号：admin / 你设置的密码"
    fi
  else
    pwline=" 账号：admin   （服务未运行，密码状态未知）"
  fi
  echo
  echo "========================================================="
  echo " Octopus 管理后台：$(service_addr)"
  echo "$pwline"
  echo " 客户端 base_url：$(service_addr)/v1"
  echo "========================================================="
}

# ---------- 安装 ----------
fetch_binary(){
  local base="https://github.com/$UPSTREAM/releases/latest/download"
  local url="$base/$ASSET"
  local tmp; tmp="$(mktemp -d)"

  info "下载 $ASSET ..."
  if ! curl -fL --max-time 300 --retry 2 "$url" -o "$tmp/o.zip" 2>/dev/null; then
    # 直链失败时退回 API 查资产地址（受 60 次/小时限流，仅作兜底）
    info "直链失败，改用 API 查询资产地址 ..."
    local json
    json="$(curl -fsSL --max-time 25 "https://api.github.com/repos/$UPSTREAM/releases/latest" 2>/dev/null || true)"
    # 末尾的 || true 是必须的：set -euo pipefail 下 grep 无匹配会让整条管道返回 1，
    # 赋值语句失败会直接把脚本静默退出（而不是走下面的空值判断）
    url="$(printf '%s' "$json" | grep -o "\"browser_download_url\": *\"[^\"]*$ASSET\"" | grep -o 'https://[^"]*' | head -1 || true)"
    if [ -z "$url" ]; then
      err "未找到资产 $ASSET，可手动到 https://github.com/$UPSTREAM/releases 下载"
      rm -rf "$tmp"; exit 1
    fi
    curl -fL --max-time 300 "$url" -o "$tmp/o.zip" || { err "下载失败"; rm -rf "$tmp"; exit 1; }
  fi

  # 校验和：拿得到就校验，拿不到不阻断
  if command -v sha256sum >/dev/null 2>&1; then
    if curl -fsSL --max-time 20 "$base/SHA256SUMS" -o "$tmp/sums" 2>/dev/null; then
      local want got
      want="$(grep -E "(^|[[:space:]/])$ASSET\$" "$tmp/sums" | awk '{print $1}' | head -1 || true)"
      got="$(sha256sum "$tmp/o.zip" | awk '{print $1}')"
      if [ -n "$want" ] && [ "$want" != "$got" ]; then
        err "SHA256 校验失败（期望 $want，实际 $got）"; rm -rf "$tmp"; exit 1
      fi
      [ -n "$want" ] && info "SHA256 校验通过"
    fi
  fi

  command -v unzip >/dev/null 2>&1 || pkg_install unzip
  unzip -oq "$tmp/o.zip" -d "$tmp/x"
  local found
  found="$(find "$tmp/x" -maxdepth 3 -type f -name "$BIN" | head -1)"
  if [ -z "$found" ]; then
    err "解压后未找到 $BIN，包内文件："; find "$tmp/x" -maxdepth 2 -type f | head -10 >&2
    rm -rf "$tmp"; exit 1
  fi
  install -m 0755 -o root -g root "$found" "$APP_DIR/$BIN"
  rm -rf "$tmp"
  info "已安装到 $APP_DIR/$BIN"
}

write_unit(){
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Octopus LLM Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
Environment=OCTOPUS_SERVER_PORT=$PORT
Environment=OCTOPUS_SERVER_HOST=0.0.0.0
ExecStart=$APP_DIR/$BIN start
Restart=always
RestartSec=3
LimitNOFILE=65535
MemoryMax=${MEMORY_MAX:-512M}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

sync_config_json(){
  # 首次启动由程序自己生成；已存在则把端口对齐，避免配置文件与实际监听不一致
  [ -f "$DATA_DIR/config.json" ] || return 0
  sed -i "s/\"port\"[[:space:]]*:[[:space:]]*[0-9]\+/\"port\": $PORT/" "$DATA_DIR/config.json" 2>/dev/null || true
}

wait_ready(){
  local p="$1" i=0
  while [ "$i" -lt 30 ]; do
    if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$p/" 2>/dev/null; then return 0; fi
    sleep 1; i=$((i+1))
  done
  return 1
}

do_install(){
  need_root; need_systemd; detect_arch
  pkg_install curl ca-certificates

  local existed=0
  [ -f "$CONF_FILE" ] && existed=1
  load_cfg

  local want="$PORT"

  local was_running=0
  if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      was_running=1
    fi
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  fi

  # 升级场景（已安装且服务在跑）：原端口是自己占的，不是别人，
  # 等 stop 真正释放后应该看到空出来；只要停止后端口还在被占，
  # 才视为有别的进程占着。
  if [ "$existed" = "1" ] && [ "$was_running" = "1" ]; then
    # 最多等 8 秒让旧进程退出释放端口；正常 1-2 秒内就会空出
    local w=0
    while [ "$w" -lt 16 ]; do
      port_in_use "$want" || break
      sleep 0.5; w=$((w+1))
    done
    if port_in_use "$want"; then
      # 端口仍被占：检查是不是自己没退干净（pkill 兜底）
      local owner
      owner="$(port_owner "$want")"
      if printf '%s' "$owner" | grep -q "$BIN"; then
        warn "旧进程残留，强制清理后重试"
        pkill -f "$APP_DIR/$BIN" 2>/dev/null || true
        sleep 1
      fi
    fi
  fi

  mkdir -p "$APP_DIR" "$DATA_DIR"

  # ---- 端口决策 ----
  if ! [[ "$want" =~ ^[0-9]+$ ]] || [ "$want" -lt 1 ] || [ "$want" -gt 65535 ]; then
    err "端口非法：$want"; exit 1
  fi
  if port_in_use "$want"; then
    local owner alt
    owner="$(port_owner "$want")"
    # 如果是自己没退干净（可能性已很低），不算被占用
    if printf '%s' "$owner" | grep -q "$BIN"; then
      pkill -f "$APP_DIR/$BIN" 2>/dev/null || true
      sleep 1
      # 再探一次，空了就接着用原端口
      if ! port_in_use "$want"; then
        PORT="$want"
      else
        warn "端口 $want 仍被自身进程占用，自动换端口"
        alt="$(pick_free_port $((want+1)) 2>/dev/null || true)"
        [ -n "$alt" ] || { err "找不到空闲端口，请手动指定 PORT=xxxx"; exit 1; }
        warn "已自动改用空闲端口 $alt"
        PORT="$alt"
      fi
    else
      warn "端口 $want 已被占用${owner:+（进程：$owner）}"
      alt="$(pick_free_port $((want+1)) 2>/dev/null || true)"
      if [ -z "$alt" ]; then
        err "从 $want 起连续 $PORT_SCAN_MAX 个端口都不可用，请手动指定 PORT=xxxx"
        exit 1
      fi
      warn "已自动改用空闲端口 $alt"
      PORT="$alt"
    fi
  else
    PORT="$want"
    if [ "$existed" = "0" ]; then
      info "端口 $PORT 可用（随机高位端口，降低被全网扫描命中的概率）"
    else
      info "端口 $PORT 可用"
    fi
  fi
  save_cfg

  # ---- 二进制 ----
  if [ "$existed" = "1" ] && [ -x "$APP_DIR/$BIN" ]; then
    info "检测到已安装，执行升级（数据目录保留）"
  fi
  fetch_binary

  # ---- 服务 ----
  write_unit
  sync_config_json
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"

  if wait_ready "$PORT"; then
    info "服务已启动，端口 $PORT"
  else
    warn "服务已在 systemd 中启动，但 HTTP 探测未通过，请查看日志："
    warn "  journalctl -u $SERVICE_NAME -n 50 --no-pager"
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ufw 2>/dev/null; then
    info "检测到 ufw，如需外网访问请执行：ufw allow $PORT/tcp"
  fi
  warn "云厂商安全组需放行 $PORT/tcp，否则外网连不上"

  show_addr

  if is_default_password "$PORT"; then
    echo
    warn "================== 安全提醒 =================="
    warn "后台仍是出厂密码 admin/admin，而服务监听 0.0.0.0:$PORT"
    warn "只要安全组放行这个端口，任何人都能登录后台接管渠道与 Key"
    warn "立刻改密码：  bash $0 passwd        （或菜单选 8）"
    warn "再在后台「API 密钥」建一个下游 Key，客户端用这个 Key 访问"
    warn "=============================================="
  fi
}

# ---------- 动作 ----------
# 卸载：数据要不要一起删，由用户当场决定。
# PURGE=1 强制删干净，PURGE=0 强制保留（用于非交互/批量）。
do_uninstall(){
  need_root
  load_cfg

  local purge="${PURGE:-}" sz=""
  # 没有可交互终端时不能靠"回车=删光"，默认保守保留，除非显式 PURGE=1
  if [ -z "$purge" ] && [ ! -e /dev/tty ]; then
    purge=0
    warn "当前没有交互终端，默认保留数据；要删干净请用 PURGE=1 或 uninstall --purge"
  fi
  if [ -z "$purge" ]; then
    if [ ! -d "$APP_DIR" ] && [ ! -f "$CONF_FILE" ]; then
      purge=1
    else
      [ -d "$APP_DIR" ] && sz="$(du -sh "$APP_DIR" 2>/dev/null | awk '{print $1}' || true)"
      echo
      warn "即将卸载 Octopus：停止并删除服务、程序文件"
      if [ -d "$DATA_DIR" ]; then
        warn "  数据目录  $DATA_DIR  ${sz:+（$sz）}"
        warn "            含后台密码、渠道配置、上游 Key、对话记录"
      fi
      if [ -f "$CONF_FILE" ]; then
        warn "  配置文件  $CONF_FILE  （端口/域名）"
      fi
      local ans; ans="$(_ask "是否连数据与配置一起删除（不可恢复）？[Y/n]: ")"
      case "$ans" in
        n|N|no|No|NO) purge=0 ;;
        *)            purge=1 ;;
      esac
    fi
  fi

  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"; systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
  pkill -f "$APP_DIR/$BIN" 2>/dev/null || true
  rm -f "$APP_DIR/$BIN"

  if [ "$purge" = "1" ]; then
    rm -rf "$APP_DIR"
    rm -f "$CONF_FILE"
    info "已彻底卸载：程序、服务、数据目录、配置文件均已删除"
    if [ -f /etc/caddy/Caddyfile ] && grep -q "127.0.0.1:" /etc/caddy/Caddyfile 2>/dev/null; then
      warn "如曾用菜单 9 配置过 HTTPS 反代，/etc/caddy/Caddyfile 里的站点块需手动清理"
    fi
  else
    warn "已卸载程序与服务；数据保留在 $DATA_DIR"
    warn "配置文件保留：$CONF_FILE"
    warn "要彻底清理：rm -rf $APP_DIR $CONF_FILE"
  fi
}

do_start(){   need_root; systemctl start "$SERVICE_NAME" && info "已启动"; show_addr; }
do_stop(){    need_root; systemctl stop  "$SERVICE_NAME" && info "已停止"; }
do_restart(){ need_root; systemctl restart "$SERVICE_NAME" && info "已重启"; show_addr; }

do_status(){
  load_cfg
  systemctl status "$SERVICE_NAME" --no-pager || true
  if port_in_use "$PORT"; then
    echo; info "端口 $PORT 正在监听（进程：$(port_owner "$PORT")）"
  else
    echo; warn "端口 $PORT 没有监听"
  fi
  show_addr
}

do_logs(){
  if [ -f "$SERVICE_FILE" ]; then
    journalctl -u "$SERVICE_NAME" -n 100 --no-pager
  else
    warn "服务未安装"
  fi
}

# 隐藏回显读一行（用于输密码）
_read_secret(){
  local p="$1" v=""
  if [ -e /dev/tty ]; then
    read -r -s -p "$p" v < /dev/tty || true
  else
    read -r -s v || true
  fi
  echo >&2
  printf '%s' "$v"
}

do_passwd(){
  need_root
  [ -x "$APP_DIR/$BIN" ] || { err "未安装"; return; }
  # upstream 的 passwd 不接受交互输入，密码必须作为参数传：octopus passwd <password>
  local pw1 pw2
  info "修改后台 admin 密码（数据库：$DATA_DIR）"
  pw1="$(_read_secret '新密码（输入不回显）: ')"
  [ -n "$pw1" ] || { err "密码不能为空"; return; }
  [ "${#pw1}" -ge 6 ] || { err "密码至少 6 位"; return; }
  pw2="$(_read_secret '再输入一次: ')"
  [ "$pw1" = "$pw2" ] || { err "两次输入不一致，已取消"; return; }
  # `--` 收尾：密码以 - 开头时也不会被当成 flag
  if ( cd "$APP_DIR" && "./$BIN" passwd --config "$DATA_DIR/config.json" -- "$pw1" ); then
    info "密码已更新（账号仍是 admin，立即生效，无需重启）"
  else
    err "修改失败，请查看上面的输出；也可手动执行：cd $APP_DIR && ./$BIN passwd <新密码>"
    return 1
  fi
}

do_change_port(){
  need_root
  load_cfg
  local cur="$PORT"
  local np; np="$(_ask "新端口（当前 $cur）: ")"
  if [ -z "$np" ]; then warn "未输入，已取消"; return; fi
  if ! [[ "$np" =~ ^[0-9]+$ ]] || [ "$np" -lt 1 ] || [ "$np" -gt 65535 ]; then
    err "端口必须是 1-65535"; return
  fi
  if port_in_use "$np"; then
    local alt; alt="$(pick_free_port $((np+1)) 2>/dev/null || true)"
    warn "端口 $np 已被占用（$(port_owner "$np")）"
    [ -n "$alt" ] && warn "可用端口示例：$alt"
    local go; go="$(_ask "仍要使用 $np？[y/N]: ")"
    [ "$go" = "y" ] || [ "$go" = "Y" ] || { warn "已取消"; return; }
  fi
  PORT="$np"; save_cfg
  if [ -f "$SERVICE_FILE" ]; then
    sed -i "s/^Environment=OCTOPUS_SERVER_PORT=.*/Environment=OCTOPUS_SERVER_PORT=$PORT/" "$SERVICE_FILE"
    systemctl daemon-reload
    sync_config_json
    systemctl restart "$SERVICE_NAME" && info "已重启（新端口 $PORT）"
  fi
  if [ -n "${DOMAIN:-}" ] && [ -f /etc/caddy/Caddyfile ]; then
    sed -i "s/reverse_proxy 127.0.0.1:[0-9]*/reverse_proxy 127.0.0.1:$PORT/" /etc/caddy/Caddyfile
    caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true
    info "已同步 Caddy 反代端口"
  fi
  show_addr
}

do_setup_caddy(){
  need_root
  load_cfg
  # 对公网之前必须先确认后台密码不再是出厂值
  # 用 `|| return 0`：被拦下属于正常流程，不要让 set -e 把菜单一起带退出
  guard_default_password "$PORT" || return 0
  local d; d="$(_ask "对外访问域名（留空取消；需已解析到本机）: ")"
  [ -z "$d" ] && { warn "已取消"; return; }
  # 只允许合法域名字符集，同时挡住 $(...)、反引号、空格等一切注入形态
  if ! printf '%s' "$d" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; then
    err "域名格式非法：只允许字母、数字、点、连字符"
    return 1
  fi
  DOMAIN="$d"; save_cfg
  if ! command -v caddy >/dev/null 2>&1; then
    info "安装 Caddy ..."
    pkg_install debian-keyring debian-archive-keyring apt-transport-https || true
    if command -v apt-get >/dev/null 2>&1; then
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true
      apt-get update -qq && apt-get install -y -qq caddy
    else
      err "非 Debian 系，请手动安装 caddy 后重试"; return
    fi
  fi
  mkdir -p /etc/caddy
  cat > /etc/caddy/Caddyfile <<EOF
$d {
  reverse_proxy 127.0.0.1:$PORT
}
EOF
  caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
  systemctl restart caddy 2>/dev/null || caddy reload --config /etc/caddy/Caddyfile
  info "已配置 HTTPS 反代：https://$d"
  show_addr
}

do_backup(){
  need_root
  [ -d "$DATA_DIR" ] || { err "数据目录不存在：$DATA_DIR"; return; }
  local ts out; ts="$(date +%Y%m%d-%H%M%S)"; out="/root/octopus-data-$ts.tar.gz"
  local was_active=0
  systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && was_active=1
  [ "$was_active" = "1" ] && systemctl stop "$SERVICE_NAME"
  tar czf "$out" -C "$APP_DIR" data
  [ "$was_active" = "1" ] && systemctl start "$SERVICE_NAME"
  info "已备份到 $out（$(du -h "$out" | awk '{print $1}')）"
}

do_restore(){
  need_root
  local f; f="$(_ask "要恢复的备份文件路径（如 /root/octopus-data-xxx.tar.gz）: ")"
  [ -f "$f" ] || { err "文件不存在：$f"; return; }
  local go; go="$(_ask "将覆盖 $DATA_DIR 现有数据，确认？[y/N]: ")"
  [ "$go" = "y" ] || [ "$go" = "Y" ] || { warn "已取消"; return; }
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  mv "$DATA_DIR" "${DATA_DIR}.bak.$(date +%s)"
  tar xzf "$f" -C "$APP_DIR"
  systemctl start "$SERVICE_NAME" 2>/dev/null || true
  info "已恢复；旧数据保留为 ${DATA_DIR}.bak.*"
}

show_menu(){
  while true; do
    echo
    echo "====== Octopus 管理菜单 ======"
    echo " 1) 安装 / 更新 install"
    echo " 2) 状态 status"
    echo " 3) 启动 start"
    echo " 4) 停止 stop"
    echo " 5) 重启 restart"
    echo " 6) 查看日志 logs"
    echo " 7) 更改端口 change-port"
    echo " 8) 重置后台密码 passwd"
    echo " 9) 对外 HTTPS setup-caddy"
    echo "10) 备份数据 backup"
    echo "11) 恢复数据 restore"
    echo "12) 卸载 uninstall"
    echo " 0) 退出"
    echo "=============================="
    local sel; sel="$(_ask "请选择 [0-12]: ")"
    case "$sel" in
      1)  do_install ;;
      2)  do_status ;;
      3)  do_start ;;
      4)  do_stop ;;
      5)  do_restart ;;
      6)  do_logs ;;
      7)  do_change_port ;;
      8)  do_passwd ;;
      9)  do_setup_caddy ;;
      10) do_backup ;;
      11) do_restore ;;
      12) do_uninstall ;;
      0|"") exit 0 ;;
      *) warn "无效选择: $sel" ;;
    esac
  done
}

# ---------- 入口 ----------
case "${1:-}" in
  install|update) do_install ;;
  uninstall)
    case "${2:-}" in
      --purge|--all) PURGE=1 ;;
      --keep)        PURGE=0 ;;
    esac
    do_uninstall ;;
  start)          do_start ;;
  stop)           do_stop ;;
  restart)        do_restart ;;
  status)         do_status ;;
  logs)           do_logs ;;
  passwd)         do_passwd ;;
  change-port)    do_change_port ;;
  setup-caddy)    do_setup_caddy ;;
  backup)         do_backup ;;
  restore)        do_restore ;;
  addr)           show_addr ;;
  menu)           show_menu ;;
  "")
    if [ -e /dev/tty ] && [ -z "${PORT:-}" ]; then
      show_menu
    else
      do_install
    fi
    ;;
  *) warn "未知参数: $1"
     echo "用法: $0 [install|update|uninstall|start|stop|restart|status|logs|passwd|change-port|setup-caddy|backup|restore|addr|menu]"
     exit 1 ;;
esac
