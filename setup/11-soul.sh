#!/usr/bin/env bash
# Quy tắc SOUL cho agent (chạy dưới user hermes):
#   sudo machinectl shell hermes@ /bin/bash /srv/agent-share/my-agent/setup/11-soul.sh
# Chỉ được ghi trong ~/hermes, mọi nơi khác chỉ đọc. Đây là quy tắc trong prompt, model có thể không tuân;
# quyền Linux của user hermes vẫn là giới hạn cứng.
# Chạy lại an toàn: khối giữa hai marker trong ~/.hermes/SOUL.md được thay bằng bản mới, phần còn lại giữ nguyên.
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RULES=$SRC/setup/hermes-home/.hermes/SOUL.rules.md
SOUL=$HOME/.hermes/SOUL.md
BEGIN='<!-- my-agent rules:begin -->'
END='<!-- my-agent rules:end -->'

[[ $(id -un) == "${AGENT_USER:-hermes}" ]] || { echo "Phải chạy dưới user ${AGENT_USER:-hermes} (agent chạy bằng user khác thì đặt AGENT_USER=<user>)" >&2; exit 1; }
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
step() { printf '\n==> %s\n' "$*"; }

step "Thư mục làm việc ~/hermes"
install -d -m 700 "$HOME/hermes" "$HOME/hermes/tmp"
hermes config set --force terminal.cwd "~/hermes" >/dev/null
echo "  terminal.cwd = $(hermes config get terminal.cwd)"

step "Ghi quy tắc vào $SOUL"
touch "$SOUL"
tmp=$(mktemp "$SOUL.XXXXXX")
awk -v b="$BEGIN" -v e="$END" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' "$SOUL" > "$tmp"
sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp"   # bỏ dòng trống cuối để chạy lại không dồn dòng trống
{ [[ -s $tmp ]] && printf '\n'; echo "$BEGIN"; cat "$RULES"; echo "$END"; } >> "$tmp"
chmod 600 "$tmp" && mv "$tmp" "$SOUL"
echo "  $(grep -c . "$SOUL") dòng, khối quy tắc: $(grep -cF "$BEGIN" "$SOUL")"

step "Khởi động lại gateway để nạp SOUL mới"
systemctl --user restart hermes-gateway.service
sleep 3
systemctl --user is-active hermes-gateway.service

cat <<EOF

Thử trên Telegram:
  "Tạo file ~/hermes/test.txt chứa chữ ok"   -> nên làm
  "Ghi chữ ok vào ~/test.txt"                  -> nên từ chối và gợi ý làm trong ~/hermes
EOF
