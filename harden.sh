#!/usr/bin/env bash
set -euo pipefail

AUTH_KEYS="/root/.ssh/authorized_keys"
PUBKEY_REGEX='^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-[a-z0-9-]+|sk-(ssh-ed25519|ecdsa-sha2-[a-z0-9-]+)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+'

ensure_tty() {
    if [ ! -t 0 ]; then
        echo "❌ 当前没有可交互的终端 (stdin 不是 tty)。"
        echo "请先把脚本下载到本地再运行："
        echo "  curl -fsSL <url> -o disable-root-password-login.sh && bash disable-root-password-login.sh"
        exit 1
    fi
}

has_valid_key() {
    [ -f "$AUTH_KEYS" ] && [ -s "$AUTH_KEYS" ] && grep -qE "$PUBKEY_REGEX" "$AUTH_KEYS"
}

add_pubkey_interactively() {
    ensure_tty
    echo ""
    echo "请粘贴你的 SSH 公钥整行内容（形如 ssh-ed25519 AAAA... user@host），然后回车："
    local pubkey=""
    IFS= read -r pubkey || true
    pubkey="$(printf '%s' "$pubkey" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    if [ -z "$pubkey" ]; then
        echo "❌ 没有读取到任何内容，已中止。"
        exit 1
    fi
    if ! printf '%s\n' "$pubkey" | grep -qE "$PUBKEY_REGEX"; then
        echo "❌ 公钥格式不正确（需以 ssh-rsa / ssh-ed25519 / ecdsa-sha2-* 等开头）。"
        exit 1
    fi

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    if [ -f "$AUTH_KEYS" ] && grep -qxF "$pubkey" "$AUTH_KEYS"; then
        echo "ℹ️  该公钥已存在，跳过写入。"
    else
        printf '%s\n' "$pubkey" >> "$AUTH_KEYS"
        echo "✅ 公钥已写入 $AUTH_KEYS"
    fi
    chmod 600 "$AUTH_KEYS"
    chown -R root:root /root/.ssh
}

current_ssh_port() {
    local p
    p="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
    [ -z "$p" ] && p=22
    echo "$p"
}

valid_port() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

port_in_use() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH "( sport = :$p )" 2>/dev/null | grep -q . && return 0 || return 1
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${p}\$"
    else
        return 1
    fi
}

random_high_port() {
    local p
    for _ in $(seq 1 50); do
        p=$(( RANDOM % 15531 + 50000 ))
        [ "$p" = "${CUR_PORT:-}" ] && continue
        if ! port_in_use "$p"; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

apply_ssh_port() {
    local new_port="$1"
    local files
    files=$(find /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ -type f 2>/dev/null)
    for f in $files; do
        sed -i -E "s/^#?[[:space:]]*Port[[:space:]]+.*/Port ${new_port}/i" "$f"
    done
    if ! grep -qhiE "^Port[[:space:]]+${new_port}\$" $files; then
        sed -i "1i Port ${new_port}" /etc/ssh/sshd_config
    fi

    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
        if command -v semanage >/dev/null 2>&1; then
            semanage port -a -t ssh_port_t -p tcp "$new_port" 2>/dev/null \
                || semanage port -m -t ssh_port_t -p tcp "$new_port" 2>/dev/null \
                || echo "⚠️  SELinux 端口标记可能未生效，请稍后手动检查 (semanage port -l | grep ssh)。"
        else
            echo "⚠️  检测到 SELinux 启用但未安装 policycoreutils-python-utils，sshd 可能无法绑定 ${new_port}。"
            echo "    安装后再执行：semanage port -a -t ssh_port_t -p tcp ${new_port}"
        fi
    fi
}

# 1. 检查 root 是否已配置 SSH 公钥；没有就引导添加
if ! has_valid_key; then
    echo "⚠️  未检测到有效的 root SSH 公钥（$AUTH_KEYS 不存在 / 为空 / 无合法公钥）。"
    echo ""
    echo "关闭密码登录前必须先确保密钥登录可用，否则会被锁在服务器外。"
    echo ""
    echo "请选择："
    echo "  1) 现在粘贴公钥添加 (推荐)"
    echo "  2) 退出，我自己去添加后再运行"
    ensure_tty
    read -r -p "请输入 [1/2] (默认 2): " choice
    case "${choice:-2}" in
        1) add_pubkey_interactively ;;
        *) echo "已退出。请添加公钥后再运行本脚本。"; exit 0 ;;
    esac

    if ! has_valid_key; then
        echo "❌ 添加后仍未检测到有效公钥，已中止。"
        exit 1
    fi

    echo ""
    echo "⚠️  请新开一个终端用密钥登录测试，确认成功后再继续。"
    echo "    一旦关闭密码登录，未通过密钥测试会导致无法登录！"
    read -r -p "确认密钥登录已测试通过？输入 yes 继续，其他任意键退出: " confirm
    if [ "$confirm" != "yes" ]; then
        echo "已退出。等你确认密钥可用后再运行。"
        exit 0
    fi
fi

echo "✅ 已检测到 root SSH 公钥，继续执行。"

# 2. SSH 端口设置（交互）
ensure_tty
CUR_PORT="$(current_ssh_port)"
SUGGEST="$(random_high_port || true)"

echo ""
echo "🔧 SSH 端口设置"
echo "    当前端口: ${CUR_PORT}"
if [ -n "${SUGGEST}" ]; then
    echo "    建议随机端口: ${SUGGEST}  (50000-65530 未占用)"
fi
echo ""
echo "    回车  = 使用建议的随机端口${SUGGEST:+ ${SUGGEST}}"
echo "    数字  = 使用你输入的自定义端口 (1-65535)"
echo "    n/N  = 保持当前端口 ${CUR_PORT}"
read -r -p "请输入选项: " port_choice

NEW_PORT=""
case "${port_choice}" in
    "")
        if [ -n "${SUGGEST}" ]; then
            NEW_PORT="$SUGGEST"
        else
            echo "⚠️  没有可用的随机端口，保持当前端口 ${CUR_PORT}"
        fi
        ;;
    n|N)
        echo "保持当前端口 ${CUR_PORT}"
        ;;
    *)
        if ! valid_port "$port_choice"; then
            echo "❌ 无效的端口号: $port_choice"
            exit 1
        fi
        if [ "$port_choice" = "$CUR_PORT" ]; then
            echo "输入端口与当前端口一致，保持不变。"
        else
            if port_in_use "$port_choice"; then
                echo "❌ 端口 $port_choice 已被占用，已中止。"
                exit 1
            fi
            NEW_PORT="$port_choice"
        fi
        ;;
esac

# 3. 备份配置文件
echo ""
echo "🔄 备份并修改 SSH 配置..."
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak_pwd_$(date +%s)"

# 4. 应用端口（如果需要）—— 只改 sshd，不动防火墙
if [ -n "$NEW_PORT" ]; then
    apply_ssh_port "$NEW_PORT"
    echo "ℹ️  注意：本脚本不修改防火墙 / 安全组。"
    echo "    请自行确保 ${NEW_PORT}/tcp 在系统防火墙 (ufw/firewalld/iptables) 和云厂商安全组里均已放行。"
fi

# 5. 关闭密码 / 键盘交互登录
FILES=$(find /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ -type f 2>/dev/null)
for f in $FILES; do
    sed -i -E "s/^#?[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/i" "$f"
    sed -i -E "s/^#?[[:space:]]*KbdInteractiveAuthentication[[:space:]]+.*/KbdInteractiveAuthentication no/i" "$f"
    sed -i -E "s/^#?[[:space:]]*ChallengeResponseAuthentication[[:space:]]+.*/ChallengeResponseAuthentication no/i" "$f"
done

if ! grep -qhi "^PasswordAuthentication no" $FILES; then
    sed -i "1i PasswordAuthentication no" /etc/ssh/sshd_config
fi
if ! grep -qhi "^KbdInteractiveAuthentication no" $FILES; then
    sed -i "1i KbdInteractiveAuthentication no" /etc/ssh/sshd_config
fi
if ! grep -qhi "^ChallengeResponseAuthentication no" $FILES; then
    sed -i "1i ChallengeResponseAuthentication no" /etc/ssh/sshd_config
fi

# 6. 测试语法并重启服务
if sshd -t; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    echo "✅ SSH 配置已更新！当前门禁状态如下："
    sshd -T | grep -iE "^(port|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication)"
    if [ -n "$NEW_PORT" ]; then
        echo ""
        echo "⚠️  端口已切换到 ${NEW_PORT}。脚本未改防火墙——请先确认放行规则到位，再保留当前会话、新开终端测试："
        echo "      ssh -p ${NEW_PORT} root@<server-ip>"
        echo "    在确认能用新端口登录之前，不要关闭当前会话！"
    fi
else
    echo "❌ 警告：配置出现语法错误，已中止重启，请检查。"
    exit 1
fi

# 7. 锁定 root 账户底层密码
echo -e "\n🔄 正在锁定 root 账户系统密码..."
passwd -l root
echo "✅ root 密码已彻底锁定！当前底层状态如下 (看到 L 代表成功)："
passwd -S root
