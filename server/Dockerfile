FROM python:3.12-slim-bookworm

RUN pip install --no-cache-dir uv==0.12.13

WORKDIR /app
COPY pyproject.toml uv.lock .python-version ./
RUN UV_PYTHON_DOWNLOADS=never uv sync --frozen --no-dev
COPY stt ./stt

# Models and history live in /data so they survive image rebuilds.
RUN useradd --system --home-dir /data --create-home --shell /usr/sbin/nologin stt
USER stt
ENV HF_HOME=/data/huggingface \
    STT_DB_PATH=/data/transcripts.db \
    PYTHONUNBUFFERED=1
VOLUME /data

EXPOSE 8000
# The first start downloads the models (~2 GB) before the server answers.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20m --retries=3 \
  CMD [".venv/bin/python", "-c", "import urllib.request as r; r.urlopen('http://127.0.0.1:8000/healthz', timeout=3)"]
CMD [".venv/bin/uvicorn", "stt.main:app", "--host", "0.0.0.0", "--port", "8000"]
