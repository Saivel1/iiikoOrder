FROM python:3.13-slim

COPY --from=ghcr.io/astral-sh/uv:0.9.2 /uv /bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Зависимости отдельным слоем — пересобираются, только когда меняется uv.lock
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY *.py ./
COPY templates ./templates

# База и свои фото блюд живут в томе data/ (см. docker-compose.yml)
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app \
    && mkdir -p /app/data /app/static/menu \
    && chown -R app:app /app/data /app/static
USER app

ENV PATH=/opt/venv/bin:$PATH \
    DB_PATH=/app/data/app.db

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/menu', timeout=4)"

# Один воркер: лимит частоты заказов живёт в памяти процесса.
# Access-лог выключен: в адресах страницы бариста лежит ключ, ему нечего делать в логах.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", \
     "--proxy-headers", "--forwarded-allow-ips", "*", "--no-access-log"]
