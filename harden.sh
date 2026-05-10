#!/usr/bin/env bash
set -euo pipefail

AUTH_KEYS="/root/.ssh/authorized_keys"
PUBKEY_REGEX='^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-[a-z0-9-]+|sk-(ssh-ed25519|ecdsa-sha2-[a-z0-9-]+)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+'

ensure_tty() {
    if [ ! -t 0 ]; then
        echo "❌ 当前没有可交互的终端 (stdin 不是 tty)。"
        echo "请先把脚本下载到本地再运行："
        echo "  curl -fsSL <url> -o harden.sh && bash harden.sh"
        exit 1
    fi
}

has_valid_key() {
    [ -f "$AUTH_KEYS" ] && [ -s "$AUTH_KEYS" ] && grep -qE "$PUBKEY_REGEX" "$AUTH_KEYS"
}

key_count() {
    if [ -f "$AUTH_KEYS" ]; then
        grep -cE "$PUBKEY_REGEX" "$AUTH_KEYS" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

add_pubkey_interactively() {
    ensure_tty
    echo ""
    echo "请粘贴你的 SSH 公钥整行内容（形如 ssh-ed25519 AAAA... user@host），然后回车："
    local pubkey=""
    IFS= read -r pubkey || true
    pubkey="$(printf '%s' "$pubkey" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    if [ -z "$pubkey" ]; then
        echo "⚠️  没有读取到任何内容，跳过本次添加。"
        return 1
    fi
    if ! printf '%s\n' "$pubkey" | grep -qE "$PUBKEY_REGEX"; then
        echo "❌ 公钥格式不正确（需以 ssh-rsa / ssh-ed25519 / ecdsa-sha2-* 等开头），跳过。"
        return 1
    fi

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    if [ -f "$AUTH_KEYS" ] && grep -qxF "$pubkey" "$AUTH_KEYS"; then
        echo "ℹ️  该公钥已存在，跳过写入。"
    else
        # 确保以换行符结尾，避免和上一行拼到一起
        if [ -f "$AUTH_KEYS" ] && [ -s "$AUTH_KEYS" ] && [ "$(tail -c1 "$AUTH_KEYS" | wc -l)" -eq 0 ]; then
            printf '\n' >> "$AUTH_KEYS"
        fi
        printf '%s\n' "$pubkey" >> "$AUTH_KEYS"
        echo "✅ 公钥已写入 $AUTH_KEYS"
    fi
    chmod 600 "$AUTH_KEYS"
    chown -R root:root /root/.ssh
    return 0
}

add_pubkeys_loop() {
    # 循环添加，至少要确保最后存在一条合法公钥才算"成功"。
    while true; do
        add_pubkey_interactively || true
        echo ""
        read -r -p "继续添加另一个公钥？输入 y 继续，其他任意键结束: " again
        case "$again" in
            y|Y) ;;
            *) break ;;
        esac
    done
}

current_ssh_port() {
    local p
    p="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
    [ -z "$p" ] && p=22
    echo "$p"
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

# 1. 检查 root 是否已配置 SSH 公钥；支持添加 1 条或多条
ensure_tty
if ! has_valid_key; then
    echo "⚠️  未检测到有效的 root SSH 公钥（$AUTH_KEYS 不存在 / 为空 / 无合法公钥）。"
    echo ""
    echo "关闭密码登录前必须先确保密钥登录可用，否则会被锁在服务器外。"
    echo ""
    echo "请选择："
    echo "  1) 现在粘贴公钥添加 (可连续添加多条，推荐)"
    echo "  2) 退出，我自己去添加后再运行"
    read -r -p "请输入 [1/2] (默认 2): " choice
    case "${choice:-2}" in
        1) add_pubkeys_loop ;;
        *) echo "已退出。请添加公钥后再运行本脚本。"; exit 0 ;;
    esac

    if ! has_valid_key; then
        echo "❌ 添加后仍未检测到有效公钥，已中止。"
        exit 1
    fi
else
    echo "✅ 已检测到 $(key_count) 条 root SSH 公钥。"
    echo ""
    echo "是否需要再添加更多公钥？"
    echo "  1) 继续添加 (可连续添加多条)"
    echo "  2) 不添加，进入后续步骤 (推荐)"
    read -r -p "请输入 [1/2] (默认 2): " more_choice
    case "${more_choice:-2}" in
        1) add_pubkeys_loop ;;
        *) ;;
    esac
fi

echo ""
echo "📋 当前 $AUTH_KEYS 里共有 $(key_count) 条合法公钥。"

# 2. SSH 端口设置（直接随机，y/n 确认）
ensure_tty
CUR_PORT="$(current_ssh_port)"
SUGGEST="$(random_high_port || true)"

NEW_PORT=""
echo ""
echo "🔧 SSH 端口设置"
echo "    当前端口: ${CUR_PORT}"
if [ -n "${SUGGEST}" ]; then
    echo "    随机端口: ${SUGGEST}  (50000-65530 内未占用)"
    read -r -p "是否切换到随机端口 ${SUGGEST}? [Y/n] (回车=切换): " port_choice
    case "${port_choice:-Y}" in
        n|N) echo "保持当前端口 ${CUR_PORT}" ;;
        *)   NEW_PORT="$SUGGEST" ;;
    esac
else
    echo "⚠️  无法生成可用的随机端口，保持当前端口 ${CUR_PORT}"
fi

# 3. 最终确认（所有选项都收齐后，最后一道闸）
TARGET_PORT="${NEW_PORT:-$CUR_PORT}"
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  最终确认 — 即将应用："
echo "    SSH 端口        : ${TARGET_PORT}${NEW_PORT:+   (将从 ${CUR_PORT} 切换)}"
echo "    授权公钥数量    : $(key_count)"
echo "    密码 / 键盘交互登录 : 关闭"
echo "    root 系统密码   : 锁定"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "⚠️  请先做以下检查再继续，否则可能被锁在服务器外："
echo "    1. 在新开终端用 ssh -p ${CUR_PORT} root@<server-ip> 测试 **每一把** 公钥能成功登录"
if [ -n "$NEW_PORT" ]; then
    echo "    2. 系统防火墙 (ufw/firewalld/iptables) 已放行 ${NEW_PORT}/tcp"
    echo "    3. 云厂商安全组已放行 ${NEW_PORT}/tcp"
fi
read -r -p "全部确认无误？输入 yes 继续，其他任意键退出: " confirm
if [ "$confirm" != "yes" ]; then
    echo "已退出。请测试通过后再运行。"
    exit 0
fi

# 4. 锁定 root 账户底层密码
echo ""
echo "🔄 正在锁定 root 账户系统密码..."
passwd -l root
echo "✅ root 密码已彻底锁定！当前底层状态如下 (看到 L 代表成功)："
passwd -S root

# 5. 备份配置 + 改 sshd_config + 重启
echo ""
echo "🔄 备份并修改 SSH 配置..."
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak_pwd_$(date +%s)"

if [ -n "$NEW_PORT" ]; then
    apply_ssh_port "$NEW_PORT"
fi

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

if sshd -t; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    echo "✅ SSH 配置已更新！当前门禁状态如下："
    sshd -T | grep -iE "^(port|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication)"
else
    echo "❌ 警告：配置出现语法错误，已中止重启，请检查。"
    exit 1
fi

# 6. 收尾：打印新配置摘要
FINAL_PORT="$(current_ssh_port)"
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "${SERVER_IP:-}" ] && SERVER_IP="<server-ip>"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  🎉 SSH 加固完成"
echo "════════════════════════════════════════════════════════════"
echo "  SSH 端口        : ${FINAL_PORT}${NEW_PORT:+   (已从 ${CUR_PORT} 切换)}"
echo "  授权公钥数量    : $(key_count)"
echo "  密码登录        : 已关闭"
echo "  键盘交互登录    : 已关闭"
echo "  root 系统密码   : 已锁定"
echo ""
echo "  下次登录命令    :"
echo "      ssh -p ${FINAL_PORT} root@${SERVER_IP}"
if [ -n "$NEW_PORT" ]; then
    echo ""
    echo "  ⚠️  端口已变更，请在 **不关闭当前会话** 的前提下，新开一个终端测试登录。"
    echo "     脚本未修改防火墙，请确保 ${FINAL_PORT}/tcp 在系统防火墙和云厂商安全组里都已放行。"
fi
echo "════════════════════════════════════════════════════════════"
