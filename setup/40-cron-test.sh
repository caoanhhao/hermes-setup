#!/usr/bin/env bash
# Thử cron job + jev-cron-gate (chạy dưới user hermes):
#   sudo machinectl shell hermes@ /bin/bash /srv/agent-share/my-agent/setup/40-cron-test.sh
# Tạo job "inbox-watch" (mỗi 30 phút đọc ~/hermes/work/inbox.md, gửi Telegram), gắn wake-gate Jev:
#   - inbox không có việc mới  -> Jev chấm thấp -> {"wakeAgent": false} -> không tốn lượt LLM
#   - có dòng "- [ ]" mới       -> Jev chấm cao -> agent chạy và báo về Telegram
# Chạy lại an toàn: job và gate đã có thì giữ nguyên.
set -euo pipefail

NAME=inbox
JOB_NAME=inbox-watch
INBOX=$HOME/hermes/work/inbox.md
GATE_PLUGIN=$HOME/.hermes/plugins/jev-cron-gate

[[ $(id -un) == "${AGENT_USER:-hermes}" ]] || { echo "Phải chạy dưới user ${AGENT_USER:-hermes} (agent chạy bằng user khác thì đặt AGENT_USER=<user>)" >&2; exit 1; }
cd "$HOME"
step() { printf '\n==> %s\n' "$*"; }
# Mô phỏng env mà cron đưa cho script (terminal.env_passthrough); key cron-gate tự đọc từ .env
eval "$(grep -E '^(TYPESAFE_BASE_URL|TYPESAFE_MODEL)=' "$HOME/.hermes/.env" | sed 's/^/export /')"

gate_py() {  # gate_py ACTION [JSON-ARGS]: gọi thẳng handler jev_cron_gate của plugin
  HERMES_HOME=$HOME/.hermes /opt/hermes-agent/venv/bin/python -I - "$GATE_PLUGIN" "$1" "${2:-}" <<'EOF'
import importlib.util, json, os, sys
base, action, args = sys.argv[1], sys.argv[2], json.loads(sys.argv[3] or "{}")
spec = importlib.util.spec_from_file_location("jcg", os.path.join(base, "__init__.py"), submodule_search_locations=[base])
mod = importlib.util.module_from_spec(spec); sys.modules["jcg"] = mod; spec.loader.exec_module(mod)
out = json.loads(sys.modules["jcg.tools"].handle({"action": action, **args}))
out.pop("state_preview", None)
print(json.dumps(out, ensure_ascii=False))
EOF
}

step "Inbox thử: $INBOX"
mkdir -p "$(dirname "$INBOX")"
[[ -f $INBOX ]] || printf '# Inbox\n\n- [x] việc cũ đã xong\n' > "$INBOX"
cat "$INBOX"

step "Cron job $JOB_NAME"
JOB_ID=$(hermes cron list --all 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk -v n="$JOB_NAME" '$0 ~ n {for (i=1;i<=NF;i++) if ($i ~ /^[0-9a-f]{8,}$/) {print $i; exit}}')
if [[ -z $JOB_ID ]]; then
  JOB_ID=$(hermes cron create "every 30m" \
    "Read ~/hermes/work/inbox.md. List every unchecked '- [ ]' item in at most 5 short lines. If there is none, reply exactly: nothing new." \
    --name "$JOB_NAME" --deliver telegram 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/.*Created job: *\([0-9a-zA-Z_-]*\).*/\1/p')
  [[ -n $JOB_ID ]] || { echo "Không tạo được job" >&2; exit 1; }
  echo "  đã tạo job $JOB_ID"
else
  echo "  đã có job $JOB_ID"
fi

step "Wake-gate Jev cho job"
gate_py setup "$(printf '{"name":"%s","job_id":"%s","question":"%s","sources":"%s"}' "$NAME" "$JOB_ID" \
  "The inbox file contains at least one unchecked TODO item (a line starting with '- [ ]'), so running the agent now would report something new." \
  '[{\"file\": \"~/hermes/work/inbox.md\"}, {\"changed\": [\"~/hermes/work/inbox.md\"]}]')"
hermes cron edit "$JOB_ID" --script "jev_gate_$NAME.py" >/dev/null && echo "  đã gắn jev_gate_$NAME.py vào job"

step "Thử 1: inbox không có việc mới (mong đợi would_wake=false)"
gate_py test "{\"name\":\"$NAME\"}"

step "Thử 2: thêm một việc mới (mong đợi would_wake=true)"
grep -q 'kiểm tra cron-gate' "$INBOX" || echo '- [ ] kiểm tra cron-gate gửi Telegram' >> "$INBOX"
gate_py test "{\"name\":\"$NAME\"}"

step "Chạy job ở tick kế tiếp của scheduler"
hermes cron run "$JOB_ID"
cat <<EOF

Đợi khoảng 1 phút, Telegram sẽ nhận danh sách việc. Xem lại:
  hermes cron runs $JOB_ID --limit 3
  tail -n 3 ~/.hermes/jev-cron-gates/log.jsonl
Dọn dẹp khi xong: hermes cron rm $JOB_ID
EOF
