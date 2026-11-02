# syntax=docker/dockerfile:1
# Backend Langflow cho DigitalOcean App Platform, build từ repo.
#
# Bọc image chính thức langflowai/langflow (đã gồm sẵn UI) và thêm một
# entrypoint để map biến PORT của App Platform sang LANGFLOW_PORT.
# Build chỉ mất ~1-2 phút vì không compile lại Python deps.
#
# Image gốc đã đặt sẵn: LANGFLOW_HOST=0.0.0.0, LANGFLOW_PORT=7860,
# WORKDIR /app, USER user, CMD ["langflow", "run"].
# Đổi version cho khớp pyproject.toml (hiện tại 1.13.0).
FROM langflowai/langflow:1.13.0

USER root
COPY docker/digitalocean/entrypoint.sh /usr/local/bin/do-entrypoint.sh
RUN chmod 0755 /usr/local/bin/do-entrypoint.sh

# Trả quyền về user của image gốc (uid/gid 1000:0, HOME=/app/data)
# để Langflow vẫn ghi được DB và uploads.
USER user

# Port mà App Platform route vào (khớp http_port trong .do/app.from-source.yaml).
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/do-entrypoint.sh"]
