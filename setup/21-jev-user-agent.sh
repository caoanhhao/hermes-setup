#!/usr/bin/env bash
# Sửa lỗi 403 "error code: 1010": Cloudflare của opencode.ai chặn User-Agent mặc định "Python-urllib",
# nên jev-judge, jev-skill-router và jev-cron-gate (urllib, không đặt UA) bị chặn rồi fail-open, nhìn như "no_fit".
# Script thêm header User-Agent vào bản plugin đã cài. Chạy dưới user hermes, chạy lại vẫn an toàn:
#   sudo machinectl shell hermes@ /bin/bash /srv/agent-share/my-agent/setup/21-jev-user-agent.sh
# Phải chạy lại sau mỗi lần `hermes plugins update` / cài lại 3 plugin này.
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLUGINS=$HOME/.hermes/plugins

[[ $(id -un) == "${AGENT_USER:-hermes}" ]] || { echo "Phải chạy dưới user ${AGENT_USER:-hermes} (agent chạy bằng user khác thì đặt AGENT_USER=<user>)" >&2; exit 1; }

for name in jev-judge jev-skill-router jev-cron-gate; do
  p=$SRC/patches/$name-user-agent.patch
  d=$PLUGINS/$name
  if patch -s -p1 -R --dry-run -d "$d" < "$p" >/dev/null 2>&1; then
    echo "$name: đã có User-Agent"
  else
    patch -s -p1 -d "$d" < "$p"
    echo "$name: đã thêm User-Agent"
  fi
done

# Runtime nền (`gateway run --idle-exit`) giữ code plugin cũ trong bộ nhớ, nên phải khởi động lại
# thì hook mới dùng bản đã patch. Runtime --idle-exit tự bật lại khi cần.
if pkill -u "$(id -u)" -f 'hermes_cli.main .*gateway run'; then
  echo "đã dừng runtime nền cũ, lần chạy sau sẽ nạp plugin đã patch"
fi

echo
hermes jev-skill-router suggest "use the github skill to list open issues in NousResearch/hermes-agent"
