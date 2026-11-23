# API

All endpoints except `/healthz` need `Authorization: Bearer <token>` when `STT_TOKENS` is set.

## Streaming (push-to-talk clients)

WebSocket `/v1/stream`:

```
client → {"type": "start", "token": "...", "language": null, "sample_rate": 16000, "save": true, "recording_id": "..."}
server → {"type": "ready"}
client → binary frames: 16 kHz mono 16-bit little-endian PCM (any size, 100–250 ms recommended)
server → {"type": "partial", "text": "<new sentence(s)>", "full": "<everything so far>"}   about every 24 s
client → {"type": "stop"}
server → {"type": "final", "id", "text", "language", "duration_s", "processing_ms", "finalize_ms"}
server → {"type": "error", "detail"}   then closes, on bad token / bad input
```

- `partial` arrives roughly every 24 s of speech (`STT_STREAM_CUT_AT_S`), not at every pause.
- `finalize_ms` is the wait from `stop` to `final`.
- The token can go in the `start` message or an `Authorization` header.
- If the connection drops, nothing is saved. Clients should keep the recording and fall back to
  the upload endpoint, using the same `recording_id` to prevent a duplicate.

## HTTP

| Method | Path | Notes |
|---|---|---|
| `POST` | `/v1/audio/transcriptions` | multipart `file` (any common format: m4a, webm, wav, mp3, ogg…). Optional: `model` (accepted for compatibility, ignored), `language` (`en`/`ko`/`no`, skips detection), `prompt` (vocabulary hint), `response_format` (`json` default, `text`, `verbose_json`), `save` (default `true`), `recording_id` (prevents duplicate saves) |
| `GET` | `/api/history` | `q` (substring search, works for Korean), `limit` (≤500), `before_id` (pagination) |
| `DELETE` | `/api/history/{id}` | |
| `GET` | `/v1/models` | for OpenAI-compatible clients |
| `GET` | `/healthz` | no auth |

Uploads must send `Content-Length` and fit within `STT_MAX_UPLOAD_MB`.

| Status | Meaning |
|---|---|
| `400` | Empty or unreadable audio |
| `401` | Invalid or missing token |
| `411` | `Content-Length` missing, or a chunked upload |
| `413` | Audio is too large |

Example upload:

```bash
# add -H "Authorization: Bearer <token>" when STT_TOKENS is set
curl -F file=@clip.m4a -F response_format=verbose_json http://127.0.0.1:8000/v1/audio/transcriptions
```
