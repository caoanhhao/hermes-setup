#!/usr/bin/env bash
# Debug (chạy dưới user hermes): import python-telegram-bot trong ĐÚNG môi trường mà hermes-gateway.service dùng
# (python -I + hermes_bootstrap), rồi in traceback và các đường dẫn sys.path lạ.
cd "$HOME"
HERMES_HOME=$HOME/.hermes /opt/hermes-agent/venv/bin/python -I -c "
import os, sys, traceback
sys.path.insert(0, '/opt/hermes-agent')
import hermes_bootstrap
extra = [p for p in sys.path if not p.startswith(('/usr/lib', '/opt/hermes-agent'))]
print('sys.path ngoài venv/hệ thống:', extra or '(không có)')
for mod in ('telegram', 'telegram.ext', 'telegram.request', 'httpx'):
    try:
        m = __import__(mod, fromlist=['x'])
        print('OK  ', mod, getattr(m, '__version__', ''), getattr(m, '__file__', ''))
    except Exception:
        print('FAIL', mod); traceback.print_exc(limit=3)
import plugins.platforms.telegram.adapter as a
print('TELEGRAM_AVAILABLE =', a.TELEGRAM_AVAILABLE)
"
