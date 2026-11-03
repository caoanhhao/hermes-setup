#!/usr/bin/env bash
# Pha 4: cài và cấu hình 4 plugin Jev từ catalog Hermes, chạy dưới user hermes:
#   sudo machinectl shell hermes@ /bin/bash /srv/agent-share/my-agent/setup/20-jev-plugins.sh
# Plugin được pin theo SHA trong catalog đi kèm hermes-agent-bin 0.22.6 (đã đọc code ngày 2026-11-03):
#   jev-judge, jev-skill-router  DoGMaTiiC/hermes-jev            5dddbeaa
#   jev-cron-gate                superlowburn/hermes-jev-cron-gate cfd99980
#   tool-slimmer                 aliasocracy/hermes-tool-slimmer  1b90aa59
# Chỉ sửa đúng các key bên dưới bằng `hermes config set`, phần config còn lại giữ nguyên.
set -euo pipefail

JEV_BASE=https://opencode.ai/zen            # plugin tự nối thêm /v1/systemone
JEV_URL=$JEV_BASE/v1/systemone             # cron-gate cần URL đầy đủ
JEV_MODEL=jev-1.13-free
ENV_FILE=$HOME/.hermes/.env

[[ $(id -un) == "${AGENT_USER:-hermes}" ]] || { echo "Phải chạy dưới user ${AGENT_USER:-hermes} (agent chạy bằng user khác thì đặt AGENT_USER=<user>)" >&2; exit 1; }

step() { printf '\n==> %s\n' "$*"; }
set_cfg() { hermes config set --force "$1" "$2" >/dev/null && echo "  $1 = $2"; }
set_env() {  # set_env KEY VALUE: thêm vào .env nếu chưa có KEY
  grep -q "^$1=" "$ENV_FILE" 2>/dev/null || { echo "$1=$2" >> "$ENV_FILE"; echo "  .env: thêm $1"; }
}

step "Kiểm tra key OpenCode"
if ! grep -qE '^TYPESAFE_API_KEY=.+' "$ENV_FILE" 2>/dev/null; then
  echo "THIẾU TYPESAFE_API_KEY trong $ENV_FILE. Các plugin sẽ fail-open (không làm gì) cho tới khi bạn điền key."
fi
set_env TYPESAFE_BASE_URL "$JEV_URL"
set_env TYPESAFE_MODEL "$JEV_MODEL"
chmod 600 "$ENV_FILE"

step "Cài plugin (chưa enable)"
for p in jev-judge jev-skill-router jev-cron-gate; do
  if hermes plugins list 2>/dev/null | grep -qw "$p"; then echo "  $p đã cài"; else hermes plugins install "$p" --no-enable; fi
done
# tool-slimmer cần pyyaml (venv của Hermes chỉ có ruamel.yaml)
hermes plugins list 2>/dev/null | grep -qw tool-slimmer || hermes plugins install tool-slimmer --no-enable --yes-deps

step "Cấu hình jev-judge (enforce: chặn lệnh vượt ngưỡng; Jev lỗi/timeout thì vẫn cho qua)"
set_cfg plugins.entries.jev-judge.settings.mode enforce
set_cfg plugins.entries.jev-judge.settings.backend typesafe
set_cfg plugins.entries.jev-judge.settings.typesafe_base_url "$JEV_BASE"
set_cfg plugins.entries.jev-judge.settings.typesafe_model "$JEV_MODEL"
set_cfg plugins.entries.jev-judge.settings.timeout_s 2.0

step "Cấu hình jev-skill-router"
set_cfg plugins.entries.jev-skill-router.settings.mode auto   # "on" bị YAML đọc thành true; auto = chạy khi có TYPESAFE_API_KEY
set_cfg plugins.entries.jev-skill-router.settings.backend typesafe
set_cfg plugins.entries.jev-skill-router.settings.typesafe_base_url "$JEV_BASE"
set_cfg plugins.entries.jev-skill-router.settings.typesafe_model "$JEV_MODEL"
set_cfg plugins.entries.jev-skill-router.settings.timeout_s 2.0

step "Cấu hình tool-slimmer (mode keyword: chạy local, không gửi gì ra ngoài)"
set_cfg tool_slimmer.enabled true
set_cfg tool_slimmer.mode keyword
set_cfg tool_slimmer.fail_open true
set_cfg tool_slimmer.jev.base_url "$JEV_BASE"
set_cfg tool_slimmer.jev.model "$JEV_MODEL"
set_cfg tool_slimmer.jev.api_key_env TYPESAFE_API_KEY

step "Manifest secret-env-strip (bỏ TYPESAFE_API_KEY khỏi terminal, cron script, execute_code)"
# Chỉ là manifest platform, không bật: Hermes đọc secret env của nó ở mỗi lần tạo tiến trình con.
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
install -D -m 644 "$SRC/setup/hermes-home/.hermes/plugins/platforms/secret-env-strip/plugin.yaml" \
  "$HOME/.hermes/plugins/platforms/secret-env-strip/plugin.yaml"

step "Enable"
for p in jev-judge jev-skill-router jev-cron-gate tool-slimmer; do
  hermes plugins enable "$p" || echo "  LỖI enable $p"
done

step "Trạng thái"
hermes plugins list
hermes jev-skill-router status 2>&1 | head -15 || true

cat <<EOF

Xong pha 4. Thử:
  hermes chat -q "Dùng tool terminal để chạy lệnh: id"
rồi xem log quyết định của jev-judge:
  tail -n 5 ~/.hermes/logs/jev-judge.log
EOF
