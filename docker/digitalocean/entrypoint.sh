#!/bin/sh
# Entrypoint cho DigitalOcean App Platform.
#
# App Platform inject biến PORT (mặc định 8080) và chỉ route traffic vào đúng
# port đó. Langflow lại đọc port từ LANGFLOW_PORT (mặc định 7860), nên cần map
# PORT -> LANGFLOW_PORT. Nếu không map, health check fail và app restart loop.
#
# Ghi đè bằng env nếu cần: LANGFLOW_HOST, LANGFLOW_PORT, LANGFLOW_BACKEND_ONLY.
set -eu

PORT="${PORT:-8080}"
LANGFLOW_HOST="${LANGFLOW_HOST:-0.0.0.0}"
LANGFLOW_PORT="${LANGFLOW_PORT:-$PORT}"

export LANGFLOW_HOST
export LANGFLOW_PORT

# Bỏ qua arg "run" nếu App Platform / người dùng truyền run_command là
# "langflow run" (khi đó args đã nằm trong ENTRYPOINT).
if [ "${1:-}" = "run" ]; then
    shift
fi

# Chạy backend-only nếu muốn tắt UI (frontend đã nằm trên Vercel).
# Đặt LANGFLOW_BACKEND_ONLY=true trong env của App Platform.
if [ "${LANGFLOW_BACKEND_ONLY:-false}" = "true" ]; then
    exec langflow run --backend-only --host "$LANGFLOW_HOST" --port "$LANGFLOW_PORT" "$@"
fi

exec langflow run --host "$LANGFLOW_HOST" --port "$LANGFLOW_PORT" "$@"
