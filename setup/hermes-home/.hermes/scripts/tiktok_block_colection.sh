#!/usr/bin/env bash
# Cron "Block tiktok" (chế độ --no-agent): chạy thẳng skill tiktok-block-colection, không qua model.
# Hermes gửi nguyên văn stdout (các dòng báo cáo của tnb.sh run); thông báo phụ nằm ở ~/.cache/tnb.log.
exec "$HOME/.hermes/skills/tiktok-block-colection/scripts/tnb.sh" run
