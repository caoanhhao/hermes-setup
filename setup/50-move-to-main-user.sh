#!/usr/bin/env bash
# Chuyển agent từ user hermes sang user chính của bạn (BỎ sandbox). Chạy bằng user chính, KHÔNG sudo:
#   bash setup/50-move-to-main-user.sh
# Cần trước (một lần, có sudo): dừng dịch vụ của hermes và cho user chính quyền ĐỌC /home/hermes:
#   sudo bash -c 'systemctl --user -M hermes@ disable --now hermes-gateway.service agent-healthcheck.timer; \
#     pkill -u hermes -f hermes_cli; loginctl disable-linger hermes; setfacl -R -m u:<user>:rX /home/hermes'
# Script chép ~/.hermes, ~/hermes sang home của bạn, ~/work vào ~/hermes/work và đổi đường dẫn /home/hermes trong file cấu hình.
# ~/.hermes cũ của bạn được đổi tên thành .hermes.bak-<giờ>. Dữ liệu của user hermes giữ nguyên.
# Bước tiếp theo:  bash setup/51-main-user.sh
set -euo pipefail

OLD_HOME=/home/hermes
NEW_HOME=$HOME
step() { printf '\n==> %s\n' "$*"; }

[[ $(id -un) != hermes && $EUID != 0 ]] || { echo "Chạy bằng user chính của bạn, không sudo" >&2; exit 1; }
[[ -r $OLD_HOME/.hermes/config.yaml ]] || { echo "Chưa đọc được $OLD_HOME/.hermes: chạy lệnh sudo ở đầu file trước" >&2; exit 1; }
if pgrep -u hermes -f hermes_cli >/dev/null; then
  echo "Gateway của hermes còn chạy: hai bot cùng nhận tin Telegram sẽ xung đột. Dừng nó trước." >&2; exit 1
fi

step "Giữ lại ~/.hermes cũ"
if [[ -e $NEW_HOME/.hermes ]]; then
  bak=$NEW_HOME/.hermes.bak-$(date +%Y%m%d-%H%M%S)
  mv "$NEW_HOME/.hermes" "$bak" && echo "  đã đổi tên thành $bak"
fi

step "Chép dữ liệu agent"
rsync -a --no-acls --chmod=u+w "$OLD_HOME/.hermes/" "$NEW_HOME/.hermes/"
chmod 700 "$NEW_HOME/.hermes"
for pair in hermes:hermes work:hermes/work; do   # ~/work cũ nằm trong ~/hermes/work, vùng được ghi
  from=${pair%%:*} to=${pair#*:}
  if [[ -e $NEW_HOME/$to ]]; then
    echo "  giữ nguyên ~/$to (đã có, không chép đè)"
  elif [[ -d $OLD_HOME/$from ]]; then
    rsync -a --no-acls --chmod=u+w "$OLD_HOME/$from/" "$NEW_HOME/$to/" && echo "  đã chép ~/$from -> ~/$to"
  fi
done

step "Đổi đường dẫn $OLD_HOME thành $NEW_HOME trong file cấu hình"
find "$NEW_HOME/.hermes" -name __pycache__ -type d -prune -exec rm -rf {} +   # .pyc chứa đường dẫn cũ, Python tự tạo lại
grep -rlaF --exclude-dir=logs --exclude-dir=sessions --exclude='*.db*' -- "$OLD_HOME" "$NEW_HOME/.hermes" \
  | while read -r f; do
      if file -b --mime-encoding "$f" | grep -q binary; then echo "  bỏ qua file nhị phân: $f"
      else sed -i "s#$OLD_HOME#$NEW_HOME#g" "$f" && echo "  $f"; fi
    done

step "Đổi khoá thư mục nguồn plugin trong môi trường Python"
# pm đặt tên plugin-sources/<plugin>-<sha256(đường dẫn plugin)[:16]>; đường dẫn đổi thì khoá đổi, lock cũ hết khớp
for plugin_dir in "$NEW_HOME"/.hermes/plugins/*/; do
  name=$(basename "$plugin_dir")
  old_key=$name-$(printf '%s' "$OLD_HOME/.hermes/plugins/$name" | sha256sum | cut -c1-16)
  new_key=$name-$(printf '%s' "$NEW_HOME/.hermes/plugins/$name" | sha256sum | cut -c1-16)
  grep -rlaF -- "$old_key" "$NEW_HOME/.hermes/installs" 2>/dev/null | while read -r f; do
    file -b --mime-encoding "$f" | grep -q binary || sed -i "s#$old_key#$new_key#g" "$f"
  done
  find "$NEW_HOME/.hermes/installs" -depth -type d -name "$old_key" -execdir mv {} "$new_key" \; 2>/dev/null
done
echo "  xong"
