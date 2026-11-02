# Deploy: Vercel (frontend) + Fly.io (backend)

Kiến trúc này tách đôi Langflow:

```
Browser ──► https://langflow-ui.vercel.app   (Vercel: static Vite/React build)
                │
                └─ /api/v1/* , /api/v2/* , /health*  ──rewrite──►  https://<app>.fly.dev
                                                                    (Fly.io: FastAPI + SQLite + UI)
```

Lý do: backend Langflow (FastAPI + SQLite + hàng trăm package Python) không chạy được
trên Vercel Functions (giới hạn 250 MB, không có filesystem bền, cần WebSocket),
nên backend đặt trên Fly.io còn Vercel chỉ phục vụ build tĩnh của `src/frontend`.

> Lưu ý: image backend trên Fly **đã bao gồm UI**, nên `https://<app>.fly.dev` cũng là
> một Langflow hoàn chỉnh. Vercel là lớp UI tuỳ biến (domain riêng, CDN, cache tĩnh);
> nếu chỉ cần một bản chạy được đầy đủ thì dùng thẳng Fly là đủ.

---

## 1. Vercel (frontend)

Đã cấu hình sẵn trong repo qua `src/frontend/vercel.json`.

Nếu tạo project bằng dashboard/CLI:

| Setting | Value |
| --- | --- |
| Root Directory | `src/frontend` |
| Framework Preset | `Vite` |
| Install Command | `npm ci` |
| Build Command | `npm run build` |
| Output Directory | `build` |

`vercel.json` làm 2 việc:

1. **SPA fallback** — `/:path* → /index.html`, để F5 ở `/login`, `/flow/<id>` không bị 404.
   (Vercel luôn ưu tiên file tĩnh trong `/assets/` trước rewrite nên không ảnh hưởng asset.)
2. **Proxy API** — `/api/v1/*`, `/api/v2/*`, `/health*` → host Fly của bạn.

Đổi backend: sửa host trong `src/frontend/vercel.json` rồi commit — redeploy tự động.

---

## 2. Fly.io (backend)

### 2.1 Chuẩn bị

```bash
fly auth login
cd <repo>
```

`fly.toml` trong repo đã cấu hình: region `sin`, internal port `7860`,
VM `shared-cpu-2x / 2gb`, volume `langflow_data` mount vào `/app/data`,
health check `/health_check`.

Đổi dòng `app = "langflow-khanhxl21"` thành tên riêng của bạn (phải duy nhất toàn cầu).

### 2.2 Tạo volume (bắt buộc, làm trước khi deploy)

```bash
fly volumes create langflow_data --region sin --size 3
```

### 2.3 Deploy

```bash
fly launch --no-deploy --copy-config   # nhận fly.toml trong repo, tạo app
fly deploy
```

Hoặc nếu đã tạo app trên dashboard:

```bash
fly apps create <app-name>
fly volumes create langflow_data --region sin --size 3 -a <app-name>
fly deploy -a <app-name>
```

### 2.4 Secrets (không commit vào repo)

```bash
fly secrets set \
  LANGFLOW_AUTO_LOGIN=false \
  LANGFLOW_SUPERUSER=admin \
  LANGFLOW_SUPERUSER_PASSWORD='<mat-khau-manh>' \
  LANGFLOW_SECRET_KEY="$(openssl rand -hex 32)" \
  -a <app-name>
```

`LANGFLOW_SECRET_KEY` phải cố định giữa các lần restart, nếu không toàn bộ JWT
đã phát hành sẽ bị vô hiệu và người dùng bị đăng xuất.

### 2.5 Kiểm tra

```bash
curl https://<app-name>.fly.dev/health_check          # -> ok
curl https://<app-name>.fly.dev/api/v1/version        # -> {"version":"1.13.0", ...}
fly logs -a <app-name>
fly status -a <app-name>
```

Sau khi backend sống, cập nhật host trong `src/frontend/vercel.json` (nếu khác
`langflow-khanh21.fly.dev`) và thêm origin Vercel vào CORS:

```bash
fly secrets set LANGFLOW_CORS_ORIGINS=https://langflow-ui.vercel.app -a <app-name>
```

### 2.6 Tuỳ chọn: dùng Postgres của Fly thay SQLite

```bash
fly postgres create --name langflow-db --region sin
fly postgres attach langflow-db -a <app-name>   # tự set DATABASE_URL
fly secrets set LANGFLOW_DATABASE_URL="<DATABASE_URL đã đổi scheme postgresql://>" -a <app-name>
```

Sau đó có thể bỏ `[[mounts]]` nếu không cần lưu file upload.

---

## 3. Nếu dùng "Launch from GitHub" trên dashboard Fly

Form "Launch from GitHub" **không** tạo volume và mặc định build từ branch được chọn —
những lưu ý bắt buộc:

| Field | Lưu ý |
| --- | --- |
| Branch | Phải là nhánh **có `Dockerfile.fly` + `fly.toml`** (nhánh PR, hoặc sau khi PR đã merge vào `main`). Chọn `main` cũ khi chưa merge → build fail vì repo không có Dockerfile ở gốc |
| Region | `sin` (Singapore) ✅ |
| Internal port | `7860` (khớp `LANGFLOW_PORT` và `EXPOSE` trong `Dockerfile.fly`). Để 8080 → health check fail, app restart loop |
| CPU / Memory | `performance-8x / 16GB` tốn ~$250/tháng — cho cá nhân dùng `shared-cpu-2x / 2GB` (~$12–15/tháng) là đủ; tối thiểu 1GB RAM (256MB sẽ bị OOM kill ngay khi import component) |
| Config path | để mặc định `./` → form đọc `fly.toml` trong repo |
| Environment variables | `LANGFLOW_HOST=0.0.0.0`, `LANGFLOW_PORT=7860`, `LANGFLOW_DATABASE_URL=sqlite:////app/data/langflow.db`, `LANGFLOW_CORS_ORIGINS=<domain Vercel thật>` |
| Managed Postgres | tuỳ chọn |

Sau khi bấm **Deploy** và app được tạo, vẫn còn 2 việc form không làm:

```bash
# 1) Volume bền — nếu không có, MỌI flow sẽ mất sau mỗi lần deploy/restart
fly volumes create langflow_data --region sin --size 3 -a <app-name>

# 2) Deploy lại từ máy local (clone đúng nhánh có Dockerfile.fly) để mount volume
git clone https://github.com/khanhxl21/langflow.git && cd langflow
git checkout <nhánh-có-Dockerfile.fly>
fly deploy -a <app-name>
```

Rồi đặt secrets như bước **2.4** ở trên.

---

## 4. Giới hạn cần biết

- **WebSocket không đi qua Vercel.** Rewrite của Vercel chỉ proxy HTTP, nên chat
  streaming và log build realtime (`/api/v1/build/...`, `use-webhook-events` dùng SSE)
  có thể không hoạt động khi truy cập qua domain Vercel. Các API HTTP còn lại
  (đăng nhập, CRUD flow, chạy flow) vẫn chạy bình thường.
  Fly.io hỗ trợ WebSocket native → mở trực tiếp `https://<app>.fly.dev` khi cần streaming.
- **Cold start**: `min_machines_running = 1` giữ 1 máy luôn bật (tránh chờ ~30s khi thức).
  Đặt `0` để tiết kiệm nhưng lần truy cập đầu sẽ chậm.
- **CORS**: `LANGFLOW_CORS_ORIGINS` phải liệt kê origin cụ thể, đúng domain Vercel thật
  (ví dụ `https://langflow-ui.vercel.app`). Nếu là `*`,
  Langflow tự tắt `allow_credentials` và đăng nhập có thể lỗi.
