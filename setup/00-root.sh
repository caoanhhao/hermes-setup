#!/usr/bin/env bash
# Pha 0: phần cần root. Chạy MỘT lần từ tài khoản của bạn:
#   sudo bash setup/00-root.sh
# Chạy lại nhiều lần cũng an toàn (idempotent).
set -euo pipefail

AGENT=hermes
SHARE=/srv/agent-share
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

[[ $EUID -eq 0 ]] || { echo "Cần chạy bằng sudo: sudo bash $0" >&2; exit 1; }
INVOKER=${SUDO_USER:?Chạy qua sudo từ tài khoản của bạn, không chạy trực tiếp bằng root}

step() { printf '\n==> %s\n' "$*"; }

step "User $AGENT (không sudo, khoá mật khẩu)"
id "$AGENT" &>/dev/null || useradd -m -s /bin/bash "$AGENT"
passwd -l "$AGENT" >/dev/null
for g in wheel docker input video wineuser; do
  if id -nG "$AGENT" | tr ' ' '\n' | grep -qx "$g"; then
    gpasswd -d "$AGENT" "$g" >/dev/null
    echo "đã gỡ $AGENT khỏi nhóm $g"
  fi
done
chmod 700 "/home/$AGENT"
loginctl enable-linger "$AGENT"
AGENT_UID=$(id -u "$AGENT")

step "Thư mục trao đổi $SHARE (nhóm agentshare)"
getent group agentshare >/dev/null || groupadd agentshare
usermod -aG agentshare "$AGENT"
usermod -aG agentshare "$INVOKER"
install -d -o "$AGENT" -g agentshare -m 2770 "$SHARE"
# User hermes không đọc được /home/$INVOKER (0700), nên copy file setup sang share
rm -rf "$SHARE/my-agent"
install -d -o "$AGENT" -g agentshare -m 2770 "$SHARE/my-agent"
cp -r "$REPO_DIR/setup" "$REPO_DIR/config" "$REPO_DIR/patches" "$SHARE/my-agent/"
chown -R "$AGENT:agentshare" "$SHARE/my-agent"
chmod -R u+rwX,g+rwX,o-rwx "$SHARE/my-agent"

step "Giới hạn tài nguyên cho user-$AGENT_UID.slice"
install -d "/etc/systemd/system/user-$AGENT_UID.slice.d"
cat > "/etc/systemd/system/user-$AGENT_UID.slice.d/50-agent-limits.conf" <<EOF
[Slice]
MemoryMax=16G
CPUQuota=1600%
TasksMax=4096
EOF

step "Kiểm tra"
echo "groups $AGENT: $(id -nG "$AGENT")"
echo "linger: $(loginctl show-user "$AGENT" -p Linger --value)"
sleep 1
ss -ltn | awk 'NR==1 || /:11434 /'
if [[ $(stat -c %a /home/wineuser 2>/dev/null) == 777 ]]; then
  echo "CẢNH BÁO: /home/wineuser đang là 777, nên $AGENT ghi được vào đó. Cân nhắc: sudo chmod 750 /home/wineuser"
fi

cat <<EOF

Xong pha 0. Bước tiếp theo (chạy dưới user $AGENT):
  sudo machinectl shell $AGENT@ /bin/bash $SHARE/my-agent/setup/10-hermes-user.sh
$INVOKER vừa được thêm vào nhóm agentshare, cần đăng nhập lại thì quyền nhóm mới có hiệu lực.
EOF
