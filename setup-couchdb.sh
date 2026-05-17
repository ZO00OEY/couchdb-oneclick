#!/usr/bin/env bash
#===============================================================================
# CouchDB + Obsidian LiveSync 一键安装配置脚本
# 适用于 Debian / Ubuntu 系列 Linux
# 使用方法: sudo bash setup-couchdb.sh
#===============================================================================

set -eo pipefail

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ===== 全局变量 =====
COUCHDB_USER="obsidian_user"
COUCHDB_PASSWORD=""
COUCHDB_DB="obsidian"
SERVER_ADDR=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CREDENTIALS_FILE="${SCRIPT_DIR}/couchdb-credentials.txt"

# ===== 工具函数 =====

print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  CouchDB + Obsidian LiveSync 一键安装脚本${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_step() {
    echo -e "\n${CYAN}${BOLD}[$1/$TOTAL_STEPS]${NC} ${BOLD}$2${NC}"
}

print_success() {
    echo -e "  ${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "  ${RED}✗${NC} $1"
}

print_warning() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

# 调用 CouchDB API（不带认证）
api_noauth() {
    local method=$1 url=$2 data=$3
    if [[ -n "$data" ]]; then
        curl -s -X "$method" "http://localhost:5984${url}" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -s -X "$method" "http://localhost:5984${url}" \
            -H "Content-Type: application/json"
    fi
}

# 调用 CouchDB API（带认证）
api() {
    local method=$1 url=$2 data=$3
    if [[ -n "$data" ]]; then
        curl -s -X "$method" "http://localhost:5984${url}" \
            -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -s -X "$method" "http://localhost:5984${url}" \
            -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" \
            -H "Content-Type: application/json"
    fi
}

# 写入一项简单配置
set_config() {
    local section=$1 key=$2 value=$3
    local resp http_code
    resp=$(curl -s -w "\n%{http_code}" \
        -X PUT "http://localhost:5984/_node/_local/_config/${section}/${key}" \
        -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d "\"${value}\"")
    http_code=$(echo "$resp" | tail -1)
    if [[ "$http_code" == "200" ]]; then
        print_success "${section}/${key} = ${value}"
        return 0
    else
        print_error "${section}/${key} 写入失败 (HTTP ${http_code})"
        return 1
    fi
}

# 获取本机 IP 列表
collect_ips() {
    local ips=()
    local ip

    # 方式1：通过 ip 命令获取全局 IPv4（排除 Docker 网桥、回环）
    if command -v ip &>/dev/null; then
        while IFS= read -r ip; do
            [[ -n "$ip" ]] && ips+=("$ip")
        done < <(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | sort -u)
    fi

    # 方式2：hostname -I 兜底
    if [[ ${#ips[@]} -eq 0 ]] && command -v hostname &>/dev/null; then
        while IFS= read -r ip; do
            [[ -n "$ip" ]] && ips+=("$ip")
        done < <(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.')
    fi

    # 尝试获取公网 IP
    local pub_ip
    pub_ip=$(curl -4 -s --connect-timeout 3 ifconfig.me 2>/dev/null || true)
    if [[ -n "$pub_ip" ]] && [[ "$pub_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local found=false
        for ip in "${ips[@]}"; do
            [[ "$ip" == "$pub_ip" ]] && found=true && break
        done
        if ! $found; then
            ips+=("$pub_ip")
        fi
    fi

    echo "${ips[@]}"
}

# 判断是否为内网 IP (RFC 1918)
is_lan_ip() {
    local ip=$1
    local a b
    IFS=. read -r a b _ _ <<< "$ip"
    [[ "$a" == "10" ]] && return 0
    [[ "$a" == "172" && "$b" -ge 16 && "$b" -le 31 ]] && return 0
    [[ "$a" == "192" && "$b" == "168" ]] && return 0
    return 1
}

# ===== 开始 =====

TOTAL_STEPS=13
STEP=0

print_banner

# ----- 1. 检测 root 权限 -----
STEP=$((STEP + 1))
print_step "$STEP" "检测 root 权限"
if [[ $EUID -ne 0 ]]; then
    print_error "请使用 sudo 运行此脚本: sudo bash setup-couchdb.sh"
    exit 1
fi
print_success "root 权限确认"

# ----- 2. 检测系统 -----
STEP=$((STEP + 1))
print_step "$STEP" "检测系统环境"
if ! command -v apt &>/dev/null; then
    print_error "此脚本仅适用于 Debian / Ubuntu 系列 Linux（需要 apt 包管理器）"
    exit 1
fi

# 检测版本代号
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-unknown}"
else
    CODENAME="unknown"
fi

if [[ "$CODENAME" == "unknown" ]]; then
    print_error "无法获取系统版本代号，请确认 /etc/os-release 文件存在"
    exit 1
fi

print_success "系统: ${NAME:-Linux} (${CODENAME})"

# ----- 3. 补装依赖 -----
STEP=$((STEP + 1))
print_step "$STEP" "检查并安装依赖工具"
DEPS_TO_INSTALL=()
for dep in curl gnupg ca-certificates openssl; do
    if ! command -v "$dep" &>/dev/null; then
        DEPS_TO_INSTALL+=("$dep")
    fi
done

if [[ ${#DEPS_TO_INSTALL[@]} -gt 0 ]]; then
    echo -e "  需要安装: ${DEPS_TO_INSTALL[*]}"
    apt update -q
    apt install -y "${DEPS_TO_INSTALL[@]}"
    print_success "依赖安装完成"
else
    print_success "所有依赖已就绪"
fi

# ----- 4. 生成凭证 -----
STEP=$((STEP + 1))
print_step "$STEP" "生成安全凭证"

# 检查是否已有凭证文件（重新运行时复用密码，避免新旧密码冲突）
if [[ -f "${CREDENTIALS_FILE}" ]]; then
    COUCHDB_PASSWORD=$(grep -oP '密码:\s+\K\S+' "${CREDENTIALS_FILE}" 2>/dev/null || true)
    if [[ -n "$COUCHDB_PASSWORD" ]]; then
        print_success "检测到已有凭证文件，复用原有密码"
        print_success "用户名: ${COUCHDB_USER}"
        print_success "数据库名: ${COUCHDB_DB}"
    fi
fi

if [[ -z "$COUCHDB_PASSWORD" ]]; then
    COUCHDB_PASSWORD=$(openssl rand -hex 16)
    print_success "用户名: ${COUCHDB_USER}"
    print_success "密码已随机生成 (32 位十六进制)"
    print_success "数据库名: ${COUCHDB_DB}"
fi

# ----- 5. 安装 CouchDB -----
STEP=$((STEP + 1))
print_step "$STEP" "安装 CouchDB"

COUCHDB_ALREADY_INSTALLED=false
if command -v couchdb &>/dev/null || dpkg -l couchdb &>/dev/null 2>&1; then
    echo -e "  ${YELLOW}CouchDB 似乎已安装，跳过安装步骤${NC}"
    COUCHDB_ALREADY_INSTALLED=true
fi

if ! $COUCHDB_ALREADY_INSTALLED; then
    # 添加 GPG 密钥
    echo "  添加 Apache CouchDB GPG 密钥..."
    curl -fsSL https://couchdb.apache.org/repo/keys.asc | \
        gpg --dearmor --batch --yes -o /usr/share/keyrings/couchdb-archive-keyring.gpg 2>/dev/null

    # 添加 apt 源
    echo "  添加 CouchDB apt 源 (${CODENAME})..."
    echo "deb [signed-by=/usr/share/keyrings/couchdb-archive-keyring.gpg] https://apache.jfrog.io/artifactory/couchdb-deb/ ${CODENAME} main" | \
        tee /etc/apt/sources.list.d/couchdb.list > /dev/null

    # 安装（预填配置项，跳过交互界面）
    echo "couchdb couchdb/mode select standalone" | debconf-set-selections
    echo "couchdb couchdb/bindaddress string 127.0.0.1" | debconf-set-selections
    echo "  正在安装 CouchDB..."
    apt update -q
    apt install -y couchdb

    print_success "CouchDB 安装完成"
fi

# ----- 6. 等待 CouchDB 启动 -----
STEP=$((STEP + 1))
print_step "$STEP" "等待 CouchDB 服务就绪"

# 确保服务在运行
systemctl start couchdb 2>/dev/null || service couchdb start 2>/dev/null || true

MAX_WAIT=60
WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if curl -s --connect-timeout 2 "http://localhost:5984/_up" 2>/dev/null | grep -q '"status":"ok"'; then
        break
    fi
    sleep 2
    ((WAITED+=2))
done

if [[ $WAITED -ge $MAX_WAIT ]]; then
    print_error "CouchDB 启动超时 (${MAX_WAIT}s)，请检查: systemctl status couchdb"
    exit 1
fi
print_success "CouchDB 已就绪"

# ----- 7. 配置单节点 -----
STEP=$((STEP + 1))
print_step "$STEP" "配置 CouchDB 单节点"

SINGLE_NODE_DONE=false

# 先检查是否已经配置过了（admin party 已关闭）
if curl -s "http://localhost:5984/_up" 2>/dev/null | grep -q '"status":"ok"'; then
    # 尝试不带认证访问 _cluster_setup，如果 401 说明已配置
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:5984/_cluster_setup" 2>/dev/null || true)
    if [[ "$HTTP_CODE" == "401" ]] || [[ "$HTTP_CODE" == "403" ]]; then
        # 用我们的凭证试试能否通过认证
        if api "GET" "/_up" | grep -q '"status":"ok"'; then
            echo -e "  ${YELLOW}单节点已配置，跳过此步${NC}"
            SINGLE_NODE_DONE=true
        else
            print_error "CouchDB 已配置但凭证不匹配，请检查现有配置"
            exit 1
        fi
    fi
fi

if ! $SINGLE_NODE_DONE; then
    RESP=$(api_noauth "POST" "/_cluster_setup" \
        "{\"action\":\"enable_single_node\",\"username\":\"${COUCHDB_USER}\",\"password\":\"${COUCHDB_PASSWORD}\",\"singlenode\":true}")

    if echo "$RESP" | grep -q '"ok"'; then
        print_success "单节点配置完成"
    else
        print_error "单节点配置失败: $RESP"
        exit 1
    fi
fi

# ----- 8. 设置监听地址 -----
STEP=$((STEP + 1))
print_step "$STEP" "设置监听地址为 0.0.0.0（允许外部设备连接）"
set_config "chttpd" "bind_address" "0.0.0.0"

# 重启 CouchDB 使监听地址生效
echo "  重启 CouchDB 使设置生效..."
systemctl restart couchdb 2>/dev/null || service couchdb restart 2>/dev/null || true

# 等待重启完成
WAITED=0
while [[ $WAITED -lt 30 ]]; do
    if api "GET" "/_up" 2>/dev/null | grep -q '"status":"ok"'; then
        break
    fi
    sleep 2
    ((WAITED+=2))
done

if [[ $WAITED -ge 30 ]]; then
    print_error "CouchDB 重启后超时，请检查: systemctl status couchdb"
    exit 1
fi
print_success "CouchDB 已重启并就绪"

# ----- 9. 创建数据库 -----
STEP=$((STEP + 1))
print_step "$STEP" "创建数据库: ${COUCHDB_DB}"

RESP=$(api "PUT" "/${COUCHDB_DB}")
if echo "$RESP" | grep -qE '"ok"|"file_exists"'; then
    if echo "$RESP" | grep -q "file_exists"; then
        echo -e "  ${YELLOW}数据库 ${COUCHDB_DB} 已存在，跳过创建${NC}"
    else
        print_success "数据库 ${COUCHDB_DB} 创建成功"
    fi
else
    print_error "数据库创建失败: $RESP"
    exit 1
fi

# ----- 10. 写入 9 项配置 -----
STEP=$((STEP + 1))
print_step "$STEP" "写入 CouchDB 配置（共 9 项）"

CONFIG_OK=true

echo ""
echo "  认证与安全:"
set_config "chttpd" "require_valid_user" "true" || CONFIG_OK=false
set_config "chttpd_auth" "require_valid_user" "true" || CONFIG_OK=false

echo ""
echo "  CORS 跨域:"
set_config "httpd" "enable_cors" "true" || CONFIG_OK=false
set_config "chttpd" "enable_cors" "true" || CONFIG_OK=false
set_config "cors" "credentials" "true" || CONFIG_OK=false

echo ""
echo "  资源限制:"
set_config "chttpd" "max_http_request_size" "4294967296" || CONFIG_OK=false
set_config "couchdb" "max_document_size" "50000000" || CONFIG_OK=false

echo ""
echo "  特殊配置:"
# WWW-Authenticate 包含双引号，需要特殊处理
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "http://localhost:5984/_node/_local/_config/httpd/WWW-Authenticate" \
    -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d '"Basic realm=\"couchdb\""')
if [[ "$HTTP_CODE" == "200" ]]; then
    print_success "httpd/WWW-Authenticate = Basic realm=\"couchdb\""
else
    print_error "httpd/WWW-Authenticate 写入失败 (HTTP ${HTTP_CODE})"
    CONFIG_OK=false
fi

# cors/origins 包含特殊字符，需要特殊处理
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "http://localhost:5984/_node/_local/_config/cors/origins" \
    -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d '"app://obsidian.md, capacitor://localhost, http://localhost"')
if [[ "$HTTP_CODE" == "200" ]]; then
    print_success "cors/origins = app://obsidian.md, capacitor://localhost, http://localhost"
else
    print_error "cors/origins 写入失败 (HTTP ${HTTP_CODE})"
    CONFIG_OK=false
fi

echo ""
if $CONFIG_OK; then
    print_success "所有配置写入完成"
else
    print_warning "部分配置写入失败，请查看上方错误"
fi

# ----- 11. 验证 -----
STEP=$((STEP + 1))
print_step "$STEP" "验证配置"

VERIFY_OK=true

echo ""
echo "  检查服务状态..."
if api "GET" "/_up" | grep -q '"status":"ok"'; then
    print_success "服务运行正常"
else
    print_error "服务异常"
    VERIFY_OK=false
fi

echo ""
echo "  检查数据库..."
if api "GET" "/_all_dbs" | grep -q "\"${COUCHDB_DB}\""; then
    print_success "数据库 ${COUCHDB_DB} 存在"
else
    print_error "数据库 ${COUCHDB_DB} 未找到"
    VERIFY_OK=false
fi

echo ""
echo "  检查关键配置项..."
check_config() {
    local section=$1 key=$2 expected=$3
    local actual
    actual=$(curl -s \
        "http://localhost:5984/_node/_local/_config/${section}/${key}" \
        -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" 2>/dev/null)
    if echo "$actual" | grep -q "$expected"; then
        print_success "${section}/${key}"
    else
        print_error "${section}/${key} — 期望包含: ${expected}"
        VERIFY_OK=false
    fi
}

check_config "chttpd" "require_valid_user" "true"
check_config "chttpd_auth" "require_valid_user" "true"
check_config "httpd" "enable_cors" "true"
check_config "chttpd" "enable_cors" "true"
check_config "cors" "credentials" "true"
check_config "chttpd" "bind_address" "0.0.0.0"

echo ""
if $VERIFY_OK; then
    print_success "验证全部通过"
else
    print_warning "部分验证未通过"
fi

# ----- 12. IP 交互确认 -----
STEP=$((STEP + 1))
print_step "$STEP" "确认服务器连接地址"
echo ""

# 收集 IP
IP_ARRAY=()
while IFS=' ' read -ra ips; do
    for ip in "${ips[@]}"; do
        [[ -n "$ip" ]] && IP_ARRAY+=("$ip")
    done
done < <(collect_ips)

# 去重
IP_ARRAY=($(printf '%s\n' "${IP_ARRAY[@]}" | sort -u))

if [[ ${#IP_ARRAY[@]} -eq 0 ]]; then
    echo -e "  ${YELLOW}未能自动检测到 IP 地址${NC}"
    echo ""
    read -r -p "  请输入服务器地址 (IP 或域名): " SERVER_ADDR
elif [[ ${#IP_ARRAY[@]} -eq 1 ]]; then
    # 只有一个 IP，回车确认或输入
    echo -e "  检测到服务器 IP: ${GREEN}${BOLD}${IP_ARRAY[0]}${NC}"
    echo ""
    read -r -p "  按回车确认，或输入其他地址 (IP/域名): " input
    if [[ -z "$input" ]]; then
        SERVER_ADDR="${IP_ARRAY[0]}"
    else
        SERVER_ADDR="$input"
    fi
else
    # 多个 IP，编号选择
    echo "  检测到以下可用地址:"
    echo -e "  ${CYAN}─────────────────────────────────${NC}"
    i=1
    for ip in "${IP_ARRAY[@]}"; do
        if is_lan_ip "$ip"; then
            echo -e "    ${BOLD}$i)${NC} ${CYAN}${ip}${NC} (内网)"
        else
            echo -e "    ${BOLD}$i)${NC} ${CYAN}${ip}${NC} (公网)"
        fi
        ((i++))
    done
    echo -e "    ${BOLD}$i)${NC} 以上都不是，手动输入"
    echo -e "  ${CYAN}─────────────────────────────────${NC}"

    MAX_OPTION=$i
    while true; do
        read -r -p "  请选择 [1-${MAX_OPTION}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$MAX_OPTION" ]]; then
            break
        fi
        echo -e "  ${RED}请输入 1-${MAX_OPTION} 之间的数字${NC}"
    done

    if [[ "$choice" -eq "$MAX_OPTION" ]]; then
        read -r -p "  请输入服务器真实地址 (IP 或域名): " SERVER_ADDR
    else
        SERVER_ADDR="${IP_ARRAY[$((choice-1))]}"
    fi
fi

if [[ -z "$SERVER_ADDR" ]]; then
    print_error "服务器地址不能为空"
    exit 1
fi

echo ""
print_success "服务器地址: ${SERVER_ADDR}"

# ----- 13. 保存凭证并打印 -----
STEP=$((STEP + 1))
print_step "$STEP" "保存凭证并输出"

# 写入凭证文件
cat > "${CREDENTIALS_FILE}" << EOF
============================================================
  CouchDB + Obsidian LiveSync 连接信息
============================================================

  服务器地址:  http://${SERVER_ADDR}:5984
  用户名:      ${COUCHDB_USER}
  密码:        ${COUCHDB_PASSWORD}
  数据库名:    ${COUCHDB_DB}

  Web 管理后台: http://${SERVER_ADDR}:5984/_utils

============================================================
EOF

echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  CouchDB 安装配置完成！${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}请将以下信息填入 Obsidian LiveSync 插件:${NC}"
echo ""
echo -e "  ${BOLD}服务器地址:${NC}  ${GREEN}http://${SERVER_ADDR}:5984${NC}"
echo -e "  ${BOLD}用户名:${NC}      ${GREEN}${COUCHDB_USER}${NC}"
echo -e "  ${BOLD}密码:${NC}        ${GREEN}${COUCHDB_PASSWORD}${NC}"
echo -e "  ${BOLD}数据库名:${NC}    ${GREEN}${COUCHDB_DB}${NC}"
echo ""
echo -e "  ${BOLD}Web 管理后台:${NC} ${CYAN}http://${SERVER_ADDR}:5984/_utils${NC}"
echo ""
echo -e "${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}${BOLD}  ⚠ 重要提醒${NC}"
echo -e "${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${YELLOW}1. 请立刻复制保存上方密码！一旦丢失需要重装才能找回。${NC}"
echo -e "  ${YELLOW}2. CouchDB 管理员密码不以明文形式保存在服务器文件中，${NC}"
echo -e "  ${YELLOW}    如需修改密码，请访问 Web 管理后台操作。${NC}"
echo -e "  ${YELLOW}3. 凭证已备份到: ${CREDENTIALS_FILE}${NC}"
echo ""

# ----- 14. 防火墙提醒 -----
print_step "14" "防火墙检查提醒"
echo ""
echo -e "  ${YELLOW}如果你使用了防火墙，请确保开放 5984 端口：${NC}"
echo ""
echo "    # ufw 防火墙"
echo "    sudo ufw allow 5984/tcp"
echo ""
echo "    # firewalld 防火墙"
echo "    sudo firewall-cmd --permanent --add-port=5984/tcp"
echo "    sudo firewall-cmd --reload"
echo ""
echo "    # 云服务器安全组"
echo "    请在云服务商控制台添加入站规则: TCP 5984"
echo ""
echo -e "  ${YELLOW}建议：如果是公网服务器，请配合 Nginx 反向代理 + HTTPS 使用。${NC}"
echo -e "  ${YELLOW}不建议将 CouchDB 5984 端口直接暴露在公网上。${NC}"
echo ""

echo -e "${GREEN}${BOLD}安装完成！享受 Obsidian 多设备实时同步吧~${NC}"
echo ""
