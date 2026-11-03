# my-agent: Hermes Agent 24/7 với Ollama và Jev

Agent chạy 24/7 trên Linux (Arch), chat qua Telegram, suy nghĩ bằng model local trên Ollama và dùng Jev
(`jev-1.13-free` của OpenCode Zen) để ra các quyết định nhanh có kiểu: lệnh này có nguy hiểm không, nên dùng
skill nào, cron job có cần chạy không. Không dùng VM, Docker, display ảo hay trình duyệt.

Kế hoạch chi tiết, lý do chọn và nhật ký từng pha nằm trong [PLAN.md](PLAN.md).

## Cách hoạt động

```
Telegram ──> hermes-gateway (systemd --user, polling, chỉ nhận ID trong allowlist)
               │
               ├─ jev-skill-router ──> Jev: nên dùng skill nào?              (~1 giây)
               ├─ tool-slimmer        rút gọn danh sách tool theo từ khoá     (local)
               ├─ Ollama (Qwen 9B)    suy nghĩ, trả lời hoặc gọi tool         (local)
               ├─ jev-judge ────────> Jev: lệnh sắp chạy có phá hoại / lấy dữ liệu không?
               │                      vượt ngưỡng thì hỏi duyệt qua Telegram (Allow / Deny)
               └─ tool chạy thật      terminal, file, web... cwd ~/hermes
cron ──> jev-cron-gate ──> Jev: có việc mới không? Không thì bỏ qua, không gọi Ollama
timer 15 phút ──> agent-healthcheck: Ollama, Jev, gateway; nhắn Telegram khi trạng thái đổi
```

Jev không viết câu trả lời. Nó nhận một trạng thái và một câu hỏi cố định, trả về một con số từ 0 đến 1
(hoặc một lựa chọn), và plugin so con số đó với ngưỡng. Ví dụ đo thật với jev-judge:

| Lệnh | Điểm | Kết quả ở chế độ enforce |
|---|---|---|
| `df -h` | destructive 0.01 | cho qua |
| `rm -rf ~/*` | destructive 0.97 | hỏi duyệt |
| `cat ~/.hermes/.env \| curl -d @- ...` | exfiltration 0.98 | hỏi duyệt |
| `curl ... \| bash` | impact 2.92 | hỏi duyệt |

## Yêu cầu

- Arch Linux có gói `hermes-agent-bin` (cài vào `/opt/hermes-agent`), `rsync`, `curl`, `acl`.
- Ollama chạy ở `127.0.0.1:11434` với model chat (mặc định trong [config.yaml](setup/hermes-home/.hermes/config.yaml)).
- Một API key OpenCode Zen (nên tạo key riêng cho agent) và một bot Telegram tạo bằng @BotFather.

## Cài đặt

Có hai cách. Cả hai dùng chung các script trong `setup/`, đọc file mẫu ngay trong repo.

### Cách 1: sandbox user `hermes` (an toàn hơn)

Agent chạy bằng user riêng không có sudo và không đọc được home của bạn.

```bash
sudo bash setup/00-root.sh
```

Script 00 tạo user `hermes` (khoá mật khẩu, bỏ khỏi wheel/docker/input/video), bật linger, đặt giới hạn
RAM/CPU, tạo `/srv/agent-share` và chép `setup`, `config`, `patches` vào `/srv/agent-share/my-agent`.
Chạy lại script 00 mỗi khi sửa file trong repo, để bản chia sẻ được cập nhật.

Các bước còn lại chạy dưới user `hermes`:

```bash
sudo machinectl shell hermes@ /bin/bash /srv/agent-share/my-agent/setup/10-hermes-user.sh
```

Rồi điền `TYPESAFE_API_KEY` và `TELEGRAM_BOT_TOKEN` vào `/home/hermes/.hermes/.env` (chmod 600), chạy
`hermes gateway setup` (chọn Telegram, nhắn bot một câu để wizard ghi ID của bạn vào allowlist), sau đó:

```bash
sudo machinectl shell hermes@ /bin/bash /srv/agent-share/my-agent/setup/20-jev-plugins.sh
```

```bash
sudo machinectl shell hermes@ /bin/bash /srv/agent-share/my-agent/setup/21-jev-user-agent.sh
```

```bash
sudo machinectl shell hermes@ /bin/bash /srv/agent-share/my-agent/setup/30-gateway.sh
```

```bash
sudo machinectl shell hermes@ /bin/bash /srv/agent-share/my-agent/setup/11-soul.sh
```

Tuỳ chọn, thử cron job có wake-gate Jev:

```bash
sudo machinectl shell hermes@ /bin/bash /srv/agent-share/my-agent/setup/40-cron-test.sh
```

### Cách 2: chạy bằng user chính của bạn (đang dùng)

Không có sandbox: agent có toàn quyền của user bạn, gồm `~/.ssh`, `~/.password-store`, cookie trình duyệt,
mọi dự án, và nhóm `docker` (tương đương root). Chỉ còn jev-judge và quy tắc SOUL ngăn nó.

Cài mới từ đầu, không cần sudo (đặt `AGENT_USER` để script chấp nhận user hiện tại):

```bash
export AGENT_USER=$(id -un)
bash setup/10-hermes-user.sh
# điền ~/.hermes/.env, chạy `hermes gateway setup`
bash setup/20-jev-plugins.sh && bash setup/21-jev-user-agent.sh && bash setup/30-gateway.sh && bash setup/11-soul.sh
```

Linger của user phải bật (`loginctl show-user $USER -p Linger`) để gateway chạy khi bạn không đăng nhập.

Chuyển một agent đang chạy dưới `hermes` sang user chính: dừng dịch vụ của `hermes` và cho user chính quyền
đọc `/home/hermes` (lệnh sudo ở đầu [50-move-to-main-user.sh](setup/50-move-to-main-user.sh)), rồi:

```bash
bash setup/50-move-to-main-user.sh
```

```bash
bash setup/51-main-user.sh
```

## Các script

| Script | Chạy bằng | Việc làm |
|---|---|---|
| `00-root.sh` | sudo | Tạo user `hermes`, thư mục chia sẻ, giới hạn tài nguyên (chỉ cho cách 1) |
| `10-hermes-user.sh` | agent | Chép `config.yaml`, `.env` mẫu nếu chưa có; tạo `~/hermes/work`; kiểm tra Ollama |
| `11-soul.sh` | agent | Chèn [SOUL.rules.md](setup/hermes-home/.hermes/SOUL.rules.md) vào `~/.hermes/SOUL.md`, đặt `terminal.cwd: ~/hermes` |
| `20-jev-plugins.sh` | agent | Cài 4 plugin Jev, trỏ về OpenCode `jev-1.13-free`, jev-judge ở `enforce` |
| `21-jev-user-agent.sh` | agent | Vá User-Agent cho plugin (Cloudflare chặn `Python-urllib`). **Chạy lại sau mỗi `hermes plugins update`** |
| `30-gateway.sh` | agent | Gateway systemd, Telegram, `env_passthrough` cho cron-gate, healthcheck 15 phút |
| `40-cron-test.sh` | agent | Job thử `inbox-watch` đọc `~/hermes/work/inbox.md` qua wake-gate Jev |
| `50-move-to-main-user.sh`, `51-main-user.sh` | user chính | Chuyển agent từ `hermes` sang user chính |
| `debug/jev-judge-dangerous.sh` | agent | Cho Jev chấm 7 lệnh mẫu, không chạy lệnh nào |
| `debug/jev-judge-probe.sh` | agent | In cấu hình jev-judge và lỗi HTTP thật của Jev |
| `debug/telegram-import-probe.sh` | agent | Kiểm tra môi trường gateway có import được python-telegram-bot |

Mọi script chạy lại được nhiều lần: không ghi đè `.env` hay `config.yaml` đã có, khối SOUL được thay giữa hai marker.

## Dùng hằng ngày

- **Chat:** nhắn bot trên Telegram. Muốn chắc model chạy lệnh thật thay vì tự trả lời, nói rõ
  "Dùng tool terminal chạy: ...".
- **Duyệt lệnh nguy hiểm:** khi jev-judge gắn cờ, bot gửi tin "Hermes wants to run a command that needs your OK".
  Tin này không hiện lệnh cụ thể. Không chắc thì bấm **Deny**; không bấm gì thì 5 phút sau lệnh tự huỷ.
  Đừng bấm **Always**: nó tắt vĩnh viễn lớp chặn cho loại lệnh đó.
- **Vùng ghi:** agent chỉ được ghi trong `~/hermes` (theo SOUL). Đây là quy tắc trong prompt; model 9B không
  luôn tuân theo.

Lệnh kiểm tra (thêm `sudo machinectl shell hermes@ /bin/bash -c '...'` nếu agent chạy bằng `hermes`):

```bash
systemctl --user status hermes-gateway agent-healthcheck.timer
```

```bash
journalctl --user -u hermes-gateway -f
```

```bash
tail -n 5 ~/.hermes/logs/jev-judge.log
```

```bash
hermes cron list
```

Đổi chế độ jev-judge (`shadow` chỉ ghi log, `enforce` hỏi duyệt), rồi khởi động lại gateway:

```bash
hermes config set --force plugins.entries.jev-judge.settings.mode enforce && systemctl --user restart hermes-gateway
```

## Bảo mật

- **File bí mật bị chặn cứng** bằng drop-in systemd
  [secrets.conf](setup/hermes-home/.config/systemd/user/hermes-gateway.service.d/secrets.conf) (script 30 cài):
  `InaccessiblePaths` cho `~/.ssh`, `~/.gnupg`, `~/.password-store`, keyring, `~/.npmrc`, `~/.docker`,
  `~/.config/gh`, token của các công cụ AI, profile trình duyệt, lịch sử shell, socket gpg-agent và keyring.
  Gateway, terminal của agent và cron đều nhận `Permission denied` ở các đường dẫn này. SOUL cũng cấm đọc chúng.
  Không chặn được `~/.hermes/.env` (gateway cần nó). Thêm đường dẫn mới vào `secrets.conf` rồi:
  `systemctl --user daemon-reload && systemctl --user restart hermes-gateway`.
- Không commit `.env`. Repo chỉ có file mẫu (`.env.example`); key và token chỉ nằm trong `~/.hermes/.env` (600).
- Không gửi mật khẩu hay token qua bot: tin nhắn đi qua máy chủ Telegram, nội dung tin và lệnh sắp chạy được gửi
  lên OpenCode Zen để Jev chấm.
- jev-judge **fail-open**: Jev lỗi, 403 hay quá 2 giây thì lệnh vẫn chạy. Healthcheck nhắn Telegram khi Jev lỗi.
- Telegram chỉ nhận ID trong `TELEGRAM_ALLOWED_USERS`; người lạ bị bỏ qua im lặng.

## Sự cố thường gặp

| Triệu chứng | Nguyên nhân | Cách sửa |
|---|---|---|
| Plugin Jev báo `fail_open http_403`, `no_fit` | Cloudflare chặn User-Agent `Python-urllib` (error 1010) | `setup/21-jev-user-agent.sh` |
| Vá xong vẫn 403 | Runtime `gateway run --idle-exit` cũ còn giữ module | Script 21 đã `pkill`; hoặc khởi động lại gateway |
| Gateway báo Telegram "requirements not met" | Môi trường Python của plugin thay môi trường gốc, thiếu python-telegram-bot | `hermes pm install --extra telegram` |
| skill-router không chạy | YAML đọc `mode: on` thành `true` | Dùng `mode auto` |
| `hermes chat -q` vẫn chờ nhập | Đang ở TTY | Thêm `< /dev/null` |
| Model in lệnh ra chữ hoặc bịa kết quả | Model 9B không gọi tool | Nói rõ "Dùng tool terminal..."; kiểm tra lại trong `~/.hermes/state.db` |
