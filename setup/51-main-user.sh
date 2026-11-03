#!/usr/bin/env bash
# Dựng lại agent dưới user chính, sau setup/50-move-to-main-user.sh. Chạy KHÔNG cần sudo:
#   bash setup/51-main-user.sh
# Chạy lần lượt script 30 (gateway + Telegram + healthcheck), 21 (vá User-Agent cho plugin Jev)
# và 11 (SOUL, cwd ~/hermes) với AGENT_USER là user hiện tại.
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export AGENT_USER=$(id -un)
[[ $AGENT_USER != hermes && $EUID != 0 ]] || { echo "Chạy bằng user chính của bạn, không sudo" >&2; exit 1; }
[[ -f $HOME/.hermes/config.yaml ]] || { echo "Chưa có ~/.hermes/config.yaml: chạy sudo bash $DIR/50-move-to-main-user.sh trước" >&2; exit 1; }

# Dựng lại môi trường Python theo đường dẫn mới: dấu (stamp) cũ tính từ /home/hermes nên Hermes báo
# "install out of sync" cho tới khi chạy lại bước này (cần script 50 đã đổi khoá plugin-sources).
hermes pm install --extra telegram
bash "$DIR/30-gateway.sh"
bash "$DIR/21-jev-user-agent.sh"
bash "$DIR/11-soul.sh"

printf '\n==> Kiểm tra\n'
systemctl --user is-active hermes-gateway.service agent-healthcheck.timer
hermes config get plugins.entries.jev-judge.settings.mode
"$HOME/.local/bin/agent-healthcheck" || true
