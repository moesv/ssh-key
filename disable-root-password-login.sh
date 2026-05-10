#!/usr/bin/env bash
set -euo pipefail

AUTH_KEYS="/root/.ssh/authorized_keys"
PUBKEY_REGEX='^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-[a-z0-9-]+|sk-(ssh-ed25519|ecdsa-sha2-[a-z0-9-]+)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+'

# 必须有 tty 才能进入交互流程；推荐使用：
#   bash disable-root-password-login.sh
# 而不是：curl ... | bash
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

# 2. 备份配置文件（放在检查之后，避免无意义的备份堆积）
echo "🔄 备份并修改 SSH 配置以关闭密码登录..."
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak_pwd_$(date +%s)"

# 3. 获取主配置和所有引用文件
FILES=$(find /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ -type f 2>/dev/null)

# 4. 遍历修改密码验证和键盘交互验证为 no
for f in $FILES; do
    sed -i -E "s/^#?[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/i" "$f"
    sed -i -E "s/^#?[[:space:]]*KbdInteractiveAuthentication[[:space:]]+.*/KbdInteractiveAuthentication no/i" "$f"
    sed -i -E "s/^#?[[:space:]]*ChallengeResponseAuthentication[[:space:]]+.*/ChallengeResponseAuthentication no/i" "$f"
done

# 5. 检查是否成功修改，如果没有就强行插在最顶部
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
    echo "✅ SSH 密码登录通道已彻底关闭！当前门禁状态如下："
    sshd -T | grep -iE "^(passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication)"
else
    echo "❌ 警告：配置出现语法错误，已中止重启，请检查。"
    exit 1
fi

# 7. 终极绝杀：锁定 root 账户底层密码
echo -e "\n🔄 正在锁定 root 账户系统密码..."
passwd -l root
echo "✅ root 密码已彻底锁定！当前底层状态如下 (看到 L 代表成功)："
passwd -S root
