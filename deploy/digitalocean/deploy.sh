#!/usr/bin/env bash
#
# Tạo hoặc cập nhật app Langflow trên DigitalOcean App Platform từ app spec.
#
#   bash deploy/digitalocean/deploy.sh                    # dùng .do/app.yaml
#   bash deploy/digitalocean/deploy.sh .do/app.from-source.yaml
#
# Yêu cầu: doctl đã cài và đã `doctl auth init`.
set -euo pipefail

SPEC="${1:-.do/app.yaml}"

if [ ! -f "$SPEC" ]; then
    echo "Không tìm thấy spec: $SPEC" >&2
    exit 1
fi

if ! command -v doctl >/dev/null 2>&1; then
    echo "Chưa cài doctl — xem https://docs.digitalocean.com/reference/doctl/how-to/install/" >&2
    exit 1
fi

# Chặn deploy khi còn placeholder (trừ khi bạn chủ ý bỏ qua).
if grep -qE "REPLACE_WITH_(A_STRONG_PASSWORD|openssl_rand_hex_32)" "$SPEC"; then
    echo "⚠️  $SPEC vẫn còn placeholder secret." >&2
    echo "    Thay LANGFLOW_SUPERUSER_PASSWORD và LANGFLOW_SECRET_KEY trước khi deploy." >&2
    echo "    Sinh key: openssl rand -hex 32" >&2
    exit 1
fi

# Tên app khai báo trong spec.
APP_NAME="$(awk '/^name:[[:space:]]*/{print $2; exit}' "$SPEC")"
if [ -z "$APP_NAME" ]; then
    echo "Không đọc được trường 'name' trong $SPEC" >&2
    exit 1
fi

echo "==> Spec : $SPEC"
echo "==> App  : $APP_NAME"

if ! doctl auth list --format Account --no-header 2>/dev/null | grep -q .; then
    echo "Chưa xác thực doctl — chạy: doctl auth init" >&2
    exit 1
fi

EXISTING_ID="$(doctl apps list --format ID,Spec.Name --no-header 2>/dev/null \
    | awk -v n="$APP_NAME" '$2 == n {print $1; exit}')"

if [ -n "$EXISTING_ID" ]; then
    echo "==> App đã tồn tại ($EXISTING_ID) → cập nhật"
    doctl apps update "$EXISTING_ID" --spec "$SPEC"
else
    echo "==> Tạo app mới"
    doctl apps create --spec "$SPEC"
fi

echo "==> Xong. Theo dõi:"
echo "    doctl apps list"
echo "    doctl apps logs \"\$(doctl apps list --format ID,Spec.Name --no-header | awk '\$2==\"$APP_NAME\"{print \$1}')  \" --follow"
