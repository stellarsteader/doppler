<p align="center">
  <img src="assets/logo/doppler-banner.svg" width="100%" alt="Doppler banner: black and white ripple rings">
</p>

<h1 align="center">Doppler</h1>

<p align="center">
  <strong>Self-Hosted Speech-to-Text Server & macOS App</strong>
</p>

<p align="center">
  <img src="assets/badges/macos.svg" alt="macOS 14.2+">
  <img src="assets/badges/python.svg" alt="Python 3.10–3.13">
  <img src="assets/badges/license.svg" alt="License: MIT">
</p>

## Doppler App

Native SwiftUI menu bar app.

- **Global push-to-talk.** Hold or toggle, with key combinations or modifier-only shortcuts.
- **Audio capture.** Any microphone, or one app's output through a Core Audio process tap.
- **WebSocket streaming.** 16 kHz PCM with automatic HTTP upload fallback.
- **Notch overlay.** Live transcript and audio level at the notch.
- **Text insertion.** Pastes into the focused app and restores the clipboard.

Connect it to Doppler Server for live text, or to another server with an OpenAI-compatible upload endpoint. If that server requires a model name, set it in Settings.

## Doppler Server

FastAPI transcription server.

- **Speech model.** Whisper `large-v3-turbo` on [faster-whisper](https://github.com/SYSTRAN/faster-whisper), with CPU `int8` inference by default.
- **Streaming pipeline.** WebSocket PCM ingest with background passes cut at Silero VAD pauses, so finalizing takes one pass.
- **Language detection.** Per-chunk detection with a smaller Whisper model, limited to a configurable language list.
- **OpenAI-compatible API.** `POST /v1/audio/transcriptions` for existing clients.
- **Device auth.** One token per device, recorded with each transcript.
- **Text-only history.** Transcripts are stored in SQLite. Audio is not kept.

## Quick start

### Server

You need [uv](https://docs.astral.sh/uv/).

```bash
cd server
uv sync
cp .env.example .env          # leave STT_TOKENS empty to skip auth locally
uv run uvicorn stt.main:app --env-file .env --port 8000
```

On first start, the server downloads the [Whisper](https://github.com/openai/whisper) models (~2 GB). On Apple Silicon, set `STT_CPU_THREADS` in `.env` to your performance-core count for the best speed.

To run it on another machine with Docker or as a Linux service, see [Self-hosting](docs/self-hosting.md).

### App

You need Xcode. No Apple Developer account is required. From the repository root:

```bash
cd apps/macos && ./build.sh --install
open "/Applications/Doppler.app"
```

Click the Doppler icon in the menu bar and open **Settings…**. Choose a shortcut, and grant Microphone and Accessibility access.

### Use them together

Start the server, then enter its URL in the app's Settings.

## Documentation

| Guide | Covers |
|---|---|
| [Self-hosting](docs/self-hosting.md) | Docker, Linux service or source install, and remote access |
| [Mac app](docs/mac-app.md) | Settings, shortcuts, permissions and local code signing |
| [API](docs/api.md) | WebSocket streaming and HTTP endpoints |
| [Configuration](docs/configuration.md) | Environment variables |

## License

[MIT](LICENSE)
