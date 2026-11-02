# Deploy: Vercel (frontend) + DigitalOcean App Platform (backend)

Tài liệu này song song với [`deploy/vercel-fly.md`](../vercel-fly.md) — cùng kiến trúc,
nhưng backend đặt trên **DigitalOcean App Platform** thay vì Fly.io.

```
Browser ──► https://langflow-ui.vercel.app      (Vercel: static Vite/React build)
                │
                └─ /api/v1/* , /api/v2/* , /health*  ──rewrite──►  https://<app>.ondigitalocean.app
                                                                   (DO App Platform: FastAPI + SQLite)
```

Backend Langflow (FastAPI + SQLite + hàng trăm package Python) không chạy được trên
Vercel Functions (giới hạn size, không có filesystem bền, cần WebSocket), nên backend
đặt trên DO và Vercel chỉ phục vụ build tĩnh của `src/frontend`.

> Image backend chạy trên DO **đã bao gồm sẵn UI**, nên `https://<app>.ondigitalocean.app`
> cũng là một Langflow hoàn chỉnh. Vercel là lớp UI tuỳ biến (domain riêng, CDN);
> nếu chỉ cần một bản chạy được đầy đủ thì dùng thẳng domain DO là đủ.

---

## ⚠️ Đọc trước: SQLite trên App Platform

Bạn chọn SQLite, và cần biết rõ hệ quả:

| | |
| --- | --- |
| **Container là ephemeral** | App Platform **không có persistent volume**. Mỗi lần deploy, rebuild, restart do crash hay scale → container mới → **toàn bộ flow/user/mất sạch** |
| **Luôn giữ `instance_count: 1`** | SQLite nằm trong container. 2 instance = 2 DB tách biệt → đăng nhập chập chờn, flow lúc có lúc mất |
| **Không backup** | Không có snapshot như Droplet volume |

→ SQLite chỉ phù hợp để demo. Khi cần giữ data: xem
[§6 Nâng cấp lên Managed Postgres](#6-nâng-cấp-lên-managed-postgres) (đổi 1 biến env, ~$15/tháng).

---

## 1. Chuẩn bị

```bash
# 1) Cài doctl (CLI của DigitalOcean)
#    macOS:  brew install doctl
#    Linux:  https://docs.digitalocean.com/reference/doctl/how-to/install/

# 2) Tạo Personal Access Token (read + write) tại
#    https://cloud.digitalocean.com/account/api/tokens
doctl auth init

# 3) Sinh secret key (ký JWT — sinh 1 lần, giữ cố định)
openssl rand -hex 32
```

## 2. Điền secrets vào app spec

Mở `.do/app.yaml`, thay 2 placeholder:

```yaml
- key: LANGFLOW_SUPERUSER_PASSWORD
  value: <mật khẩu mạnh của bạn>
- key: LANGFLOW_SECRET_KEY
  value: <kết quả của openssl rand -hex 32>
```

Rồi khởi tạo thư mục `data` không cần làm gì — image đã tạo sẵn `/app/data`
thuộc `user` (uid 1000), và `LANGFLOW_DATABASE_URL` trỏ vào đó.

## 3. Deploy bằng `doctl` (khuyến nghị)

```bash
cd <repo>

# Lần đầu — tạo app
doctl apps create --spec .do/app.yaml

# Các lần sau — cập nhật
doctl apps list                       # lấy APP_ID
doctl apps update "$APP_ID" --spec .do/app.yaml

# Hoặc dùng helper (tự tạo nếu chưa có, tự update nếu đã có):
bash deploy/digitalocean/deploy.sh
```

`doctl apps create` sẽ in ra App ID và URL dạng
`https://langflow-khanhxl21-<hash>.ondigitalocean.app`.

### Build từ repo thay vì image có sẵn

```bash
doctl apps create --spec .do/app.from-source.yaml
```

Spec này clone branch `main` và build `docker/digitalocean/Dockerfile`
(bọc image chính thức + entrypoint map `PORT` → `LANGFLOW_PORT`, ~1-2 phút).
Đang theo dõi `main`, nên muốn deploy code mới thì chỉ cần merge PR rồi
`doctl apps update "$APP_ID" --spec .do/app.from-source.yaml`.

## 4. Deploy bằng dashboard (không dùng CLI)

`https://cloud.digitalocean.com/apps/new` → chọn **GitHub** → repo `khanhxl21/langflow`,
branch hiện tại → **Edit Plan** → các field quan trọng:

| Field | Value | Tại sao |
| --- | --- | --- |
| Resource type | **Web Service** (Docker Hub) | Không autodetect được — repo không có `Dockerfile` ở gốc |
| Image | `langflowai/langflow:1.13.0` | Image chính thức |
| Region | **Bangalore (blr)** | Gần VN nhất |
| HTTP Port | **8080** | ⚠️ Để 7860 (mặc định của Langflow) → health check fail, restart loop |
| Instance size | **professional-s** (~2 GB RAM) | Langflow cần ≥1 GB; 512 MB OOM khi import component |
| Instance count | **1** | Bắt buộc với SQLite |
| Health check path | `/health_check` | Endpoint có sẵn trong `src/backend/base/langflow/api/health_check_router.py` |

Environment variables (tab **Environment**):

```
LANGFLOW_HOST                  = 0.0.0.0
LANGFLOW_PORT                  = 8080
LANGFLOW_LOG_LEVEL             = INFO
LANGFLOW_AUTO_LOGIN            = false
LANGFLOW_SUPERUSER             = admin
LANGFLOW_SUPERUSER_PASSWORD    = <mật khẩu mạnh>     (Encrypt ✓)
LANGFLOW_SECRET_KEY            = <openssl rand -hex 32> (Encrypt ✓)
LANGFLOW_DATABASE_URL          = sqlite:////app/data/langflow.db
LANGFLOW_SAVE_DB_IN_CONFIG_DIR = false
LANGFLOW_CORS_ORIGINS          = https://langflow-ui.vercel.app
```

## 5. Kiểm tra

```bash
APP=https://langflow-khanhxl21-<hash>.ondigitalocean.app

curl -s  "$APP/health"         # -> ok
curl -s  "$APP/health_check"   # -> {"status":"ok","chat":"ok","db":"ok"}
curl -s  "$APP/api/v1/version" # -> {"version":"1.13.0", ...}

doctl apps list
doctl apps logs "$APP_ID" --follow     # xem log realtime
doctl apps get "$APP_ID"               # trạng thái deployment
```

Nếu deployment bị đánh dấu fail dù app vẫn sống: Langflow khởi động chậm → tăng
`initial_delay_seconds` trong `.do/app.yaml` (đang để 180).

## 6. Nâng cấp lên Managed Postgres

```bash
# 1. Tạo DB (mất vài phút)
doctl databases create langflow-db \
  --engine pg --version 16 --region blr1 --size db-s-1vcpu-1gb
```

Rồi trong `.do/app.yaml`: bỏ comment khối `databases:` ở cuối file, và đổi:

```yaml
- key: LANGFLOW_DATABASE_URL
  scope: RUN_TIME
  value: ${langflow-db.DATABASE_URL}
```

Scheme của DO là `postgres://`, Langflow cần `postgresql+psycopg://`. Nếu gặp lỗi
driver, đặt trực tiếp connection string đã sửa scheme:

```bash
doctl apps update "$APP_ID" --spec .do/app.yaml
```

Sau khi chuyển sang Postgres có thể tăng `instance_count` lên >1.

## 7. Nối frontend Vercel vào backend DO

Domain DO có dạng `https://<app>-<hash>.ondigitalocean.app` — chỉ biết sau khi tạo app.

1. Copy file mẫu (đã trỏ sẵn `/api/v1`, `/api/v2`, `/health*` + SPA fallback):

   ```bash
   cp src/frontend/vercel.do.json src/frontend/vercel.json
   ```

2. Thay `REPLACE_WITH_DO_HOST` bằng host thật (không kèm `https://`):

   ```bash
   sed -i "s/REPLACE_WITH_DO_HOST/langflow-khanhxl21-xxxxx.ondigitalocean.app/g" \
     src/frontend/vercel.json
   ```

3. Commit → Vercel tự redeploy.

4. Thêm origin Vercel vào CORS của backend (nếu chưa có trong app spec):

   ```bash
   doctl apps update "$APP_ID" --spec .do/app.yaml
   ```

**Quay lại Fly.io** (đang chạy ở `langflow-khanhxl21.fly.dev`): thay host trong
`src/frontend/vercel.json` bằng `langflow-khanhxl21.fly.dev` rồi commit.
`git diff HEAD~1 -- src/frontend/vercel.json` sẽ cho bản cũ nếu cần.

## 8. Giới hạn cần biết

- **WebSocket không đi qua Vercel.** Rewrite của Vercel chỉ proxy HTTP, nên chat
  streaming và build log realtime (`/api/v1/build/...` dùng SSE) có thể không chạy
  qua domain Vercel. Các API HTTP (đăng nhập, CRUD flow, chạy flow) vẫn bình thường.
  → Mở trực tiếp `https://<app>.ondigitalocean.app` (image có sẵn UI) khi cần streaming.
- **CORS**: `LANGFLOW_CORS_ORIGINS` phải là origin cụ thể. Nếu để `*`, Langflow tự
  tắt `allow_credentials` → đăng nhập lỗi.
- **Cold start**: App Platform luôn giữ instance chạy (không scale-to-zero ở plan này),
  nhưng lần deploy đầu mất vài phút để pull image + migrate DB.
- **Chi phí tham khảo**: service `professional-s` ~$24/tháng; Managed Postgres
  `db-s-1vcpu-1gb` ~$15/tháng. Kiểm tra lại trên
  <https://www.digitalocean.com/pricing/app-platform>.
