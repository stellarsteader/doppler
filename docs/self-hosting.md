# Self-hosting

Doppler Server runs on any always-on host: a cloud VM, dedicated server, home server or
workstation. Choose how to run it, then how your devices reach it.

## Requirements

- 64-bit x86 or ARM CPU. Doppler runs on the CPU by default.
- 8 GB of RAM recommended.
- About 3 GB of free disk space for the image and models.

## Install

| Method | Best for |
|---|---|
| [Docker Compose](#docker-compose) | Any host with Docker. Recommended for servers |
| [Linux service](#linux-service) | Ubuntu 22.04/24.04 without Docker |
| [From source](#from-source) | macOS and development |

On macOS, run from source because Docker runs inside a virtual machine.

### Docker Compose

```bash
git clone https://github.com/stellarsteader/doppler.git
cd doppler/server
cp .env.example .env
docker compose run --rm --no-deps doppler python -c "import secrets; print(secrets.token_hex(24))"
```

Put the printed token in `.env`, then start the server:

```bash
# in .env
STT_TOKENS=laptop:YOUR_TOKEN
```

```bash
docker compose up -d --build
```

The first start downloads the models (~2 GB). Follow it with `docker compose logs -f`.
The container restarts automatically, and models and history stay in the `doppler_data` volume.

To update:

```bash
git pull && docker compose up -d --build
```

To back up your history:

```bash
docker compose stop
docker compose cp doppler:/data/transcripts.db ./transcripts-backup.db
docker compose start
```

### Linux service

```bash
sudo apt-get install -y git
git clone https://github.com/stellarsteader/doppler.git
cd doppler/server
sudo bash deploy/setup.sh
```

`setup.sh` installs uv, creates an `stt` system user, installs into `/opt/doppler`,
writes `/etc/doppler.env` with a fresh token per device (printed once at the end),
downloads the models and starts the `doppler` systemd service.

To update, run this from `doppler/server`. Your tokens and history are kept.

```bash
git pull && sudo bash deploy/setup.sh
```

Useful commands:

```bash
sudo journalctl -u doppler -f        # logs (one line per transcription with timings)
sudo systemctl restart doppler       # after editing /etc/doppler.env
```

To read recent transcripts, install the SQLite command-line tool once:

```bash
sudo apt-get install -y sqlite3
sudo -u stt sqlite3 /var/lib/doppler/transcripts.db 'select created_at, text from transcripts order by id desc limit 10'
```

To back up your history while the server is running:

```bash
sudo -u stt sqlite3 /var/lib/doppler/transcripts.db ".backup '/var/lib/doppler/transcripts-backup.db'"
```

Copy `/var/lib/doppler/transcripts-backup.db` to another machine to protect it from disk failure.

### From source

You need [uv](https://docs.astral.sh/uv/).

```bash
cd server
uv sync
cp .env.example .env
uv run uvicorn stt.main:app --env-file .env --port 8000
```

This runs in the foreground and does not start automatically. On Apple Silicon, set
`STT_CPU_THREADS` in `.env` to your performance-core count for the best speed.

To back up your history from the `server` folder, using the `sqlite3` command-line tool:

```bash
sqlite3 data/transcripts.db ".backup 'data/transcripts-backup.db'"
```

## Check the server

```bash
curl http://127.0.0.1:8000/healthz
curl -H "Authorization: Bearer YOUR_TOKEN" -F file=@clip.m4a -F response_format=verbose_json \
  http://127.0.0.1:8000/v1/audio/transcriptions
```

`processing_ms` in the response is the server-side latency on that host.

## Remote access

The server listens on `127.0.0.1:8000` by default, so only the host itself can reach it.

### Private network (recommended)

[Tailscale](https://tailscale.com) reaches the host from your devices without opening a port,
including behind a home router. The free Personal plan is enough.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
sudo tailscale serve --bg 8000     # https://<host>.<tailnet>.ts.net, tailnet-only
```

Enter that URL and your token in the app's Settings.

To test from another computer without Tailscale, use an SSH tunnel:

```bash
ssh -N -L 8000:127.0.0.1:8000 USER@YOUR_HOST
```

### Public internet

Put an HTTPS reverse proxy, such as Caddy or nginx, in front of `127.0.0.1:8000`. It must forward
WebSockets for `/v1/stream` and allow uploads up to `STT_MAX_UPLOAD_MB`. Always set `STT_TOKENS`,
because an empty value disables authentication.

## Keep the host awake

The server stops responding while the host sleeps. On a dedicated Linux desktop, disable sleep:

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```
