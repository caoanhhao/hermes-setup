#!/usr/bin/env bash
# tnb.sh: block kênh TikTok theo collection "block" (skill tiktok-block-colection), chạy ngầm không chiếm màn hình.
# Trình duyệt riêng của Hermes (Google Chrome, profile riêng) nằm ở workspace 9 và không cần được hiển thị:
# nó chạy qua XWayland (--ozone-platform=x11) với các cờ tắt chế độ ngủ nền, nên vẫn tải và chạy trang khi
# workspace 9 bị ẩn. Trang được điều khiển bằng JavaScript qua Chrome DevTools Protocol (cdp.mjs, cổng chỉ nghe
# trên 127.0.0.1, chỉ mở khi chạy ngầm): mở URL, chờ phần tử hiện ra thay vì sleep, bấm bằng sự kiện chuột của
# trang. Không dùng chuột hay phím của user, không đổi workspace của user.
#
#   tnb.sh run            làm hết: lấy kênh trong collection block, gỡ video, block từng kênh, đóng trình duyệt,
#                         in báo cáo (thông báo phụ ở ~/.cache/tnb.log; mỗi lần chỉ một lượt)
#   tnb.sh login          mở trình duyệt của Hermes trên màn hình để user tự đăng nhập, chờ user đóng nó
#   tnb.sh start          bảo đảm có cửa sổ trình duyệt của Hermes ở workspace 9, điều khiển được qua DevTools
#   tnb.sh collection     mở collection block (URL đã lưu, hoặc tiktok.com → Profile → Favorites → Collections),
#                         in handle từng kênh (hoặc empty)
#   tnb.sh remove         gỡ mọi video khỏi collection block đang mở, in: removed N | failed: <lý do>
#   tnb.sh block HANDLE   block kênh @HANDLE, in: blocked | already | failed: <lý do>
#   tnb.sh open URL       mở URL trong trình duyệt của Hermes, chờ dựng xong trang, in tiêu đề
set -euo pipefail

WS=9
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Trình duyệt riêng của Hermes: Google Chrome với profile riêng (user tự đăng nhập các tài khoản bằng
# "tnb.sh login"), class cửa sổ riêng "hermes-chrome" để không lẫn với Chrome của user.
PROFILE=${HERMES_CHROME_PROFILE:-$HOME/.local/share/hermes-chrome}
# URL trang collection "block" (cố định, kèm id của collection), tự tìm ra lần đầu bằng đường bấm rồi lưu ở đây.
# Có cache thì "_collection" mở thẳng URL đó; URL không dùng được thì xoá, đi lại đường bấm và lưu URL mới.
URL_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/tnb-collection-url
CDP_PORT=${TNB_CDP_PORT:-9334}

# Phần tử trên giao diện TikTok: selector CSS (thường theo thuộc tính data-e2e của TikTok) hoặc chữ hiển thị, xem
# bằng "tnb.sh open URL" rồi "node cdp.mjs $CDP_PORT eval JS". TikTok đổi giao diện thì thường chỉ cần sửa ở đây.
# Các chữ ghi "tiền tố" được so khớp phần đầu (vd nút thật tên "Remove (6)").
SEL_PROFILE='[data-e2e=nav-profile]'                 # link Profile ở sidebar, href là /@<mình>
SEL_EDIT_PROFILE='[data-e2e=edit-profile-entrance]'  # chỉ có trên trang của chính mình, khi đã đăng nhập
SEL_FAVORITES='[data-e2e=favorites-tab]'             # tab trên trang profile
SEL_COLLECTIONS='[data-e2e=sub-tab-collections]'     # nút "Collections N" trong tab Favorites
TXT_COLLECTION='block '                              # tiền tố, link "block N videos" tới collection
SEL_MANAGE='[data-e2e=collection-action-manage]'     # nút Manage videos trên trang collection
SEL_ITEM='[data-e2e=collection-item]'                # thẻ video trong lưới collection
SEL_ITEM_AUTHOR='a[data-e2e=collection-item-avatar]' # link /@<kênh> trong thẻ video
TXT_SELECT_ALL='Select all'
TXT_REMOVE_N='Remove ('                              # tiền tố, nút "Remove (N)" sau khi chọn
TXT_REMOVE='Remove'                                  # nút xác nhận trong hộp thoại
TXT_EMPTY='No videos in this collection'             # chữ trên trang collection trống
SEL_ACTIONS='[data-e2e=user-more]'                   # nút … (Actions) trên trang kênh
TXT_BLOCK='Block'                                    # mục trong menu Actions
SEL_BLOCK_CONFIRM='[data-e2e=block-popup-block-btn]' # nút Block của hộp thoại xác nhận
TXT_UNBLOCK='Unblock'                                # tiền tố, nút "Unblock <tên>" khi kênh đã bị block

CLASS=hermes-chrome
CHROME_FLAGS=(--user-data-dir="$PROFILE" --class="$CLASS" --password-store=basic --no-first-run
              --hide-crash-restore-bubble --ozone-platform=x11 --disable-backgrounding-occluded-windows
              --disable-renderer-backgrounding --disable-background-timer-throttling)

# Gateway của Hermes chạy dưới systemd, không có biến môi trường của phiên Hyprland: tự tìm phiên đang chạy
# (thư mục mới nhất trong $XDG_RUNTIME_DIR/hypr có socket), socket Wayland và display của Xwayland.
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  for d in $(ls -t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null); do
    [ -S "$XDG_RUNTIME_DIR/hypr/$d/.socket.sock" ] && { export HYPRLAND_INSTANCE_SIGNATURE=$d; break; }
  done
fi
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
  for s in "$XDG_RUNTIME_DIR"/wayland-[0-9]*; do
    case "$s" in *.lock) continue ;; esac
    [ -S "$s" ] && { export WAYLAND_DISPLAY=${s##*/}; break; }
  done
fi
if [ -z "${DISPLAY:-}" ]; then
  # Lấy display của Xwayland từ socket X của chính user trong /tmp/.X11-unix (X0 của root là của màn hình khác),
  # không quét /proc (xem chrome_pid).
  for s in /tmp/.X11-unix/X*; do
    n=${s##*/X}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ -S "$s" ] && [ -O "$s" ] && { export DISPLAY=:$n; break; }
  done
fi

# hypruse desktop đôi khi không trả kết quả: thử lại vài lần thay vì để set -e dừng script.
desktop_json() {
  local out
  for _ in 1 2 3 4 5; do
    out=$(hypruse desktop --json 2>/dev/null) && [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    sleep 0.5
  done
  echo '{"result": {"windows": [], "monitors": []}}'
}

# PID tiến trình chính của Chrome đang dùng profile của Hermes (còn chạy thì in ra), lấy từ symlink SingletonLock
# "<máy>-<pid>" mà Chrome tạo trong profile. Không dùng pgrep/pkill -f: chúng đọc dòng lệnh của mọi tiến trình
# trong /proc và treo theo bất kỳ tiến trình nào kẹt ở trạng thái D (vd một clang đang build), giữ khoá của "run".
chrome_pid() {
  local l
  l=$(readlink "$PROFILE/SingletonLock" 2>/dev/null) || return 1
  l=${l##*-}
  [ -n "$l" ] && kill -0 "$l" 2>/dev/null && echo "$l"
}

# Có cửa sổ trình duyệt của Hermes ở workspace 9 thì in địa chỉ.
chrome_addr() {
  desktop_json | python3 -c '
import json, sys
for w in json.load(sys.stdin)["result"]["windows"]:
    if w["class"] == sys.argv[1] and str(w["workspace"]) == sys.argv[2]:
        print(w["address"]); break' "$CLASS" "$WS"
}

# Chrome của Hermes có mở cổng DevTools không.
cdp_up() { curl -s --max-time 2 "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null; }

# Đóng hẳn Chrome của Hermes: đóng cửa sổ, chờ thoát, còn tiến trình chính thì gửi TERM.
chrome_quit() {
  local a p
  a=$(chrome_addr); [ -n "$a" ] && hypruse hypr close_window "$a" >/dev/null 2>&1 || true
  for _ in $(seq 20); do chrome_pid >/dev/null || return 0; sleep 0.5; done
  p=$(chrome_pid) && kill -TERM "$p" 2>/dev/null || true
}

# Bảo đảm có cửa sổ Chrome của Hermes ở workspace 9 với cổng DevTools, in địa chỉ cửa sổ. Chrome đang chạy mà không
# có cổng (vd mở bằng "login") thì đóng rồi mở lại. Cổng DevTools chỉ nghe trên 127.0.0.1.
win() {
  local addr
  addr=$(chrome_addr)
  if [ -n "$addr" ] && ! cdp_up; then chrome_quit; addr=""; fi
  if [ -z "$addr" ]; then
    hypruse launch --workspace "$WS" --wait 25 -- google-chrome-stable "${CHROME_FLAGS[@]}" \
      --remote-debugging-port="$CDP_PORT" --new-window https://www.tiktok.com/ >/dev/null || true
    addr=$(chrome_addr)
  fi
  for _ in $(seq 40); do cdp_up && break; sleep 0.25; done
  echo "$addr"
}

# Chạy JS trong tab đang mở (xem cdp.mjs; có sẵn vis, nm, find, click). js: in giá trị. wait_js JS SECS: chờ tới
# khi JS truthy, in giá trị. tap JS SECS: chờ phần tử JS trả về hiện ra rồi bấm. nav URL SECS: mở URL.
js() { node "$DIR/cdp.mjs" "$CDP_PORT" eval "$1"; }
wait_js() { node "$DIR/cdp.mjs" "$CDP_PORT" wait "$1" "${2:-30}"; }
tap() { node "$DIR/cdp.mjs" "$CDP_PORT" tap "$1" "${2:-30}" >/dev/null; }
nav() { node "$DIR/cdp.mjs" "$CDP_PORT" nav "$1" "${2:-60}"; }

title() { js 'document.title' 2>/dev/null || true; }

# JS: nút/mục hiển thị có tên đúng TEXT (phần tử cuối cùng trong trang: hộp thoại nằm cuối DOM).
exact() { echo "[...document.querySelectorAll(CLICKABLE)].filter(e => vis(e) && nm(e) === '$1').pop() || null"; }
# JS: trang có chữ TEXT ở đâu đó.
has_text() { echo "document.body && document.body.innerText.includes('$1')"; }

# Thoát mã 5 nếu chưa có Chrome của Hermes ở workspace 9 điều khiển được (chưa gọi "start").
need_ready() {
  [ -n "$(chrome_addr)" ] && cdp_up || { echo "tnb: chưa có Chrome ở workspace $WS, chạy: tnb.sh start" >&2; exit 5; }
}

# Lưu những gì trang đang hiển thị (tiêu đề, URL, các phần tử data-e2e và nút) vào ~/.cache/tnb-fail/ khi một bước
# hỏng, để sửa SEL_*/TXT_* nếu TikTok đổi giao diện. In đường dẫn file (dạng ~/...); giữ 20 file gần nhất.
snapshot() {
  local dir f
  cdp_up || return 0
  dir=${XDG_CACHE_HOME:-$HOME/.cache}/tnb-fail
  mkdir -p "$dir"
  f=$dir/$(date +%Y%m%d-%H%M%S)-$1.txt
  {
    echo "# bước: $1"
    echo "# lỗi: $2"
    echo "# tiêu đề: $(title)"
    echo "# url: $(js 'location.href' 2>/dev/null || true)"
    echo "## phần tử hiển thị (thẻ | role | data-e2e | tên)"
    js "[...document.querySelectorAll('[data-e2e], ' + CLICKABLE)].filter(vis).map(e => [e.tagName, e.getAttribute('role') || '', e.dataset.e2e || '', nm(e).slice(0, 100)].join(' | ')).join('\\n')" 2>&1 || true
  } > "$f" 2>&1
  ls -t "$dir"/*.txt 2>/dev/null | tail -n +21 | xargs -r rm -f
  echo "${f/#$HOME/\~}"
}

# Mở trang collection URL (bỏ qua nếu đang ở đó) và chờ nút Manage videos; không ra trang collection thì mã 1.
open_collection() {
  local path=${1#https://www.tiktok.com}
  [ "$(js 'location.pathname' 2>/dev/null)" = "$path" ] || nav "$1" 90 >/dev/null || true
  wait_js "location.pathname.includes('/collection/') && document.querySelector('$SEL_MANAGE')" 90 >/dev/null
}

# tiktok.com → Profile → Favorites → Collections, in URL của collection block (hoặc "failed: <lý do>", mã 1)
# và bấm vào nó.
find_collection_url() {
  local href
  nav https://www.tiktok.com/ 60 >/dev/null || true
  wait_js "(e => e && e.getAttribute('href').startsWith('/@'))(document.querySelector('$SEL_PROFILE'))" 60 >/dev/null ||
    { echo "failed: chưa đăng nhập (không có link Profile tới trang của mình)"; return 1; }
  tap "document.querySelector('$SEL_PROFILE')" 10 || { echo "failed: không bấm được Profile"; return 1; }
  wait_js "document.querySelector('$SEL_EDIT_PROFILE')" 60 >/dev/null ||
    { echo "failed: bấm Profile không mở được trang của mình (chưa đăng nhập?)"; return 1; }
  tap "document.querySelector('$SEL_FAVORITES')" 30 || { echo "failed: không thấy tab Favorites"; return 1; }
  # Nút hiện "Collections 0" trong lúc còn tải: chờ số collection > 0 rồi mới bấm.
  tap "(e => e && /[1-9]/.test(nm(e)) ? e : null)(document.querySelector('$SEL_COLLECTIONS'))" 30 ||
    { echo "failed: không thấy tab Collections (hoặc chưa có collection nào)"; return 1; }
  href=$(wait_js "(a => a && a.getAttribute('href'))([...document.querySelectorAll('a[href*=\"/collection/\"]')].find(a => vis(a) && nm(a).startsWith('$TXT_COLLECTION')))" 30) ||
    { echo "failed: không thấy collection block trong tab Collections"; return 1; }
  tap "[...document.querySelectorAll('a[href*=\"/collection/\"]')].find(a => nm(a).startsWith('$TXT_COLLECTION'))" 10 || true
  href=${href%%\?*}
  echo "https://www.tiktok.com$href"
}

case "${1:-}" in
  open|block|collection|_collection|remove) need_ready ;;
esac

case "${1:-}" in
  login)
    # User tự đăng nhập: đóng cửa sổ đang chạy ngầm ở workspace 9 rồi mở lại trên màn hình của user (không qua
    # hypruse launch, không mở cổng DevTools), chờ tới khi user đóng trình duyệt. Không bao giờ gõ mật khẩu hộ.
    chrome_quit
    echo "Đăng nhập trong cửa sổ Chrome vừa mở, xong thì đóng cửa sổ đó."
    google-chrome-stable "${CHROME_FLAGS[@]}" https://www.tiktok.com/login >/dev/null 2>&1 || true
    ;;
  start)
    # Mở trình duyệt của Hermes (có cửa sổ, có cổng DevTools) ở workspace 9 nếu chưa có; không đụng Chrome của user.
    w=$(win)
    [ -n "$w" ] && cdp_up || { echo "tnb: không mở được Chrome của Hermes ở workspace $WS" >&2; exit 5; }
    echo ready
    ;;
  run)
    # Cả quy trình, chạy ngầm ở workspace 9: lấy danh sách kênh → gỡ hết video → block từng kênh → đóng trình
    # duyệt. Chỉ in báo cáo tiếng Việt ra stdout (mỗi dòng một kết quả); thông báo phụ ghi vào $LOG.
    # Mỗi lần chỉ một lượt: lượt thứ hai báo đang chạy và thoát ngay, không đụng vào trình duyệt.
    LOG=${XDG_CACHE_HOME:-$HOME/.cache}/tnb.log
    mkdir -p "${LOG%/*}"
    exec 9>"${LOG%/*}/tnb.lock"
    flock -n 9 || { echo "đang có một lượt block khác chạy, chờ nó xong rồi xem kết quả của lượt đó"; exit 0; }
    exec 2>>"$LOG"
    echo "== $(date '+%F %T') run" >&2
    "$0" start >/dev/null || { echo "lỗi: không mở được trình duyệt của Hermes ở workspace $WS"; exit 1; }
    # Xong (kể cả khi lỗi hay bị ngắt) thì tắt hẳn trình duyệt của Hermes (đóng luôn cổng DevTools).
    finish() { trap - EXIT INT TERM HUP; chrome_quit; }
    trap finish EXIT
    trap 'exit 130' INT TERM HUP
    list=$("$0" collection) || { echo "lỗi: ${list#failed: } (chi tiết: $(snapshot collection "$list"))"; exit 1; }
    if [ "$list" = empty ]; then echo "collection block trống, không có kênh nào để block"; exit 0; fi
    if r=$("$0" remove); then echo "đã gỡ ${r#removed } video khỏi collection block"
    else echo "lỗi khi gỡ video: ${r#failed: } (chi tiết: $(snapshot remove "$r"))"; fi
    while read -r h; do
      r=$("$0" block "$h") || r=$("$0" block "$h") || true
      case "$r" in
        blocked) echo "@$h: đã block" ;;
        already) echo "@$h: đã block từ trước" ;;
        *) echo "@$h: lỗi: ${r#failed: } (chi tiết: $(snapshot "block-$h" "$r"))" ;;
      esac
    done <<< "$list"
    ;;
  win) win ;;
  open)
    url=${2:?url}
    nav "$url" 60 || { echo "failed: trang không tải xong ($url)"; exit 1; }
    ;;
  block)
    handle=${2:?handle}; handle=${handle#@}
    nav "https://www.tiktok.com/@$handle" 60 >/dev/null || true
    # Trang kênh xong khi tiêu đề có (@handle) và có nút Actions hoặc Unblock (kênh đã block).
    wait_js "document.title.includes('(@$handle)') && (document.querySelector('$SEL_ACTIONS') || find('$TXT_UNBLOCK', 'button'))" 90 >/dev/null ||
      { echo "failed: trang kênh không mở đúng ($(title))"; exit 1; }
    if js "!!find('$TXT_UNBLOCK', 'button')" | grep -qx true; then echo already; exit 0; fi
    # Bấm Actions tới khi menu có mục Block, bấm Block tới khi có hộp thoại xác nhận, tối đa 3 lần mỗi bước.
    ok=""
    for _ in 1 2 3; do
      tap "document.querySelector('$SEL_ACTIONS')" 10 || continue
      tap "$(exact "$TXT_BLOCK")" 5 || continue
      wait_js "document.querySelector('$SEL_BLOCK_CONFIRM')" 10 >/dev/null && { ok=1; break; }
    done
    [ -n "$ok" ] || { echo "failed: không mở được hộp thoại xác nhận Block"; exit 1; }
    # Bấm Block của hộp thoại tới khi trang có nút Unblock (hộp thoại còn thì bấm lại).
    for _ in 1 2 3; do
      tap "document.querySelector('$SEL_BLOCK_CONFIRM')" 5 || true
      wait_js "find('$TXT_UNBLOCK', 'button')" 15 >/dev/null && { echo blocked; exit 0; }
    done
    echo "failed: chưa thấy nút $TXT_UNBLOCK sau khi bấm"; exit 1
    ;;
  collection)
    # Trang TikTok đôi khi bỏ qua một lệnh bấm: chạy lại cả quy trình tối đa 3 lần.
    for _ in 1 2 3; do
      out=$("$0" _collection) && { echo "$out"; exit 0; }
    done
    echo "$out"; exit 1
    ;;
  _collection)
    # Mở collection block (URL đã lưu, hoặc tìm bằng đường bấm rồi lưu), rồi in handle các kênh trong collection
    # (bỏ kênh của mình), "empty" nếu không có video.
    url=$(cat "$URL_CACHE" 2>/dev/null || true)
    if [ -z "$url" ] || ! open_collection "$url"; then
      [ -z "$url" ] || echo "url collection đã lưu không dùng được ($url), đi đường bấm" >&2
      rm -f "$URL_CACHE"
      url=$(find_collection_url) || { echo "$url"; exit 1; }
      open_collection "$url" || { echo "failed: trang collection block không mở"; exit 1; }
      printf '%s\n' "$url" > "$URL_CACHE"
    fi
    me=$(js "(e => e ? e.getAttribute('href').replace(/^\\/@/, '').split('?')[0] : '')(document.querySelector('$SEL_PROFILE'))" || true)
    [ -n "$me" ] || me=$(printf '%s\n' "$url" | grep -o '/@[^/]*' | tr -d '/@' | head -1)
    # Chờ lưới hiện thẻ video hoặc chữ "trống", rồi cuộn tới cuối cho tới khi số thẻ và số link tác giả không đổi
    # trong 3 giây (lưới nạp dần, link tác giả của thẻ có thể đến sau thẻ).
    wait_js "document.querySelector('$SEL_ITEM') || $(has_text "$TXT_EMPTY")" 60 >/dev/null || true
    list=$(js "(async () => {
      const count = () => document.querySelectorAll('$SEL_ITEM').length + '/' + document.querySelectorAll('$SEL_ITEM_AUTHOR').length;
      let last = '', same = 0;
      for (let i = 0; i < 80 && same < 6; i++) {
        const items = document.querySelectorAll('$SEL_ITEM');
        items[items.length - 1]?.scrollIntoView();
        await new Promise(r => setTimeout(r, 500));
        const c = count();
        same = c === last ? same + 1 : 0; last = c;
      }
      const hs = [...document.querySelectorAll('$SEL_ITEM_AUTHOR')].map(a => new URL(a.href).pathname.slice(2).split('/')[0]);
      return [...new Set(hs)].filter(h => /^[A-Za-z0-9._]+\$/.test(h) && h !== '$me').join('\\n');
    })()") || { echo "failed: không đọc được lưới video của collection block"; exit 1; }
    [ -n "$list" ] && { echo "$list"; exit 0; }
    # Không có kênh nào: báo trống khi trang nói vậy, hoặc lưới có thẻ video mà suốt 10 giây không thẻ nào có link
    # tác giả (video đã xoá, của chính mình). Còn không thì lưới chưa tải, để "collection" chạy lại.
    if js "$(has_text "$TXT_EMPTY")" | grep -qx true; then echo empty; exit 0; fi
    if js "!!document.querySelector('$SEL_ITEM')" | grep -qx true &&
       ! wait_js "[...document.querySelectorAll('$SEL_ITEM_AUTHOR')].some(a => !a.href.includes('/@$me'))" 10 >/dev/null; then
      echo empty; exit 0
    fi
    echo "failed: lưới video của collection block chưa tải"; exit 1
    ;;
  remove)
    # Trên trang collection block (sau "collection"): Manage videos → Select all → Remove (N) → Remove.
    js "location.pathname" | grep -q '/collection/' || { echo "failed: không ở trang collection block ($(title))"; exit 1; }
    tap "document.querySelector('$SEL_MANAGE')" 15 || { echo "failed: không thấy nút Manage videos"; exit 1; }
    tap "$(exact "$TXT_SELECT_ALL")" 15 || { echo "failed: bấm Manage videos không vào chế độ chọn"; exit 1; }
    n=$(wait_js "(e => e && nm(e))(find('$TXT_REMOVE_N', 'button'))" 15) ||
      { echo "failed: bấm $TXT_SELECT_ALL không chọn được video"; exit 1; }
    # Bấm "Remove (N)", rồi nút "Remove" của hộp thoại xác nhận ("Remove N videos from block", có Cancel và Remove).
    # Lặp tới khi trang báo trống: còn hộp thoại thì bấm lại nút của nó, hộp thoại đã đóng thì bấm lại "Remove (N)".
    for _ in 1 2 3; do
      if js "!!($(exact "$TXT_REMOVE"))" | grep -qx true; then
        tap "$(exact "$TXT_REMOVE")" 5 || true
      else
        tap "find('$TXT_REMOVE_N', 'button')" 5 || true
        tap "$(exact "$TXT_REMOVE")" 10 || true
      fi
      wait_js "$(has_text "$TXT_EMPTY")" 20 >/dev/null && { echo "removed ${n//[^0-9]/}"; exit 0; }
    done
    echo "failed: chưa thấy '$TXT_EMPTY' sau khi bấm"; exit 1
    ;;
  *) sed -n '2,17p' "$0"; exit 2 ;;
esac
