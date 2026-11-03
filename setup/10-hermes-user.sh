#!/usr/bin/env bash
# Phần chạy dưới user hermes. Từ tài khoản của bạn:
#   sudo machinectl shell hermes@ /bin/bash /srv/agent-share/my-agent/setup/10-hermes-user.sh
# Chạy lại nhiều lần cũng an toàn: không ghi đè config hay .env đã có.
# Không có display, VNC hay trình duyệt: agent chỉ dùng terminal, file và HTTP.
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # /srv/agent-share/my-agent

[[ $(id -un) == "${AGENT_USER:-hermes}" ]] || { echo "Phải chạy dưới user ${AGENT_USER:-hermes} (agent chạy bằng user khác thì đặt AGENT_USER=<user>)" >&2; exit 1; }

step() { printf '\n==> %s\n' "$*"; }
copy_once() {  # copy_once SRC DST MODE: chỉ copy khi DST chưa tồn tại
  if [[ -e $2 ]]; then echo "giữ nguyên $2"; else install -D -m "$3" "$1" "$2"; echo "đã tạo $2"; fi
}

step "Hermes config và .env"
install -d "$HOME/hermes/work"
copy_once "$SRC/setup/hermes-home/.hermes/config.yaml" "$HOME/.hermes/config.yaml" 600
copy_once "$SRC/setup/hermes-home/.hermes/.env.example" "$HOME/.hermes/.env" 600

step "Kiểm tra"
curl -fsS http://127.0.0.1:11434/api/tags >/dev/null && echo "Ollama: OK" || echo "Ollama: LỖI"
hermes --version | head -1

cat <<EOF

Còn lại (bạn tự làm):
  1. Điền OpenCode key vào ~/.hermes/.env (TYPESAFE_API_KEY)
  2. Thử Hermes CLI:   hermes      (model Ollama, terminal chạy với quyền hermes)
EOF
