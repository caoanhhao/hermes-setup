#!/usr/bin/env bash
# Pha 6: Hermes gateway 24/7 (Telegram, cron) + healthcheck, chạy dưới user hermes:
#   sudo machinectl shell hermes@ /bin/bash /srv/agent-share/my-agent/setup/30-gateway.sh
# Cần trước trong ~/.hermes/.env (bạn tự điền, script không hỏi token):
#   TELEGRAM_BOT_TOKEN=<token từ @BotFather>
# Allowlist: chạy `hermes gateway setup` (chọn Telegram). Wizard tự nhận ra Telegram ID của bạn khi bạn
# nhắn bot, rồi ghi TELEGRAM_ALLOWED_USERS + TELEGRAM_HOME_CHANNEL. Khi đã có allowlist, người lạ bị
# bỏ qua im lặng (unauthorized_dm_behavior mặc định = ignore). Chưa có allowlist thì bot gửi mã
# pairing, duyệt bằng `hermes pairing approve telegram <mã>`.
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=$HOME/.hermes/.env

[[ $(id -un) == "${AGENT_USER:-hermes}" ]] || { echo "Phải chạy dưới user ${AGENT_USER:-hermes} (agent chạy bằng user khác thì đặt AGENT_USER=<user>)" >&2; exit 1; }
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}

step() { printf '\n==> %s\n' "$*"; }

step "Kiểm tra Telegram trong .env"
if ! grep -qE '^TELEGRAM_BOT_TOKEN=.+' "$ENV_FILE"; then
  echo "THIẾU TELEGRAM_BOT_TOKEN trong $ENV_FILE. Nhắn /newbot cho @BotFather, điền token (nano $ENV_FILE), rồi chạy lại."
  exit 1
fi

step "Cho script cron (jev-cron-gate) thấy endpoint Jev"
# Hermes lọc env của script cron; chỉ tên trong terminal.env_passthrough mới đi qua.
# Không truyền TYPESAFE_API_KEY: cron-gate tự đọc key từ .env.
hermes config set --force terminal.env_passthrough '["TYPESAFE_BASE_URL", "TYPESAFE_MODEL"]' >/dev/null
echo "  terminal.env_passthrough = $(hermes config get terminal.env_passthrough | tr -d ' \n')"

step "Dừng runtime nền tạm (gateway run --idle-exit) để service quản lý gateway"
pkill -u "$(id -u)" -f 'hermes_cli.main .*gateway run' && echo "  đã dừng" || echo "  không có"

step "Cài và chạy hermes-gateway.service (systemd --user, có linger)"
# Nếu plugin đã tạo môi trường Python riêng (--yes-deps), môi trường đó không có python-telegram-bot.
# Nhánh --extra không cài chromium/cua-driver.
if HERMES_HOME=$HOME/.hermes /opt/hermes-agent/venv/bin/python -I -c \
     "import sys; sys.path.insert(0, '/opt/hermes-agent'); import hermes_bootstrap, telegram" 2>/dev/null; then
  echo "  python-telegram-bot đã có trong môi trường đang dùng"
else
  hermes pm install --extra telegram
fi
hermes gateway install --if-missing --start-now --start-on-login
systemctl --user enable --now hermes-gateway.service
sleep 5
systemctl --user --no-pager --lines=5 status hermes-gateway.service || true
hermes gateway status || true

step "Healthcheck mỗi 15 phút"
install -D -m 755 "$SRC/setup/hermes-home/.local/bin/agent-healthcheck" "$HOME/.local/bin/agent-healthcheck"
install -D -m 644 "$SRC"/setup/hermes-home/.config/systemd/user/agent-healthcheck.{service,timer} -t "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now agent-healthcheck.timer
"$HOME/.local/bin/agent-healthcheck" || true

cat <<EOF

Xong pha 6. Tiếp theo:
  1. Mở Telegram, nhắn bot bất kỳ câu nào: bot trả về một mã pairing 8 ký tự
  2. Duyệt chính bạn:  hermes pairing approve telegram <mã>
  3. Nhắn lại "Use the terminal tool to run: id", rồi gõ /sethome để cron và healthcheck gửi về chat này
  4. Log gateway:  journalctl --user -u hermes-gateway -f
EOF
