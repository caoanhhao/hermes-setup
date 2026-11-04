#!/usr/bin/env bash
# tnb.sh: block kênh TikTok theo collection "block" (skill tiktok-block-colection), chạy ngầm không chiếm màn hình.
# Trình duyệt riêng của Hermes (Google Chrome, profile riêng) nằm ở workspace 9 và không cần được hiển thị:
# nó chạy qua XWayland (--ozone-platform=x11) với các cờ tắt chế độ ngủ nền, nên vẫn tải và chạy trang khi
# workspace 9 bị ẩn. Mọi cú bấm đi qua accessibility (hypruse click_ui), không dùng chuột hay phím, không đổi
# workspace của user.
#
#   tnb.sh run            làm hết: lấy kênh trong collection block, gỡ video, block từng kênh, đóng trình duyệt,
#                         in báo cáo (thông báo phụ ở ~/.cache/tnb.log; mỗi lần chỉ một lượt)
#   tnb.sh login          mở trình duyệt của Hermes trên màn hình để user tự đăng nhập, chờ user đóng nó
#   tnb.sh start          bảo đảm có cửa sổ trình duyệt của Hermes ở workspace 9
#   tnb.sh collection     tiktok.com → Profile → Favorites → Collections → block, in handle từng kênh (hoặc empty)
#   tnb.sh remove         gỡ mọi video khỏi collection block đang mở, in: removed N | failed: <lý do>
#   tnb.sh block HANDLE   block kênh @HANDLE, in: blocked | already | failed: <lý do>
#   tnb.sh open URL       mở URL trong trình duyệt của Hermes, chờ tải xong, in tiêu đề
set -euo pipefail

WS=9
# Trình duyệt riêng của Hermes: Google Chrome với profile riêng (user tự đăng nhập các tài khoản bằng
# "tnb.sh login"), class cửa sổ riêng "hermes-chrome" để không lẫn với Chrome của user. Chrome của profile mới
# không tự bật cây accessibility nên phải ép bằng --force-renderer-accessibility.
PROFILE=${HERMES_CHROME_PROFILE:-$HOME/.local/share/hermes-chrome}
# Trang của collection "block" (id cố định của collection): dùng khi tab Collections không nhận lệnh bấm.
COLLECTION_URL=${TNB_COLLECTION_URL:-https://www.tiktok.com/@USER/collection/block-ID}
CLASS=hermes-chrome
CHROME_FLAGS=(--user-data-dir="$PROFILE" --class="$CLASS" --password-store=basic --no-first-run --force-renderer-accessibility
              --ozone-platform=x11 --disable-backgrounding-occluded-windows
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
  d=$(pgrep -a -u "$(id -u)" -x Xwayland | grep -o ' :[0-9]*' | head -1 | tr -d ' ' || true)
  [ -n "$d" ] && export DISPLAY=$d
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

# Có cửa sổ trình duyệt của Hermes ở workspace 9 thì in địa chỉ.
chrome_addr() {
  desktop_json | python3 -c '
import json, sys
for w in json.load(sys.stdin)["result"]["windows"]:
    if w["class"] == sys.argv[1] and str(w["workspace"]) == sys.argv[2]:
        print(w["address"]); break' "$CLASS" "$WS"
}

win() {
  local addr
  addr=$(chrome_addr)
  if [ -z "$addr" ]; then
    hypruse launch --workspace "$WS" --wait 25 -- google-chrome-stable "${CHROME_FLAGS[@]}" --new-window https://www.tiktok.com/ >/dev/null || true
    addr=$(chrome_addr)
  fi
  echo "$addr"
}

title() {
  desktop_json | python3 -c '
import json, sys
for w in json.load(sys.stdin)["result"]["windows"]:
    if w["class"] == sys.argv[1] and str(w["workspace"]) == sys.argv[2]:
        print(w["title"].removesuffix(" - Google Chrome")); break' "$CLASS" "$WS"
}

# Thoát mã 5 nếu chưa có cửa sổ trình duyệt của Hermes ở workspace 9 (chưa gọi "start").
need_ready() {
  [ -n "$(chrome_addr)" ] || { echo "tnb: chưa có Chrome ở workspace $WS, chạy: tnb.sh start" >&2; exit 5; }
}

# Các nút tên đúng NAME, mỗi dòng "x y", bỏ nút của thanh công cụ trình duyệt (y < 90).
buttons() {
  hypruse ui --window "$1" --name "$2" --json | python3 -c '
import json, sys
for e in (lambda r: r if isinstance(r, list) else [])(json.load(sys.stdin)["result"]):
    if e.get("role") == "button" and e.get("name") == sys.argv[1] and e.get("y", 0) >= 90:
        print(e["x"], e["y"])' "$2"
}

# Chờ tối đa SECS giây (mặc định 15) tới khi có nút/link/tab tên bắt đầu bằng PREFIX, in tên đầy đủ.
wait_name() {
  local i
  for i in $(seq $(( ${3:-15} * 2 ))); do
    hypruse ui --window "$1" --name "$2" --json 2>/dev/null | python3 -c '
import json, sys
for e in (lambda r: r if isinstance(r, list) else [])(json.load(sys.stdin)["result"]):
    if e.get("y", 0) >= 90 and e.get("role") in ("button", "link", "page tab") and e.get("name", "").startswith(sys.argv[1]):
        print(e["name"]); sys.exit(0)
sys.exit(1)' "$2" && return 0
    sleep 0.5
  done
  return 1
}

# Chờ tối đa SECS giây tới khi trang có phần tử (kể cả nút bị vô hiệu hoá) tên bắt đầu bằng PREFIX.
wait_any() {
  local i
  for i in $(seq $(( $3 * 2 ))); do
    hypruse ui --window "$1" --name "$2" --all --json 2>/dev/null | python3 -c '
import json, sys
r = json.load(sys.stdin)["result"]
sys.exit(0 if any(e.get("y", 0) >= 90 and e.get("name", "").startswith(sys.argv[1]) for e in (r if isinstance(r, list) else [])) else 1)' "$2" && return 0
    sleep 0.5
  done
  return 1
}

# Mỗi lần mở URL Chrome thêm một tab ở cuối và chọn nó: đóng các tab còn lại bằng nút "Close" của từng tab
# (cửa sổ XWayland không nhận phím chạy ngầm nên không dùng được ctrl+w). Nút "Close" trên thanh tab
# (y < 60) chỉ có của tab; Chrome không vẽ nút đóng cửa sổ ở đây.
close_old_tabs() {
  local st n i
  for _ in $(seq 10); do
    # In "số_tab chỉ_số_nút_Close_của_tab_trái_nhất". Đếm tab theo phần tử "page tab" (không theo nút Close:
    # nút của tab vừa đóng còn nằm trong cây một lúc, đếm theo nó sẽ đóng nhầm tab cuối và cả cửa sổ).
    st=$(hypruse ui --window "$1" --json 2>/dev/null | python3 -c '
import json, sys
r = json.load(sys.stdin)["result"]
r = r if isinstance(r, list) else []
tabs = [e for e in r if e.get("role") == "page tab" and e.get("y", 999) < 60]
# click_ui --index đếm các phần tử trùng tên hoàn toàn và bấm được, theo thứ tự của ui.
same = [e for e in r if e.get("name") == "Close" and e.get("clickable")]
closes = [(e["x"], i) for i, e in enumerate(same) if e.get("role") == "button" and e.get("y", 999) < 60]
print(len(tabs), min(closes)[1] if closes else -1)' || echo "0 -1")
    read -r n i <<< "$st"
    [ "$n" -gt 1 ] && [ "$i" -ge 0 ] || return 0
    hypruse click_ui Close --window "$1" --index "$i" >/dev/null 2>&1 || return 0
    # Chờ số tab giảm thật rồi mới đếm lại.
    for _ in $(seq 10); do
      st=$(hypruse ui --window "$1" --json 2>/dev/null | python3 -c '
import json, sys
r = json.load(sys.stdin)["result"]
print(sum(1 for e in (r if isinstance(r, list) else []) if e.get("role") == "page tab" and e.get("y", 999) < 60))' || echo 0)
      [ "$st" -lt "$n" ] && break
      sleep 0.5
    done
  done
}

# Bấm PREFIX tới khi thấy NEXT (tối đa 3 lần): nút đôi khi chưa nhận lệnh bấm lúc trang vừa đổi.
press_until() {
  local n
  for _ in 1 2 3; do
    wait_any "$1" "$3" 1 && return 0
    n=$(wait_name "$1" "$2" 15) || { echo "failed: $4"; exit 1; }
    hypruse click_ui "$n" --window "$1" --index 0 >/dev/null || true
    # Vài nút của TikTok (như tab Collections) đôi khi bỏ qua lần bấm đầu qua accessibility: chờ rồi bấm lại.
    wait_any "$1" "$3" 15 && return 0
  done
  echo "failed: $4"; exit 1
}

# Link tác giả trong lưới collection tên "Tên hiển thị,handle": in mỗi handle một dòng.
card_handles() {
  hypruse ui --window "$1" --name "," --json | python3 -c '
import json, re, sys
for e in (lambda r: r if isinstance(r, list) else [])(json.load(sys.stdin)["result"]):
    n = e.get("name", "")
    if e.get("role") == "link" and e.get("y", 0) >= 250 and "," in n:
        h = n.rsplit(",", 1)[1]
        if re.fullmatch(r"[A-Za-z0-9._]+", h):
            print(h)'
}

# Bấm nút tên đúng NAME nằm cùng hàng y=ROW (nút trong hộp thoại), qua accessibility, không dùng chuột.
press_row() {
  local i
  i=$(hypruse ui --window "$1" --name "$2" --json | python3 -c '
import json, sys
r = json.load(sys.stdin)["result"]
# click_ui --index đếm các phần tử trùng tên hoàn toàn và bấm được, theo thứ tự của ui.
same = [e for e in (r if isinstance(r, list) else []) if e.get("name") == sys.argv[1] and e.get("clickable")]
for i, e in enumerate(same):
    if e.get("role") == "button" and (sys.argv[2] == "" or e.get("y") == int(sys.argv[2])):
        print(i); break' "$2" "${3:-}")
  [ -n "$i" ] && hypruse click_ui "$2" --window "$1" --index "$i" >/dev/null
}

# Kênh đã bị block thì nút Follow thành "Unblock <tên kênh>".
blocked() {
  hypruse ui --window "$1" --name Unblock --json | python3 -c '
import json, sys
sys.exit(0 if any(e.get("role") == "button" and e.get("name", "").startswith("Unblock")
                  for e in (lambda r: r if isinstance(r, list) else [])(json.load(sys.stdin)["result"])) else 1)'
}

case "${1:-}" in
  open|block|collection|_collection|remove) need_ready ;;
esac

case "${1:-}" in
  login)
    # User tự đăng nhập: đóng cửa sổ đang chạy ngầm ở workspace 9 rồi mở lại trên màn hình của user (không qua
    # hypruse launch), chờ tới khi user đóng trình duyệt. Không bao giờ gõ mật khẩu hộ.
    a=$(chrome_addr); [ -n "$a" ] && hypruse hypr close_window "$a" >/dev/null || true
    for _ in $(seq 20); do pgrep -f -- "--user-data-dir=$PROFILE" >/dev/null || break; sleep 0.5; done
    echo "Đăng nhập trong cửa sổ Chrome vừa mở, xong thì đóng cửa sổ đó."
    google-chrome-stable "${CHROME_FLAGS[@]}" https://www.tiktok.com/login >/dev/null 2>&1 || true
    ;;
  start)
    # Mở trình duyệt của Hermes (có cửa sổ) ở workspace 9 nếu chưa có; không đụng tới Chrome của user.
    w=$(win)
    [ -n "$w" ] || { echo "tnb: không mở được Chrome của Hermes ở workspace $WS" >&2; exit 5; }
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
    # Xong (kể cả khi lỗi hay bị ngắt) thì tắt hẳn trình duyệt của Hermes: đóng cửa sổ, chờ Chrome thoát,
    # còn tiến trình nào của profile này thì gửi TERM.
    finish() {
      trap - EXIT INT TERM HUP
      a=$(chrome_addr); [ -n "$a" ] && hypruse hypr close_window "$a" >/dev/null 2>&1 || true
      for _ in $(seq 20); do pgrep -u "$(id -u)" -f -- "--user-data-dir=$PROFILE" >/dev/null || return 0; sleep 0.5; done
      pkill -TERM -u "$(id -u)" -f -- "--user-data-dir=$PROFILE" || true
    }
    trap finish EXIT
    trap 'exit 130' INT TERM HUP
    list=$("$0" collection) || { echo "lỗi: $list"; exit 1; }
    if [ "$list" = empty ]; then echo "collection block trống, không có kênh nào để block"; exit 0; fi
    if r=$("$0" remove); then echo "đã gỡ ${r#removed } video khỏi collection block"; else echo "lỗi khi gỡ video: $r"; fi
    while read -r h; do
      r=$("$0" block "$h") || r=$("$0" block "$h") || true
      case "$r" in
        blocked) echo "@$h: đã block" ;;
        already) echo "@$h: đã block từ trước" ;;
        *) echo "@$h: lỗi: ${r#failed: }" ;;
      esac
    done <<< "$list"
    ;;
  win) win ;;
  open)
    url=${2:?url}
    w=$(win)
    old=$(title)
    # Không gõ URL: hypruse làm rơi "/", "@", "_" và ký tự cần Shift khi gõ vào Chrome.
    # Đưa URL cho Chrome đang chạy: nó mở tab mới trong cửa sổ duy nhất (ở workspace 9).
    # Lệnh phụ này giao URL cho Chrome đang chạy rồi có thể crash (trong môi trường của Hermes): chạy trong
    # subshell để bash không in thông báo "core dumped" ra output.
    ( google-chrome-stable "${CHROME_FLAGS[@]}" "$url" ) >/dev/null 2>&1 || true
    for _ in $(seq 20); do
      [ "$(title)" != "$old" ] && break
      sleep 0.5
    done
    # Trong lúc tải, tiêu đề là "TikTok - Make Your Day": chờ thêm tối đa 40 giây cho tiêu đề thật.
    for _ in $(seq 80); do
      case "$(title)" in "TikTok - Make Your Day"*) sleep 0.5 ;; *) break ;; esac
    done
    close_old_tabs "$w"
    # TikTok vẽ bản chưa đăng nhập trước rồi mới nạp phiên: chờ đủ lâu.
    sleep 6
    title
    ;;
  block)
    handle=${2:?handle}; handle=${handle#@}
    w=$(win)
    t=$("$0" open "https://www.tiktok.com/@$handle")
    # Chrome chạy ẩn tải chậm (có khi hơn 1 phút); tiêu đề và các nút đến sau nội dung: chờ thêm tối đa 90 giây.
    for _ in $(seq 180); do
      case "$t" in *"(@$handle)"*) break ;; esac
      sleep 0.5; t=$(title)
    done
    case "$t" in *"(@$handle)"*) ;; *) echo "failed: trang kênh không mở đúng ($t)"; exit 1 ;; esac
    if blocked "$w"; then echo already; exit 0; fi
    # Menu ba chấm cạnh Message/Share tên "Actions", trong đó có mục "Block".
    # Lệnh bấm qua accessibility đôi khi không mở menu: bấm lại tới khi menu có mục Block.
    press_until "$w" Actions Block "không mở được menu Actions (không có Block)"
    sleep 1
    # Bấm mục Block trong menu rồi chờ hộp thoại xác nhận (tối đa 10 giây); chưa thấy thì bấm lại, tối đa 3 lần.
    # Hộp thoại "Block <handle> (...)?" có Cancel và Block; nút Block của hộp thoại nằm cùng hàng với Cancel.
    cy=""
    for _ in 1 2 3; do
      press_row "$w" Block || true
      for _ in $(seq 10); do
        read -r _ cy < <(buttons "$w" Cancel | head -1) && break
        cy=""; sleep 1
      done
      [ -n "$cy" ] && break
      wait_any "$w" Block 1 || press_until "$w" Actions Block "không mở lại được menu Actions"
    done
    [ -n "$cy" ] || { echo "failed: không thấy hộp thoại xác nhận"; exit 1; }
    press_row "$w" Block "$cy" || { echo "failed: không thấy nút Block trong hộp thoại"; exit 1; }
    # Chờ nút Unblock tối đa 20 giây; hộp thoại còn (lần bấm không ăn) thì bấm lại nút Block của nó.
    for i in $(seq 20); do
      blocked "$w" && { echo blocked; exit 0; }
      if [ $(( i % 5 )) = 0 ] && read -r _ cy < <(buttons "$w" Cancel | head -1); then press_row "$w" Block "$cy" || true; fi
      sleep 1
    done
    echo "failed: chưa thấy nút Unblock sau khi bấm"; exit 1
    ;;
  collection)
    # Trang TikTok đôi khi bỏ qua một lệnh bấm qua accessibility: chạy lại cả quy trình tối đa 3 lần.
    for _ in 1 2 3; do
      out=$("$0" _collection) && { echo "$out"; exit 0; }
    done
    echo "$out"; exit 1
    ;;
  _collection)
    # tiktok.com → Profile (link ở sidebar) → Favorites → Collections → block,
    # rồi in handle các kênh trong collection (bỏ kênh của mình), "empty" nếu không có video.
    w=$(win)
    "$0" open https://www.tiktok.com/ >/dev/null
    # Link Profile có ở sidebar cả khi sidebar thu gọn (chỉ còn icon). Không bấm theo tên "Avatar": tên đó
    # khớp avatar của các kênh đang follow ở sidebar.
    press_until "$w" Profile "Edit profile" "bấm Profile không mở được trang của mình (chưa đăng nhập?)"
    for _ in $(seq 30); do case "$(title)" in *"(@"*) break ;; *) sleep 0.5 ;; esac; done
    me=$(title | grep -o '(@[^)]*)' | tr -d '()@' | head -1 || true)
    [ -n "$me" ] || { echo "failed: không mở được trang Profile ($(title))"; exit 1; }
    wait_name "$w" "Edit profile" 10 >/dev/null || { echo "failed: chưa đăng nhập (không có Edit profile)"; exit 1; }
    press_until "$w" Favorites Collections "không mở được tab Favorites"
    # Tab Favorites hiện "Collections 0" trong lúc còn tải: chờ số collection > 0 rồi mới bấm.
    for _ in $(seq 30); do
      case "$(wait_name "$w" Collections 1 || true)" in "Collections "[1-9]*) break ;; esac
      sleep 0.5
    done
    # Tab Collections của Chrome XWayland thường bỏ qua lệnh bấm qua accessibility (không gửi được phím Enter
    # dự phòng vì cửa sổ XWayland không nhận phím chạy ngầm): bấm 2 lần, không ăn thì mở thẳng trang collection.
    n=$(wait_name "$w" Collections 5) || { echo "failed: không thấy tab Collections"; exit 1; }
    for _ in 1 2; do
      hypruse click_ui "$n" --window "$w" --index 0 >/dev/null 2>&1 || true
      wait_any "$w" "block " 6 && break
    done
    if wait_any "$w" "block " 1; then
      press_until "$w" "block " "Manage videos" "trang collection block không mở"
    else
      "$0" open "$COLLECTION_URL" >/dev/null
      wait_any "$w" "Manage videos" 60 || { echo "failed: trang collection block không mở"; exit 1; }
    fi
    # Sidebar chiếm gần hết 60 phần tử mà hypruse ui trả về: thu gọn để thấy lưới video.
    if n=$(wait_name "$w" "Collapse sidebar" 1); then hypruse click_ui "$n" --window "$w" --index 0 >/dev/null || true; fi
    sleep 4
    # Đọc lại vài lần cho tới khi danh sách thẻ không đổi (lưới nạp dần).
    seen=""
    for _ in $(seq 6); do
      new=$(card_handles "$w" || true)
      all=$(printf '%s\n%s\n' "$seen" "$new" | awk 'NF && !s[$0]++')
      [ "$all" = "$seen" ] && [ -n "$seen" ] && break
      seen=$all
      sleep 2
    done
    list=$(printf '%s\n' "$seen" | grep -vx "$me" | grep -v '^$' || true)
    if [ -z "$list" ]; then echo empty; else echo "$list"; fi
    ;;
  remove)
    # Trên trang collection block (sau "collection"): Manage videos → Select all → Remove (N) → Remove.
    w=$(win)
    case "$(title)" in "Collection block"*) ;; *) echo "failed: không ở trang collection block ($(title))"; exit 1 ;; esac
    press_until "$w" "Manage videos" "Select all" "bấm Manage videos không vào chế độ chọn"
    press_until "$w" "Select all" "Remove (" "bấm Select all không chọn được video"
    n=$(wait_name "$w" "Remove (" 5) || { echo "failed: không thấy nút Remove (N)"; exit 1; }
    hypruse click_ui "$n" --window "$w" --index 0 >/dev/null
    # Hộp thoại "Remove N videos from block" có Cancel và Remove; nút "Remove" đúng tên chỉ có trong hộp thoại.
    sleep 1.5
    press_row "$w" Remove || { echo "failed: không thấy hộp thoại xác nhận"; exit 1; }
    sleep 3
    if hypruse ui --window "$w" --name "No videos in this collection" --all >/dev/null 2>&1; then
      echo "removed ${n//[^0-9]/}"
    else
      echo "failed: chưa thấy 'No videos in this collection' sau khi bấm"; exit 1
    fi
    ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
