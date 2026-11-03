# Kế hoạch: Hermes Agent 24/7 (Ollama local + Jev qua OpenCode) trong user sandbox

Ngày: 2026-11-03 · Máy: Arch Linux, Hyprland (Wayland), RTX 4070 12 GB, 32 GB RAM, 24 core.

## 1. Mục tiêu và ràng buộc

| # | Yêu cầu | Cách đáp ứng |
|---|---|---|
| 1 | Decision model kiểu Jev | Plugin Hermes gắn vào hook, gọi **`jev-1.13-free` qua OpenCode Zen** |
| 2 | Model local | Ollama (đang chạy dạng system service) |
| 3 | Điều khiển máy, không giành chuột/phím | **Tạm tắt.** Không dùng display riêng (Xvfb/openbox/x11vnc) hay Chromium. Agent chỉ dùng terminal, file và HTTP. Xem mục 5 |
| — | Agent | **Hermes Agent** |
| — | Sandbox | **User Linux riêng `hermes`, không sudo**. Không dùng máy ảo, không dùng Docker |

## 2. Sandbox: user `hermes`

### 2.1 Ranh giới cách ly (đã kiểm tra trên máy ngày 2026-11-03)

| Tài nguyên | Hiện trạng | `hermes` có chạm được không |
|---|---|---|
| `/home/<user-chính>` | `drwx------` | Không |
| Wayland/Hyprland của bạn (`/run/user/1000`) | 0700 | **Không**, nên không thể đụng chuột, phím hay cửa sổ của bạn |
| `/dev/uinput` | `root:input 0660` | Không, nếu `hermes` không ở nhóm `input` |
| Docker | nhóm `docker` tương đương root | **Không được** thêm `hermes` vào nhóm `docker` |
| GPU `/dev/nvidia*` | `0666` | Có (không cần cho agent, chat model chạy trong Ollama system service) |
| Ollama `:11434` | đang lắng nghe `*:11434`, **mở ra cả LAN** | Có qua `127.0.0.1`. **Cần đổi sang chỉ localhost** |
| `/home/wineuser` | `drwxrwxrwx` | **Có, ghi được.** Nên `chmod 750` nếu không cố ý để mở |

Nguyên tắc: `hermes` **không thuộc** các nhóm `wheel`, `docker`, `input`, `video`, `wineuser`.
Mọi thao tác cần root đều do bạn (user chính) chạy một lần lúc setup.

### 2.2 Tạo user (bạn chạy, cần sudo)

```bash
sudo useradd -m -s /bin/bash hermes
sudo passwd -l hermes                       # khoá đăng nhập bằng mật khẩu, chỉ vào qua sudo -iu hermes / machinectl
sudo loginctl enable-linger hermes          # systemd --user của hermes chạy 24/7, không cần đăng nhập
sudo groupadd agentshare && sudo usermod -aG agentshare hermes && sudo usermod -aG agentshare "$USER"
sudo install -d -o hermes -g agentshare -m 2770 /srv/agent-share   # thư mục trao đổi file duy nhất
```

Giới hạn tài nguyên (khuyến nghị):

```bash
sudo systemctl set-property user-$(id -u hermes).slice MemoryMax=16G CPUQuota=1600%
```

Tuỳ chọn: chặn mạng ra ngoài theo UID bằng nftables (`meta skuid hermes`), chỉ cho phép
`127.0.0.1`, `api.typesafe.ai`, `api.telegram.org` và các domain bạn duyệt.

### 2.2a Vùng ghi: chỉ `~/hermes` (quy tắc SOUL)

`setup/11-soul.sh` chèn `setup/hermes-home/.hermes/SOUL.rules.md` vào `~/.hermes/SOUL.md` (giữa hai marker,
chạy lại thì thay khối cũ) và đặt `terminal.cwd: ~/hermes`. Agent chỉ được tạo, sửa, xoá file trong
`~/hermes` (gồm `~/hermes/work`, nơi có `inbox.md`); `~/.hermes` và phần còn lại chỉ đọc. Tool tự quản lý state (`memory`, `cronjob`,
`todo`, `skills`) vẫn được dùng. Đây là quy tắc trong prompt: model 9B có thể không tuân. Từ 2026-11-03 agent
chạy bằng user chính (mục 2.2b), nên ngoài quy tắc này chỉ còn jev-judge enforce chặn lệnh phá hoại hay lấy dữ liệu.

### 2.2d Bỏ key khỏi môi trường terminal (2026-11-03)

Thử qua Telegram: model vẫn chạy `printenv` dù SOUL cấm. Hermes che `TYPESAFE_API_KEY` thành `***` ở chỗ hiển thị,
nhưng biến vẫn có trong môi trường con (`echo $TYPESAFE_API_KEY | base64` lấy được). Hermes chỉ tự bỏ các tên nó
biết (`TELEGRAM_BOT_TOKEN`, `GH_TOKEN`...) và tên do plugin khai báo qua `TerminalEnvironmentProvider.strip_env_keys`.
Lần đầu thử plugin khai báo `TerminalEnvironmentProvider.strip_env_keys`: chỉ có tác dụng cho lệnh nền/PTY
(`_sanitize_subprocess_env`), vì lệnh thường đi qua `_make_run_env` với danh sách plugin rỗng; Telegram vẫn thấy key.
Cách đang dùng: manifest `~/.hermes/plugins/platforms/secret-env-strip/plugin.yaml` (`kind: platform`, không code, không
bật) khai báo `TYPESAFE_API_KEY`, `OPENCODE_API_KEY` là `secret: true` trong `optional_env`. Hermes đọc secret env của mọi
manifest platform ở mỗi lần tạo tiến trình con. Đã kiểm tra: `_make_run_env` và `_sanitize_subprocess_env` đều bỏ hai key
và token Telegram, giữ `TYPESAFE_BASE_URL`/`TYPESAFE_MODEL`; bỏ manifest đi thì `_make_run_env` lại còn key.
Skill-router vẫn gợi ý được, healthcheck OK.

Lỗi gặp khi bật plugin sau lúc chuyển user: pm đặt tên `plugin-sources/<plugin>-<sha256(đường dẫn plugin)[:16]>`,
nên lock chép từ `/home/hermes` trỏ tới khoá cũ (`tool-slimmer-dff15d01…` thay vì `…5fc56851…`) và `uv lock` báo
"Distribution not found". Script 50 giờ tính lại khoá cho mọi plugin và đổi tên trong lock lẫn thư mục.

### 2.2c Chặn cứng file bí mật (2026-11-03)

SOUL có mục "Secrets: never read", nhưng model 9B không luôn tuân, nên `setup/30-gateway.sh` cài drop-in
`hermes-gateway.service.d/secrets.conf` với `InaccessiblePaths` (SSH/GPG key, pass, keyring, token npm/docker/gh/AI CLI,
profile trình duyệt, lịch sử shell, socket gpg-agent/keyring, `/run/docker.sock` nếu có lúc khởi động).
Đã kiểm tra bằng `nsenter` vào namespace của gateway: `~/.ssh`, `~/.npmrc`, `~/.password-store` trả `Permission denied`,
`~/hermes` và `~/.hermes` vẫn đọc được, Telegram vẫn kết nối. Giới hạn: không chặn `~/.hermes/.env`; `hermes` CLI
chạy tay ngoài service không bị chặn; docker khởi động sau gateway thì socket không bị che (nhóm `docker` = root).

### 2.2b Chuyển sang chạy bằng user chính (2026-11-03): BỎ sandbox

Theo lựa chọn của bạn, gateway, healthcheck, plugin và dữ liệu agent chuyển từ `hermes` sang user chính:
1. Một lệnh sudo: `systemctl --user -M hermes@ disable --now hermes-gateway.service agent-healthcheck.timer`,
   `pkill -u hermes -f hermes_cli`, `loginctl disable-linger hermes`, `setfacl -R -m u:<user-chính>:rX /home/hermes`.
2. `setup/50-move-to-main-user.sh` (không sudo): đổi tên `~/.hermes` cũ thành `.hermes.bak-<giờ>`, chép
   `~/.hermes`, `~/hermes`, `~/work` (vào `~/hermes/work`), xoá `__pycache__`, đổi `/home/hermes` thành home mới trong mọi file văn bản
   (kể cả `.pth` của môi trường Python trong `installs/`).
3. `setup/51-main-user.sh`: chạy script 30, 21, 11 với `AGENT_USER=$(id -un)`. Script 30 bỏ qua
   `hermes pm install --extra telegram` khi môi trường đang dùng đã import được `telegram`, vì dựng môi trường
   mới sau khi chép bị lỗi ở plugin tool-slimmer (`plugin-sources` không tìm thấy).

Kết quả: gateway chạy bằng user chính, Telegram polling kết nối, healthcheck OK, jev-judge `enforce`, skill-router
gợi ý `github`. User `hermes` và dữ liệu của nó giữ nguyên để quay lại (bật lại service và linger của nó, tắt
service của user chính). Hệ quả: agent có toàn quyền của user chính (`~/.ssh`, `~/.password-store`, cookie trình duyệt,
dự án), nhóm `docker` tương đương root, nhóm `input` đọc và giả lập được bàn phím, chuột.

### 2.3 Ollama

Bạn giữ `OLLAMA_HOST=0.0.0.0:11434` (trong `override.conf` của bạn), nên script 00 không đổi cấu hình Ollama.
`hermes` gọi Ollama qua `127.0.0.1`. API Ollama không có xác thực, nên `hermes`, cũng như mọi máy trong LAN,
pull hoặc xoá được model.

## 3. Model

### 3.1 Chat model (Ollama)

- Model `saluki*` hiện có là 26.9B **IQ2_XS**, ctx 100k–260k. Tool calling kém ổn định và tràn VRAM, không hợp chạy 24/7.
- **Đang dùng:** `Qwen3.5-9B-DeepSeek-V4-Flash-GGUF-50k` (9B Q4_K_M, ctx 50000). Bạn chọn ngày 2026-11-03; model chiếm khoảng 6.3 GB, chạy 100% trên GPU. Request đầu tiên mất 5.1s với prompt khoảng 8.7k token.
  Benchmark tool-calling trước khi chạy thật.
- `OLLAMA_KEEP_ALIVE=-1` để model luôn nạp sẵn.

### 3.2 Decision model: `jev-1.13-free` qua OpenCode Zen

Theo docs OpenCode Zen:

| | Giá trị |
|---|---|
| Endpoint | `POST https://opencode.ai/zen/v1/systemone` (cùng định dạng System One của TypeSafe). **Bạn đã test được ngày 2026-11-03** với `choice` + `score`. Lưu ý: docs Zen ghi `/inference/systemone/v1/systemone`, nhưng endpoint thật là `/zen/v1/systemone` |
| Auth | `Authorization: Bearer $OPENCODE_API_KEY` |
| Model | `jev-1.13-free` (miễn phí, "for a limited time"). Bản trả phí `jev-1.13` giá $0.042/1M input |
| Primitive Zen ghi | `noul`, `choice`, `score`. **Chưa thấy ghi `box`/ảnh**, nên coi như không có |

- Toàn bộ VRAM 12 GB dành cho chat model Ollama.
- Còn độ trễ mạng. Plugin hook (mục 4) đã bỏ được phần chậm chính là các lượt LLM mà MCP gây ra,
  nhưng vẫn phải đo RTT tới opencode.ai ở pha 2.
- Bản free không ghi hạn mức hay ngày kết thúc. Nếu hết free thì đổi `jev-1.13-free` thành `jev-1.13` ở một chỗ (mục 4).
- Docs Zen không nói rõ chính sách dữ liệu của Jev free. Không gửi secret vào `state`. jev-judge đã redact và cap 600 ký tự mỗi arg.

Key lưu trong `~hermes/.hermes/.env` (quyền 600). Các plugin đọc biến `TYPESAFE_API_KEY`, nên đặt
`TYPESAFE_API_KEY=<OpenCode API key>`. Nên dùng một key OpenCode **riêng cho agent** để thu hồi được độc lập.

## 4. Jev trong Hermes: plugin + hook (không dùng MCP)

MCP chậm vì LLM phải tự quyết định gọi tool Jev, rồi đọc lại kết quả. Mỗi lần như vậy tốn thêm khoảng 2 lượt LLM.
Plugin Hermes chạy **trong tiến trình** và gọi decision model **tự động tại hook**, không cần LLM tham gia.

Plugin chọn từ catalog chính thức `NousResearch/hermes-agent/plugin-catalog`
(tier community, có pin SHA; **đọc code trước khi enable**):

| Plugin | Hook | Việc | Cấu hình trỏ về OpenCode (đọc từ code) |
|---|---|---|---|
| **jev-judge** (DoGMaTiiC/hermes-jev) | `pre_tool_call` | Gate rủi ro cho `terminal`/`write_file`/`patch`. Shadow trước, enforce sau. Fail-open, có circuit breaker, log JSONL | `backend: typesafe` (**bắt buộc**, để không tự dùng key OpenRouter), `typesafe_base_url: https://opencode.ai/zen`, `typesafe_model: jev-1.13-free` |
| **jev-skill-router** (cùng repo) | `pre_llm_call` | Chọn đúng 1 skill trước khi gọi model | Giống jev-judge: `backend`, `typesafe_base_url`, `typesafe_model` |
| **jev-cron-gate** | wake-gate script | Bỏ qua cron run không có việc. Fail-open, bắt wake sau N lần skip | env `TYPESAFE_BASE_URL=https://opencode.ai/zen/v1/systemone`, `TYPESAFE_MODEL=jev-1.13-free` (URL **đầy đủ**) |
| **tool-slimmer** | `pre_llm_call` + `llm_request` | Rút gọn schema tool để vừa ctx 50k | `mode: jev`, `jev.base_url: https://opencode.ai/zen`, `jev.model: jev-1.13-free`, `jev.api_key_env: TYPESAFE_API_KEY` |

jev-judge, jev-skill-router và tool-slimmer tự nối thêm `/v1/systemone` vào sau base URL. Riêng cron-gate nhận URL đầy đủ.
jev-judge từ chối redirect (fail-open), nên base URL phải đúng chính xác. Endpoint đã chạy khi gọi bằng curl. Cấu hình các plugin thì **chưa test**, phải kiểm tra ở pha 4.

Không dùng: các router model/effort (vì chỉ có một Ollama local), `nerve` (quá nặng, gửi mỗi lượt ra ngoài),
và các gói `Pinutss/jev-*` (thực chất là MCP).

Cấu hình chung: timeout decision khoảng 2s (hook mặc định 30s, và `pre_tool_call` khi timeout sẽ **chặn** tool),
fail-open với gate shadow, ghi độ trễ mỗi quyết định để đo.

## 5. Computer use và duyệt web: tạm TẮT

Theo yêu cầu: **không dùng Xvfb, openbox, x11vnc hay Chromium**. User `hermes` không có display và không có trình duyệt.

- Trong `setup/hermes-home/.hermes/config.yaml`, `platform_toolsets` chỉ bật
  `web, terminal, file, skills, todo, cronjob, memory, session_search, clarify`. `browser` và `computer_use` **tắt**
  (đã kiểm tra bằng `hermes tools list`).
- `web` = tìm kiếm và lấy trang qua HTTP. Không chạy được JS, không đăng nhập hay bấm nút trên trang.
- jev-ultrafast cần một Chrome qua CDP, nên **chưa triển khai**. Patch và `.env` mẫu vẫn giữ trong repo cho sau này.

### 5.1 Nếu sau này cần GUI hoặc trình duyệt (chưa chọn)

| Phương án | Được gì | Đánh đổi |
|---|---|---|
| A. Desktop thật của bạn: cấp cho `hermes` quyền vào socket Wayland/Hyprland IPC (ACL), dùng cua-driver ở chế độ nền hoặc hypruse | Thao tác app thật, không cần thêm tiến trình nào | **Sandbox bị hở**: agent chụp được toàn màn hình và gõ phím được vào app của bạn, ví dụ terminal. Tức là mượn quyền user chính (wheel/docker), không cần sudo |
| B. Trình duyệt cloud (Browser Use Cloud / Browserbase) cho `browser` toolset và jev-ultrafast (`BU_BROWSER_ID`) | Máy không chạy trình duyệt nào | Nội dung trang và phiên duyệt nằm trên cloud, có thể tốn phí |
| C. Chromium headless bật theo yêu cầu (không chạy service, không có cửa sổ) | Chạy local, không có display | Bạn đã nói không dùng Chromium |

## 6. Chạy 24/7: systemd --user của `hermes`

Chỉ có Hermes gateway. Unit do `hermes gateway install` tự tạo, trong user manager của `hermes` (đã bật linger).
Thêm một healthcheck timer gọi Ollama `/api/tags` và một câu `noul` tới endpoint Jev. Nếu Jev lỗi thì báo qua Telegram;
các plugin vẫn fail-open nên agent không bị dừng. Nhờ linger, sau khi reboot gateway tự chạy lại.

Secret (`TYPESAFE_API_KEY` = OpenCode key, token Telegram) để trong `~hermes/.hermes/.env`, quyền 600.

## 7. Lộ trình

Triển khai: `sudo bash setup/00-root.sh` (pha 0), rồi `sudo machinectl shell hermes@ /bin/bash /srv/agent-share/my-agent/setup/10-hermes-user.sh`
(pha 3: config và `.env`). Hermes cài từ gói Arch `hermes-agent-bin` 0.22.6 (`/opt/hermes-agent`, root-owned).

| Pha | Ai chạy | Việc | Kiểm chứng |
|---|---|---|---|
| 0 | bạn (sudo) | Tạo user `hermes`, linger, `agentshare`, giới hạn slice. **Đã xong 2026-11-03** | `id hermes` chỉ có nhóm hermes và agentshare. Linger=yes. MemoryMax=16G |
| 1 | hermes | Chat model `-50k` (đã chọn), benchmark tool-calling | 20 tool call liên tiếp không lỗi format |
| 2 | hermes | Tạo key OpenCode riêng cho agent. `curl` thử `noul`/`choice`/`score` tới `opencode.ai/zen/v1/systemone` với `jev-1.13-free`. Thử thêm `box` | Trả typed answer. Đo p50/p95 RTT. Ghi lại `box` có chạy không |
| 3 | hermes | Hermes 0.22.6 (gói Arch). Chạy script 10 (config Ollama, toolsets không có browser/computer_use), chạy CLI | Agent trả lời và chạy được lệnh shell với quyền `hermes` |
| 4 | hermes | **Xong 2026-11-03** (kèm `setup/21-jev-user-agent.sh`). `setup/20-jev-plugins.sh`: cài 4 plugin theo SHA catalog (đã đọc code: không subprocess/eval, mạng chỉ tới endpoint Jev đã cấu hình), đặt settings trỏ về OpenCode `jev-1.13-free`, jev-judge ở chế độ shadow, skill-router `auto` (`on` bị YAML đọc thành `true`), tool-slimmer `keyword` (local) | `hermes plugins list` thấy cả 4 plugin đã enable. `~/.hermes/logs/jev-judge.log` có quyết định kèm độ trễ. Không có request nào đi ra openrouter.ai hay api.typesafe.ai |
| 6 | hermes | **Phần lớn xong 2026-11-03** (gateway + Telegram + healthcheck OK; cron `inbox-watch` + jev-cron-gate: inbox không có việc mới 0.03 → skip, có việc mới 0.92 → wake, Telegram nhận tin, qua `setup/40-cron-test.sh`; jev-judge chuyển sang enforce 2026-11-03 sau khi `setup/debug/jev-judge-dangerous.sh` cho thấy 5/5 lệnh nguy hiểm vượt ngưỡng, 2/2 lệnh vô hại cho qua; còn: test reboot). `setup/30-gateway.sh`: kiểm tra `TELEGRAM_BOT_TOKEN`; allowlist đặt bằng `hermes gateway setup` (tự nhận ra ID, **đã đặt 2026-11-03: chỉ ID Telegram của bạn**; người lạ bị bỏ qua im lặng), `terminal.env_passthrough` cho cron-gate, `hermes gateway install` (systemd --user), timer `agent-healthcheck` 15 phút (Ollama, Jev, gateway; chỉ nhắn Telegram khi trạng thái đổi). | Reboot xong tự chạy. Nhắn Telegram có trả lời. `/sethome` nhận kết quả cron |
| 7 | (sau) | Nếu cần GUI hoặc web: chọn A, B hoặc C ở mục 5.1, rồi mới triển khai computer_use, jev-ultrafast và grounding `box` | — |

## 8. Rủi ro

- **Môi trường Python riêng của Hermes thay hẳn venv gốc** (gặp ngày 2026-11-03): cài plugin với `--yes-deps`
  (tool-slimmer cần `pyyaml`) khiến Hermes tạo `~/.hermes/installs/…/environments/…/venv` cho user hermes. Môi trường
  này không chứa các gói optional của venv `/opt` (ví dụ `python-telegram-bot`), nên Telegram báo "requirements not met".
  Đã sửa bằng `hermes pm install --extra telegram` (không kèm `--without`, vì hai cờ không dùng chung được; nhánh `--extra`
  không cài chromium hay cua-driver), rồi restart gateway. Extra nào khác cần dùng sau này cũng phải cài như vậy.
- **Cloudflare của opencode.ai chặn User-Agent `Python-urllib`** (403, `error code: 1010`; gặp ngày 2026-11-03).
  jev-judge, jev-skill-router và jev-cron-gate dùng urllib mà không đặt UA, nên bị chặn rồi fail-open, nhìn như `no_fit`.
  Đã sửa bằng `patches/*-user-agent.patch` qua `setup/21-jev-user-agent.sh` (sau đó: `suggested: github gate=0.86, 1614ms, 2 calls`).
  **Phải chạy lại script 21 sau mỗi lần `hermes plugins update`.** Script tự dừng runtime nền `gateway run --idle-exit`, vì runtime đó giữ code plugin cũ trong bộ nhớ (gặp ngày 2026-11-03: hook vẫn 403 sau khi đã patch). tool-slimmer (tự đặt UA) và jev-ultrafast (httpx) không bị ảnh hưởng.
- **Model 9B bịa kết quả tool** (gặp ngày 2026-11-03): `search_files` trên `/home/<user-chính>` thật ra trả 0 kết quả kèm cảnh báo
  "Skipped 1 unreadable path", nhưng model lại báo có `.hermes` và `.local`. Sandbox vẫn kín (`700`, không ACL).
  Ranh giới quyền là việc của Linux, không cần prompt. Còn câu trả lời sai thì là vấn đề độ tin cậy của model:
  với việc quan trọng, đối chiếu output gốc của tool, hoặc đổi sang model lớn hơn.
- **`jev-1.13-free` chỉ free trong thời gian giới hạn**, không ghi rate limit. Khi hết free thì đổi model
  thành `jev-1.13` (trả phí). Nếu endpoint lỗi, plugin fail-open: agent vẫn chạy nhưng mất gate.
- **Dữ liệu gửi ra ngoài:** mọi `state` đều đi tới opencode.ai rồi tới TypeSafe. Chính sách dữ liệu của bản free chưa rõ.
- **Plugin cộng đồng:** Nous chỉ review bản pin SHA. Khi update phải review lại. Cấu hình trỏ về OpenCode
  mới đọc từ code, **chưa test**.
- **Cùng một máy:** user sandbox không cách ly bằng VM. Lỗ hổng kernel hoặc quyền file sai (như `/home/wineuser` 777)
  vẫn là đường thoát. Rà quyền file định kỳ.

## Nguồn

- Hermes: [plugins](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins),
  [hooks](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks),
  computer use (`website/docs/user-guide/features/computer-use.md` trong repo),
  [plugin-catalog](https://github.com/NousResearch/hermes-agent/tree/main/plugin-catalog)
- [DoGMaTiiC/hermes-jev](https://github.com/DoGMaTiiC/hermes-jev),
  [superlowburn/hermes-jev-cron-gate](https://github.com/superlowburn/hermes-jev-cron-gate),
  [aliasocracy/hermes-tool-slimmer](https://github.com/aliasocracy/hermes-tool-slimmer)
- [OpenCode Zen](https://opencode.ai/docs/zen/) · [TypeSafe System One API](https://docs.typesafe.ai/api/system-one.md)
- [cua-driver](https://github.com/trycua/cua)
- [browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast) · [browser-harness](https://github.com/browser-use/browser-harness)
