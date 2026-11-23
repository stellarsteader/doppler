# Configuration

Environment variables (see `server/.env.example`):

| Variable | Default | |
|---|---|---|
| `STT_MODEL` | `large-v3-turbo` | any faster-whisper model name or local path |
| `STT_LANGID_MODEL` | `small` | small model for language detection (`base` is faster but can't tell Norwegian); empty = use main model |
| `STT_LANGUAGES` | `en,ko,no` | languages you speak; detection picks among these per stretch of speech (one value = always that language) |
| `STT_DEVICE` | `cpu` | device passed to faster-whisper |
| `STT_COMPUTE_TYPE` | `int8` | model precision passed to faster-whisper |
| `STT_BEAM_SIZE` | `5` | `1` is faster, slightly less accurate |
| `STT_CPU_THREADS` | `0` | 0 = all cores. On Apple Silicon set it to the performance-core count |
| `STT_TOKENS` | empty | `mac:token1,phone:token2`; empty disables auth |
| `STT_DB_PATH` | `data/transcripts.db` | transcript database; a relative path starts from the folder the server runs in. Docker always uses `/data/transcripts.db` |
| `STT_MAX_UPLOAD_MB` | `50` | largest accepted upload |
| `STT_MAX_STREAM_MIN` | `30` | longest single streamed recording |
| `STT_STREAM_CUT_AT_S` | `24` | streaming buffers this long before transcribing in the background. Lower = slightly shorter wait after stop (less text in the final pass) but more total compute and a chance of waiting for two passes. Tune on your host |

Docker Compose (`server/.env`) and the Linux service (`/etc/doppler.env`) also read:

| Variable | Default | |
|---|---|---|
| `STT_HOST` | `127.0.0.1` | host address to listen on |
| `STT_PORT` | `8000` | host port to listen on |

When running from source, set these with `--host` and `--port` on the `uvicorn` command.
