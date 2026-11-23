#!/usr/bin/env bash
# Installs or updates Doppler on an Ubuntu 22.04/24.04 host. Run as root from the server folder:
#   sudo bash deploy/setup.sh
# Safe to re-run after pulling new code: it keeps the existing env file, tokens and history.
set -euo pipefail

APP_DIR=/opt/doppler
DATA_DIR=/var/lib/doppler
ENV_FILE=/etc/doppler.env
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Installing system packages"
apt-get update -qq
apt-get install -y -qq curl ca-certificates rsync openssl sudo

if ! command -v uv >/dev/null; then
  echo "==> Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh
fi

if ! id stt >/dev/null 2>&1; then
  echo "==> Creating service user 'stt'"
  useradd --system --home-dir "$DATA_DIR" --create-home --shell /usr/sbin/nologin stt
fi

echo "==> Copying app to $APP_DIR"
mkdir -p "$APP_DIR"
rsync -a --delete --exclude .venv --exclude data --exclude .env --exclude __pycache__ \
  "$SRC_DIR"/ "$APP_DIR"/
chown -R stt:stt "$APP_DIR" "$DATA_DIR"

as_stt() { sudo -u stt env HOME="$DATA_DIR" "$@"; }

echo "==> Installing Python dependencies"
(cd "$APP_DIR" && as_stt uv sync --no-dev)

if [ ! -f "$ENV_FILE" ]; then
  echo "==> Creating $ENV_FILE with new device tokens"
  MAC_TOKEN=$(openssl rand -hex 24)
  PHONE_TOKEN=$(openssl rand -hex 24)
  cat >"$ENV_FILE" <<EOF
STT_HOST=127.0.0.1
STT_PORT=8000
STT_MODEL=large-v3-turbo
STT_LANGID_MODEL=small
STT_DEVICE=cpu
STT_COMPUTE_TYPE=int8
STT_CPU_THREADS=0
STT_BEAM_SIZE=5
STT_LANGUAGES=en,ko,no
STT_TOKENS=mac:$MAC_TOKEN,phone:$PHONE_TOKEN
STT_DB_PATH=$DATA_DIR/transcripts.db
STT_MAX_UPLOAD_MB=50
EOF
  chown root:stt "$ENV_FILE"
  chmod 640 "$ENV_FILE"
  NEW_TOKENS=1
fi

echo "==> Downloading models (first run only, ~2 GB)"
for VAR in STT_MODEL STT_LANGID_MODEL; do
  MODEL=$(grep -E "^$VAR=" "$ENV_FILE" | cut -d= -f2 || true)
  [ -n "$MODEL" ] || continue
  (cd "$APP_DIR" && as_stt .venv/bin/python -c \
    "from faster_whisper.utils import download_model; download_model('$MODEL')")
done

echo "==> Installing systemd service"
cp "$APP_DIR/deploy/doppler.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable doppler >/dev/null
systemctl restart doppler

echo "==> Waiting for the server to load the model"
PORT=$(grep -E '^STT_PORT=' "$ENV_FILE" | cut -d= -f2)
for _ in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    echo "==> Running: $(curl -fsS "http://127.0.0.1:$PORT/healthz")"
    break
  fi
  sleep 2
done
systemctl is-active --quiet doppler || { journalctl -u doppler -n 50 --no-pager; exit 1; }

if [ "${NEW_TOKENS:-}" = 1 ]; then
  echo
  echo "Device tokens (also stored in $ENV_FILE):"
  grep -E '^STT_TOKENS=' "$ENV_FILE" | cut -d= -f2 | tr ',' '\n' | sed 's/^/  /'
fi
echo
echo "Logs:  journalctl -u doppler -f"
