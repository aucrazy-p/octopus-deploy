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
#   - 端口占用自动检测：默认 8080，被占用时自动向上找空闲端口
#   - 数据目录 /opt/octopus/data，备份/升级都不会碰它
#   - 交互读取统一走 /dev/tty，解决 curl|bash 场景下菜单无输入的问题

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
if [ -e /dev/tty ]; then
  _ask() { local p="$1"; read -r -p "$p" _V < /dev/tty; printf '%s' "$_V"; }
else
  _ask() { local p="$1"; read -r _V; printf '%s' "$_V"; }
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

pkg_install(){
  for p in "$@"; do command -v "$p" >/dev/null 2>&1 || INSTALL_PKGS="$INSTALL_PKGS $p"; done
  [ -z "${INSTALL_PKGS:-}" ] && return 0
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq $INSTALL_PKGS
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q $INSTALL_PKGS
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q $INSTALL_PKGS
  else
    warn "无法自动安装依赖:$INSTALL_PKGS，请手动安装"; return 1
  fi
  INSTALL_PKGS=""
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
  local p="${1:-8080}" n=0
  while [ "$n" -lt "$PORT_SCAN_MAX" ]; do
    [ "$p" -gt 65535 ] && return 1
    port_in_use "$p" || { echo "$p"; return 0; }
    p=$((p+1)); n=$((n+1))
  done
  return 1
}

# ---------- 配置 ----------
load_cfg(){
  [ -f "$CONF_FILE" ] && . "$CONF_FILE"
  PORT="${PORT:-8080}"
  DOMAIN="${DOMAIN:-}"
}

save_cfg(){
  cat > "$CONF_FILE" <<EOF
PORT=$PORT
DOMAIN=${DOMAIN:-}
EOF
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
  echo
  echo "========================================================="
  echo " Octopus 管理后台：$(service_addr)"
  echo " 默认账号：admin / admin   ← 首次登录请立刻改密码"
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
    url="$(printf '%s' "$json" | grep -o "\"browser_download_url\": *\"[^\"]*$ASSET\"" | grep -o 'https://[^"]*' | head -1)"
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
      want="$(grep -E "(^|[[:space:]/])$ASSET\$" "$tmp/sums" | awk '{print $1}' | head -1)"
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

  # 先停掉自己的服务，避免把「自己的端口」误判为被别人占用
  if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  fi

  mkdir -p "$APP_DIR" "$DATA_DIR"

  # ---- 端口决策 ----
  local want="${PORT:-8080}"
  if ! [[ "$want" =~ ^[0-9]+$ ]] || [ "$want" -lt 1 ] || [ "$want" -gt 65535 ]; then
    err "端口非法：$want"; exit 1
  fi
  if port_in_use "$want"; then
    local owner alt
    owner="$(port_owner "$want")"
    warn "端口 $want 已被占用${owner:+（进程：$owner）}"
    alt="$(pick_free_port $((want+1)) 2>/dev/null || true)"
    if [ -z "$alt" ]; then
      err "从 $want 起连续 $PORT_SCAN_MAX 个端口都不可用，请手动指定 PORT=xxxx"
      exit 1
    fi
    warn "已自动改用空闲端口 $alt"
    PORT="$alt"
  else
    PORT="$want"
    info "端口 $PORT 可用"
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
  warn "云厂商安全组也需要放行 $PORT 端口"

  show_addr
}

# ---------- 动作 ----------
do_uninstall(){
  need_root
  load_cfg
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"; systemctl daemon-reload 2>/dev/null || true
  pkill -f "$APP_DIR/$BIN" 2>/dev/null || true
  rm -f "$APP_DIR/$BIN"
  warn "已卸载程序与服务；数据保留在 $DATA_DIR（确认不需要可手动删除）"
  warn "配置文件保留：$CONF_FILE"
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

do_passwd(){
  need_root
  [ -x "$APP_DIR/$BIN" ] || { err "未安装"; return; }
  info "按提示输入新密码（读的是 $DATA_DIR 下的数据库）"
  ( cd "$APP_DIR" && "./$BIN" passwd )
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
  local d; d="$(_ask "对外访问域名（留空取消；需已解析到本机）: ")"
  [ -z "$d" ] && { warn "已取消"; return; }
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
  uninstall)      do_uninstall ;;
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
