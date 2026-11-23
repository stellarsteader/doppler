"""Transcribe while the user is still talking.

The client streams 16 kHz mono s16le PCM. Whisper always encodes a fixed 30 s window, so one
pass costs about the same for 3 s or 25 s of audio, and the wait after "stop" can never be less
than one pass. The goal is therefore to make it *exactly* one pass, with as few passes overall
as possible:

- Nothing is transcribed until the buffer nears the 30 s window (CUT_AT). Recordings shorter
  than that get a single pass after stop, and no earlier pass can still be running then.
- At CUT_AT, the audio up to the latest pause (Silero VAD) is transcribed in the background,
  so whatever is left at stop always fits in one window, however long the user talked.
"""

import asyncio
import logging
import time
from collections import Counter
from collections.abc import Awaitable, Callable

import numpy as np
from faster_whisper.vad import VadOptions, get_speech_timestamps
from starlette.concurrency import run_in_threadpool

from . import config
from .transcriber import SAMPLE_RATE, Transcriber

log = logging.getLogger("stt")

# Lower = shorter final pass (less text to decode after stop) but more passes overall.
# Keep it well below 30 s for audio that arrives while a background pass is running.
CUT_AT = int(config.STREAM_CUT_AT_S * SAMPLE_RATE)
MIN_CHUNK = 8 * SAMPLE_RATE  # ignore pauses earlier than this when choosing where to cut
CHECK_EVERY = SAMPLE_RATE // 2
MIN_TRAILING_PAUSE = int(0.3 * SAMPLE_RATE)
PROMPT_CHARS = 200

_PAUSES = VadOptions(min_silence_duration_ms=400, speech_pad_ms=100)


def find_cut(audio: np.ndarray) -> int | None:
    """Sample index to cut at, or None to keep buffering."""
    speech = get_speech_timestamps(audio, _PAUSES)
    if not speech:
        # Only silence so far: drop all but the last second so the buffer can't grow forever.
        return max(0, len(audio) - SAMPLE_RATE) or None
    if len(audio) < CUT_AT:
        return None

    # Middle of the latest pause, so no word is split between two passes.
    cuts = [(a["end"] + b["start"]) // 2 for a, b in zip(speech, speech[1:])]
    trailing = len(audio) - speech[-1]["end"]
    if trailing >= MIN_TRAILING_PAUSE:
        cuts.append(speech[-1]["end"] + trailing // 2)
    ready = [c for c in cuts if c >= MIN_CHUNK]
    if ready:
        return ready[-1]

    # No usable pause: cut at the quietest 100 ms in the second half.
    window = SAMPLE_RATE // 10
    half = len(audio) // 2
    tail = audio[half:]
    n = len(tail) // window
    energy = (tail[: n * window].reshape(n, window) ** 2).mean(axis=1)
    return half + int(energy.argmin()) * window + window // 2


class StreamSession:
    def __init__(
        self,
        transcriber: Transcriber,
        language: str | None,
        on_partial: Callable[[str, str], Awaitable[None]],
    ) -> None:
        self.transcriber = transcriber
        self.fixed_language = language
        self.on_partial = on_partial
        self.parts: list[str] = []
        self._languages: Counter[str] = Counter()
        self.total_samples = 0
        self.processing_s = 0.0
        self._pending = np.zeros(0, dtype=np.float32)
        self._carry = b""  # odd trailing byte from the last frame
        self._since_check = 0
        self._task: asyncio.Task | None = None

    @property
    def text(self) -> str:
        return " ".join(self.parts)

    @property
    def language(self) -> str | None:
        """The language most of the chunks were in."""
        return self.fixed_language or next(iter(self._languages.most_common(1)), (None,))[0]

    @property
    def duration_s(self) -> float:
        return round(self.total_samples / SAMPLE_RATE, 2)

    def feed(self, data: bytes) -> None:
        if self._task and self._task.done():
            self._task.result()

        data = self._carry + data
        usable = len(data) - len(data) % 2
        self._carry = data[usable:]
        samples = np.frombuffer(data[:usable], dtype="<i2").astype(np.float32) / 32768.0

        self._pending = np.concatenate([self._pending, samples])
        self.total_samples += len(samples)
        if self.total_samples > config.MAX_STREAM_SECONDS * SAMPLE_RATE:
            raise ValueError("stream too long")

        self._since_check += len(samples)
        if self._since_check >= CHECK_EVERY and (self._task is None or self._task.done()):
            self._since_check = 0
            self._task = asyncio.create_task(self._step())

    async def _step(self) -> None:
        # Only this task removes audio from _pending; feed() only appends, so the cut index
        # computed on this snapshot is still valid afterwards.
        cut = await run_in_threadpool(find_cut, self._pending)
        if cut:
            await self._transcribe(cut)

    async def _transcribe(self, cut: int) -> None:
        chunk, self._pending = self._pending[:cut], self._pending[cut:]
        prompt = self.text[-PROMPT_CHARS:]
        start = time.perf_counter()
        # Language is detected per chunk, never carried over: Whisper told "Korean" for a chunk
        # of English speech translates it into Korean instead of transcribing it.
        text, language = await run_in_threadpool(
            self.transcriber.transcribe_audio, chunk, self.fixed_language, prompt
        )
        elapsed = time.perf_counter() - start
        self.processing_s += elapsed
        log.info("chunk %.1fs -> %d chars in %dms (%s)", len(chunk) / SAMPLE_RATE, len(text), elapsed * 1000, language)
        if text:
            self._languages[language] += 1
            self.parts.append(text)
            await self.on_partial(text, self.text)

    async def finish(self) -> None:
        """Wait for the in-flight chunk, then transcribe whatever is left."""
        if self._task:
            await self._task
        if len(self._pending):
            await self._transcribe(len(self._pending))

    def cancel(self) -> None:
        if self._task and not self._task.done():
            self._task.cancel()
