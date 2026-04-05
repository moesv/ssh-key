#!/usr/bin/env bash
set -euo pipefail

echo "🔄 正在备份并修改 SSH 配置关闭密码登录..."

# 1. 备份配置文件
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak_pwd_$(date +%s)

# 2. 先检查 root 是否已配置 SSH 公钥
if [ ! -f /root/.ssh/authorized_keys ] || [ ! -s /root/.ssh/authorized_keys ]; then
    echo "❌ 未检测到 /root/.ssh/authorized_keys，或文件为空。"
    echo "请先确认 root 的 SSH key 登录可用，再运行本脚本。"
    exit 1
fi

echo "✅ 已检测到 root SSH 公钥，继续执行。"

# 3. 获取主配置和所有引用文件
FILES=$(find /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ -type f 2>/dev/null)

# 4. 遍历修改密码验证和键盘交互验证为 no
for f in $FILES; do
    sed -i -E "s/^#?[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/i" "$f"
    sed -i -E "s/^#?[[:space:]]*KbdInteractiveAuthentication[[:space:]]+.*/KbdInteractiveAuthentication no/i" "$f"
    sed -i -E "s/^#?[[:space:]]*ChallengeResponseAuthentication[[:space:]]+.*/ChallengeResponseAuthentication no/i" "$f"
done

# 4. 检查是否成功修改，如果没有就强行插在最顶部
if ! grep -qhi "^PasswordAuthentication no" $FILES; then
    sed -i "1i PasswordAuthentication no" /etc/ssh/sshd_config
fi
if ! grep -qhi "^KbdInteractiveAuthentication no" $FILES; then
    sed -i "1i KbdInteractiveAuthentication no" /etc/ssh/sshd_config
fi
if ! grep -qhi "^ChallengeResponseAuthentication no" $FILES; then
    sed -i "1i ChallengeResponseAuthentication no" /etc/ssh/sshd_config
fi

# 5. 测试语法并重启服务
if sshd -t; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    echo "✅ SSH 密码登录通道已彻底关闭！当前门禁状态如下："
    sshd -T | grep -iE "^(passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication)"
else
    echo "❌ 警告：配置出现语法错误，已中止重启，请检查。"
    exit 1
fi

# 6. 终极绝杀：锁定 root 账户底层密码
echo -e "\n🔄 正在锁定 root 账户系统密码..."
passwd -l root
echo "✅ root 密码已彻底锁定！当前底层状态如下 (看到 L 代表成功)："
passwd -S root
