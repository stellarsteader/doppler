import asyncio
import hmac
import json
import logging
import time
from contextlib import asynccontextmanager

from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    Header,
    HTTPException,
    Query,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.responses import JSONResponse, PlainTextResponse
from starlette.concurrency import run_in_threadpool
from starlette.datastructures import Headers

from . import config, db
from .streaming import StreamSession
from .transcriber import SAMPLE_RATE, Transcriber

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("stt")


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init()
    if not config.TOKENS:
        log.warning("STT_TOKENS is empty: auth is DISABLED. Only do this for local testing.")
    app.state.transcriber = await run_in_threadpool(Transcriber)
    yield


app = FastAPI(title="Doppler", lifespan=lifespan)


def lookup_device(token: str) -> str | None:
    """Device name for a token, 'local' when auth is disabled, None if the token is unknown."""
    if not config.TOKENS:
        return "local"
    for known, device in config.TOKENS.items():
        if hmac.compare_digest(known.encode(), token.strip().encode()):
            return device
    return None


def device_from_header(authorization: str | None) -> str | None:
    scheme, _, token = (authorization or "").partition(" ")
    return lookup_device(token if scheme.lower() == "bearer" else "")


def device_name(authorization: str | None = Header(default=None)) -> str:
    device = device_from_header(authorization)
    if device is None:
        raise HTTPException(status_code=401, detail="invalid or missing token")
    return device


UPLOAD_PATH = "/v1/audio/transcriptions"
UPLOAD_OVERHEAD = 1024 * 1024  # room for the multipart boundaries and form fields
MAX_RECORDING_ID = 64


class UploadGuard:
    """Rejects a bad token or oversized upload before its body is read to temporary storage."""

    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] == "http" and scope["method"] == "POST" and scope["path"] == UPLOAD_PATH:
            headers = Headers(scope=scope)
            length = headers.get("content-length", "")
            rejection = None
            if device_from_header(headers.get("authorization")) is None:
                rejection = (401, "invalid or missing token")
            elif "transfer-encoding" in headers or not (length.isascii() and length.isdigit()):
                rejection = (411, "content-length required")
            elif int(length) > config.MAX_UPLOAD_BYTES + UPLOAD_OVERHEAD:
                rejection = (413, "audio too large")
            if rejection:
                status, detail = rejection
                await JSONResponse({"detail": detail}, status_code=status)(scope, receive, send)
                return
        await self.app(scope, receive, send)


app.add_middleware(UploadGuard)


@app.get("/healthz")
def healthz():
    return {"ok": True, "model": config.MODEL}


@app.get("/v1/models")
def list_models(_: str = Depends(device_name)):
    return {"object": "list", "data": [{"id": config.MODEL, "object": "model", "owned_by": "self"}]}


@app.post(UPLOAD_PATH)
async def transcribe(
    file: UploadFile = File(...),
    model: str | None = Form(default=None),  # accepted for compatibility, ignored
    language: str | None = Form(default=None),
    prompt: str | None = Form(default=None),
    response_format: str = Form(default="json"),
    save: bool = Form(default=True),
    recording_id: str | None = Form(default=None, max_length=MAX_RECORDING_ID),
    device: str = Depends(device_name),
):
    saved = db.find_recording(recording_id) if recording_id else None
    if saved:  # the stream already saved this recording before the client gave up on it
        result = {key: saved[key] for key in ("text", "language", "duration_s", "processing_ms")}
        entry_id = saved["id"]
    else:
        data = await file.read(config.MAX_UPLOAD_BYTES + 1)
        if len(data) > config.MAX_UPLOAD_BYTES:
            raise HTTPException(status_code=413, detail="audio too large")
        if not data:
            raise HTTPException(status_code=400, detail="empty audio")

        try:
            result = await run_in_threadpool(app.state.transcriber.transcribe, data, language or None, prompt)
        except Exception as exc:
            log.exception("transcription failed")
            raise HTTPException(status_code=400, detail=f"could not transcribe audio: {exc}") from exc
        finally:
            del data

        log.info(
            "%s: %.1fs audio -> %d chars in %dms (%s)",
            device, result["duration_s"], len(result["text"]), result["processing_ms"], result["language"],
        )

        entry_id = None
        if save and result["text"]:
            entry_id = db.add(source=device, recording_id=recording_id or None, **result)["id"]

    if response_format == "text":
        return PlainTextResponse(result["text"])
    if response_format == "verbose_json":
        return {"id": entry_id, "source": device, **result, "duration": result["duration_s"]}
    return {"text": result["text"]}


class StreamError(Exception):
    pass


@app.websocket("/v1/stream")
async def stream(ws: WebSocket):
    """Push-to-talk streaming. Protocol:

    client -> {"type": "start", "token": "...", "language": null, "sample_rate": 16000, "save": true,
               "recording_id": "..."}
    server -> {"type": "ready"}
    client -> binary frames of 16 kHz mono s16le PCM (any size; ~100-250 ms each is ideal)
    server -> {"type": "partial", "text": <new chunk>, "full": <all text so far>}   (about every 24 s)
    client -> {"type": "stop"}
    server -> {"type": "final", "id", "text", "language", "duration_s", "processing_ms", "finalize_ms"}

    finalize_ms is the wait the user feels: time from "stop" to "final".
    The token may also be sent as an Authorization: Bearer header instead.
    """
    await ws.accept()
    session: StreamSession | None = None
    try:
        try:
            start = await asyncio.wait_for(ws.receive_json(), timeout=10)
        except (asyncio.TimeoutError, json.JSONDecodeError, KeyError) as exc:
            raise StreamError('first message must be JSON {"type": "start", ...}') from exc
        if start.get("type") != "start":
            raise StreamError('first message must be {"type": "start", ...}')

        scheme, _, header_token = ws.headers.get("authorization", "").partition(" ")
        token = start.get("token") or (header_token if scheme.lower() == "bearer" else "")
        device = lookup_device(token)
        if device is None:
            raise StreamError("invalid or missing token")
        if start.get("sample_rate", SAMPLE_RATE) != SAMPLE_RATE:
            raise StreamError(f"sample_rate must be {SAMPLE_RATE}")
        recording_id = start.get("recording_id") or None
        if recording_id is not None and (not isinstance(recording_id, str) or len(recording_id) > MAX_RECORDING_ID):
            raise StreamError("invalid recording_id")

        async def send_partial(text: str, full: str) -> None:
            await ws.send_json({"type": "partial", "text": text, "full": full})

        session = StreamSession(app.state.transcriber, start.get("language") or None, send_partial)
        await ws.send_json({"type": "ready"})

        while True:
            message = await ws.receive()
            if message["type"] == "websocket.disconnect":
                raise WebSocketDisconnect(message.get("code", 1000))
            if message.get("bytes"):
                session.feed(message["bytes"])
            elif message.get("text") and json.loads(message["text"]).get("type") == "stop":
                break

        stopped = time.perf_counter()
        await session.finish()
        finalize_ms = int((time.perf_counter() - stopped) * 1000)

        entry_id = None
        if start.get("save", True) and session.text:
            entry_id = db.add(
                text=session.text,
                source=device,
                language=session.language,
                duration_s=session.duration_s,
                processing_ms=int(session.processing_s * 1000),
                recording_id=recording_id,
            )["id"]
        log.info(
            "%s (stream): %.1fs audio -> %d chars, %dms after stop (%s)",
            device, session.duration_s, len(session.text), finalize_ms, session.language,
        )
        await ws.send_json({
            "type": "final",
            "id": entry_id,
            "text": session.text,
            "language": session.language,
            "duration_s": session.duration_s,
            "processing_ms": int(session.processing_s * 1000),
            "finalize_ms": finalize_ms,
        })
        await ws.close()
    except WebSocketDisconnect:
        # Client went away mid-recording: nothing is saved. Clients fall back to uploading
        # the full recording to /v1/audio/transcriptions instead.
        if session:
            session.cancel()
    except Exception as exc:
        if session:
            session.cancel()
        if not isinstance(exc, StreamError):
            log.exception("stream failed")
        try:
            await ws.send_json({"type": "error", "detail": str(exc)})
            await ws.close(code=1008 if isinstance(exc, StreamError) else 1011)
        except Exception:
            pass


@app.get("/api/history")
def history(
    q: str = "",
    limit: int = Query(default=50, ge=1, le=500),
    before_id: int | None = None,
    _: str = Depends(device_name),
):
    return db.search(q.strip(), limit, before_id)


@app.delete("/api/history/{transcript_id}")
def delete_entry(transcript_id: int, _: str = Depends(device_name)):
    if not db.delete(transcript_id):
        raise HTTPException(status_code=404, detail="not found")
    return {"ok": True}
