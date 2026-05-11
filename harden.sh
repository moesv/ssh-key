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

install_fail2ban() {
    if command -v fail2ban-server >/dev/null 2>&1; then
        echo "ℹ️  fail2ban 已安装，跳过安装步骤。"
        return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
        echo "🔄 通过 apt 安装 fail2ban..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban || return 1
    elif command -v dnf >/dev/null 2>&1; then
        echo "🔄 通过 dnf 安装 fail2ban..."
        dnf install -y epel-release >/dev/null 2>&1 || true
        dnf install -y fail2ban || return 1
    elif command -v yum >/dev/null 2>&1; then
        echo "🔄 通过 yum 安装 fail2ban..."
        yum install -y epel-release >/dev/null 2>&1 || true
        yum install -y fail2ban || return 1
    elif command -v pacman >/dev/null 2>&1; then
        echo "🔄 通过 pacman 安装 fail2ban..."
        pacman -Sy --noconfirm fail2ban || return 1
    elif command -v apk >/dev/null 2>&1; then
        echo "🔄 通过 apk 安装 fail2ban..."
        apk add --no-cache fail2ban || return 1
    else
        echo "❌ 未识别的包管理器，请手动安装 fail2ban。"
        return 1
    fi
    command -v fail2ban-server >/dev/null 2>&1
}

configure_fail2ban() {
    local port="$1"
    mkdir -p /etc/fail2ban
    cat > /etc/fail2ban/jail.local <<EOF
# Generated by harden.sh
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = ${port}
EOF
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban 2>/dev/null || systemctl start fail2ban 2>/dev/null || return 1
}

# 写入登录横幅脚本，用户每次 ssh 上来时显示加固状态
MOTD_FILE="/etc/profile.d/00-server-init.sh"
install_motd() {
    local port="$1"
    local auth="$2"
    local f2b="$3"
    mkdir -p /etc/profile.d
    cat > "$MOTD_FILE" <<EOF
#!/bin/sh
# Generated by harden.sh — SSH hardening status banner shown on login.
# Remove this file if you don't want it: rm $MOTD_FILE

case \$- in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
[ -t 1 ] || { return 0 2>/dev/null; exit 0; }

_C1='\033[1;34m'
_C2='\033[1;32m'
_C3='\033[1;33m'
_R='\033[0m'

printf '%b\n' "\${_C1}══════════════════════════════════════════════════════════\${_R}"
printf '              %bServer Hardened by harden.sh%b\n' "\${_C1}" "\${_R}"
printf '%b\n' "\${_C1}══════════════════════════════════════════════════════════\${_R}"
printf '  Login User:  %b%s%b\n' "\${_C2}" "\$(id -un)" "\${_R}"
printf '  SSH Port:    %b%s%b\n' "\${_C2}" '${port}' "\${_R}"
printf '  Auth Type:   %b%s%b\n' "\${_C2}" '${auth}' "\${_R}"
printf '  fail2ban:    %b%s%b\n' "\${_C2}" '${f2b}' "\${_R}"
printf '  Firewall:    %bMake sure TCP/%s is allowed%b\n' "\${_C3}" '${port}' "\${_R}"
printf '%b\n' "\${_C1}══════════════════════════════════════════════════════════\${_R}"

unset _C1 _C2 _C3 _R
EOF
    chmod 644 "$MOTD_FILE"
}

# 检查 VPS 是否已经全面加固：四项全中则脚本可以直接退出
already_hardened() {
    has_valid_key || return 1

    local port sshd_cfg
    port="$(current_ssh_port)"
    [ "$port" != "22" ] || return 1

    sshd_cfg="$(sshd -T 2>/dev/null)" || return 1
    echo "$sshd_cfg" | grep -qiE "^passwordauthentication no" || return 1
    echo "$sshd_cfg" | grep -qiE "^kbdinteractiveauthentication no" || return 1

    command -v fail2ban-client >/dev/null 2>&1 || return 1
    systemctl is-active --quiet fail2ban 2>/dev/null || return 1
    fail2ban-client status sshd >/dev/null 2>&1 || return 1

    return 0
}

# 0. 幂等性检查：四项全满足则进入"维护模式"——只允许追加公钥，其他都跳过
if already_hardened; then
    CUR_PORT="$(current_ssh_port)"
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -z "${SERVER_IP:-}" ] && SERVER_IP="<server-ip>"

    # 没装登录横幅就静默补上一份（不覆盖已有的）
    if [ ! -f "$MOTD_FILE" ]; then
        install_motd "$CUR_PORT" "Key Only (Secure)" "Active"
    fi

    echo "════════════════════════════════════════════════════════════"
    echo "  ✅ 检测到本机已加固"
    echo "════════════════════════════════════════════════════════════"
    echo "  SSH 端口        : ${CUR_PORT} (非默认)"
    echo "  授权公钥数量    : $(key_count)"
    echo "  密码 / 键盘交互登录 : 已关闭"
    echo "  fail2ban        : 已启用 (sshd jail 在用)"
    echo "  登录横幅        : $([ -f "$MOTD_FILE" ] && echo "已安装" || echo "未安装")"
    echo ""
    echo "  登录命令        :"
    echo "      ssh -p ${CUR_PORT} root@${SERVER_IP}"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    ensure_tty
    read -r -p "是否需要追加公钥？[y/N] (回车=退出): " add_choice
    case "${add_choice}" in
        y|Y)
            add_pubkeys_loop
            echo ""
            echo "✅ 完成。当前 $AUTH_KEYS 共 $(key_count) 条合法公钥。"
            echo "   其它加固项已就绪，未做任何修改。"
            ;;
        *) ;;
    esac
    exit 0
fi

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

# 2. SSH 端口设置：只在当前还是默认 22 时建议改成高位端口；
#    已经是非默认端口的环境保持原状。
ensure_tty
CUR_PORT="$(current_ssh_port)"
NEW_PORT=""

if [ "$CUR_PORT" != "22" ]; then
    echo ""
    echo "🔧 当前 SSH 端口已是 ${CUR_PORT}（非默认），保持不变。"
else
    SUGGEST="$(random_high_port || true)"
    echo ""
    echo "🔧 SSH 端口设置"
    echo "    当前端口: 22 (默认，容易被扫)"
    if [ -n "${SUGGEST}" ]; then
        echo "    随机端口: ${SUGGEST}  (50000-65530 内未占用)"
        read -r -p "是否切换到随机端口 ${SUGGEST}? [Y/n] (回车=切换): " port_choice
        case "${port_choice:-Y}" in
            n|N) echo "保持当前端口 22" ;;
            *)   NEW_PORT="$SUGGEST" ;;
        esac
    else
        echo "⚠️  无法生成可用的随机端口，保持当前端口 22"
    fi
fi

# 3. fail2ban 选项
INSTALL_F2B=0
echo ""
echo "🛡️  fail2ban 可在多次失败登录后自动封禁 IP，进一步降低被暴破/扫描的噪音。"
read -r -p "是否安装并启用 fail2ban? [Y/n] (回车=安装): " f2b_choice
case "${f2b_choice:-Y}" in
    n|N) echo "跳过 fail2ban。" ;;
    *)   INSTALL_F2B=1 ;;
esac

# 4. 登录横幅 (MOTD) 选项
INSTALL_MOTD=0
echo ""
echo "🖼️  登录横幅可在每次 ssh 上来时显示端口/用户/认证方式，方便记忆。"
read -r -p "是否安装登录横幅? [Y/n] (回车=安装): " motd_choice
case "${motd_choice:-Y}" in
    n|N) echo "跳过登录横幅。" ;;
    *)   INSTALL_MOTD=1 ;;
esac

# 5. 最终确认（所有选项都收齐后，最后一道闸）
TARGET_PORT="${NEW_PORT:-$CUR_PORT}"
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  最终确认 — 即将应用："
echo "    SSH 端口        : ${TARGET_PORT}${NEW_PORT:+   (将从 ${CUR_PORT} 切换)}"
echo "    授权公钥数量    : $(key_count)"
echo "    密码 / 键盘交互登录 : 关闭"
echo "    root 系统密码   : 锁定"
if [ "$INSTALL_F2B" = "1" ]; then
    echo "    fail2ban        : 安装并启用 (sshd jail, port=${TARGET_PORT})"
else
    echo "    fail2ban        : 跳过"
fi
if [ "$INSTALL_MOTD" = "1" ]; then
    echo "    登录横幅        : 安装到 ${MOTD_FILE}"
else
    echo "    登录横幅        : 跳过"
fi
echo "════════════════════════════════════════════════════════════"
echo ""
echo "⚠️  请先做以下检查再继续，否则可能被锁在服务器外："
echo "    1. 保留当前这个 SSH 会话，**在你本地电脑上另开一个终端窗口**，跑："
echo "         ssh -p ${CUR_PORT} root@<server-ip>"
echo "       确认 **每一把** 公钥都能成功登录（不要关掉这个老会话）"
if [ -n "$NEW_PORT" ]; then
    echo "    2. 系统防火墙 (ufw/firewalld/iptables) 已放行 ${NEW_PORT}/tcp"
    echo "    3. 云厂商安全组 (阿里云/腾讯云/AWS 等) 已放行 ${NEW_PORT}/tcp"
fi
read -r -p "全部确认无误？[y/N] (回车=退出): " confirm
case "${confirm}" in
    y|Y) ;;
    *) echo "已退出。请测试通过后再运行。"; exit 0 ;;
esac

# 5. 备份配置文件
echo ""
TS="$(date +%s)"
echo "🔄 备份配置..."
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak_pwd_${TS}"
echo "    sshd_config → /etc/ssh/sshd_config.bak_pwd_${TS}"
if [ "$INSTALL_F2B" = "1" ] && [ -f /etc/fail2ban/jail.local ]; then
    cp /etc/fail2ban/jail.local "/etc/fail2ban/jail.local.bak_${TS}"
    echo "    ⚠️  已有的 /etc/fail2ban/jail.local 将被覆盖（已备份为 jail.local.bak_${TS}）"
fi

# 6. 改 sshd_config + sshd -t + 重启 sshd
echo "🔄 修改 sshd_config..."
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
    echo "✅ sshd 已重启。当前门禁状态："
    sshd -T | grep -iE "^(port|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication)"
else
    echo "❌ sshd_config 语法错误，已中止重启。root 密码仍可用，请修复后重试。"
    exit 1
fi

# 7. 验证 sshd 正在目标端口监听 (失败不阻塞，但提醒用户)
FINAL_PORT="$(current_ssh_port)"
echo ""
echo "🔍 验证 sshd 在端口 ${FINAL_PORT} 上监听..."
LISTEN_OK=0
for _ in 1 2 3; do
    if port_in_use "$FINAL_PORT"; then
        LISTEN_OK=1
        break
    fi
    sleep 1
done
if [ "$LISTEN_OK" = "1" ]; then
    echo "✅ sshd 正在端口 ${FINAL_PORT} 上监听。"
else
    echo "⚠️  未检测到端口 ${FINAL_PORT} 上的监听器！请立刻 systemctl status sshd 检查。"
    echo "    在确认 sshd 起来之前，**不要** 关闭当前 SSH 会话；root 密码也还没锁定，可作为应急通道。"
    read -r -p "仍然继续后续步骤（装 fail2ban + 锁 root 密码）？[y/N] (回车=中止): " keep_going
    case "${keep_going}" in
        y|Y) ;;
        *) echo "已中止。root 密码未锁，请优先恢复 sshd。"; exit 1 ;;
    esac
fi

# 8. 安装并配置 fail2ban (如选择)
F2B_STATUS="未安装"
if [ "$INSTALL_F2B" = "1" ]; then
    echo ""
    if install_fail2ban && configure_fail2ban "$FINAL_PORT"; then
        F2B_STATUS="已启用 (sshd jail, port=${FINAL_PORT})"
        echo "✅ fail2ban 已启用。当前 sshd jail 状态："
        fail2ban-client status sshd 2>/dev/null || true
    else
        F2B_STATUS="安装/启动失败 (请手动检查)"
        echo "❌ fail2ban 安装或启动失败，请手动排查。"
    fi
fi

# 9. 安装登录横幅 (如选择)
MOTD_DISP="未安装"
if [ "$INSTALL_MOTD" = "1" ]; then
    F2B_FOR_MOTD="Disabled"
    [ "$INSTALL_F2B" = "1" ] && [ "${F2B_STATUS#已启用}" != "${F2B_STATUS}" ] && F2B_FOR_MOTD="Active"
    install_motd "$FINAL_PORT" "Key Only (Secure)" "$F2B_FOR_MOTD"
    MOTD_DISP="已安装 (${MOTD_FILE})"
    echo ""
    echo "✅ 登录横幅已安装到 ${MOTD_FILE}"
fi

# 10. 锁定 root 账户底层密码（最后一步：只有前面都通过才下死手）
echo ""
echo "🔄 正在锁定 root 账户系统密码..."
passwd -l root
echo "✅ root 密码已锁定（看到 L 代表成功）："
passwd -S root

# 11. 收尾：打印新配置摘要
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
echo "  fail2ban        : ${F2B_STATUS}"
echo "  登录横幅        : ${MOTD_DISP}"
echo ""
echo "  下次登录命令    :"
echo "      ssh -p ${FINAL_PORT} root@${SERVER_IP}"
echo ""
echo "  ⚠️  在你本地电脑另开终端用上面的命令登录验证一次，**确认成功后再关闭当前这个会话**。"
if [ -n "$NEW_PORT" ]; then
    echo "     端口已从 ${CUR_PORT} 切到 ${FINAL_PORT}——请确认系统防火墙和云厂商安全组都放行了 ${FINAL_PORT}/tcp。"
fi
echo "════════════════════════════════════════════════════════════"
