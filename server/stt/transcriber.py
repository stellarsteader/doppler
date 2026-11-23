import io
import logging
import threading
import time

import av
import numpy as np
from faster_whisper import WhisperModel
from faster_whisper.vad import collect_chunks, get_speech_timestamps

from . import config

log = logging.getLogger("stt")

SAMPLE_RATE = 16000


def decode_audio(data: bytes) -> np.ndarray:
    """Any container/codec (webm, mp4, wav, ogg...) -> 16 kHz mono float32, entirely in memory.

    Our own copy of faster_whisper.audio.decode_audio, which passes an argument
    (metadata_errors) that PyAV 15+ no longer accepts.
    """
    resampler = av.AudioResampler(format="s16", layout="mono", rate=SAMPLE_RATE)
    chunks = []
    with av.open(io.BytesIO(data), mode="r") as container:
        for frame in container.decode(audio=0):
            for out in resampler.resample(frame):
                chunks.append(out.to_ndarray().reshape(-1))
        for out in resampler.resample(None):
            chunks.append(out.to_ndarray().reshape(-1))
    if not chunks:
        return np.zeros(0, dtype=np.float32)
    return np.concatenate(chunks).astype(np.float32) / 32768.0


MIN_REPEAT_WORDS = 4


def collapse_repeats(text: str) -> str:
    """Drops a phrase Whisper emitted twice in a row ("아무 말이나 한번 해보겠습니다 아무 말이나 한번
    해보겠습니다"), a known hallucination. Only spans of MIN_REPEAT_WORDS+ words are touched,
    since people do repeat short phrases on purpose."""
    words = text.split()
    i = 0
    while i < len(words):
        for length in range((len(words) - i) // 2, MIN_REPEAT_WORDS - 1, -1):
            if words[i : i + length] == words[i + length : i + 2 * length]:
                del words[i + length : i + 2 * length]
                break
        else:
            i += 1
    return " ".join(words)


# Whisper writes in one language per pass. Decoding as Korean keeps English words and sentences in
# English, but decoding as English translates the Korean. So a chunk that may hold Korean is
# decoded as Korean even when English scores higher.
KEEPS_ENGLISH = {"ko"}
KEEPS_ENGLISH_MIN = 0.15


class Transcriber:
    def __init__(self) -> None:
        log.info("loading %s (%s/%s)", config.MODEL, config.DEVICE, config.COMPUTE_TYPE)
        start = time.perf_counter()
        self.model = self._load(config.MODEL)
        self.langid = self._load(config.LANGID_MODEL) if config.LANGID_MODEL else self.model
        log.info("model ready in %.1fs", time.perf_counter() - start)
        # One request at a time: each transcription already uses every core.
        self._lock = threading.Lock()

    @staticmethod
    def _load(name: str) -> WhisperModel:
        return WhisperModel(
            name,
            device=config.DEVICE,
            compute_type=config.COMPUTE_TYPE,
            cpu_threads=config.CPU_THREADS,
        )

    def _pick_language(self, audio: np.ndarray) -> str | None:
        if len(config.LANGUAGES) == 1:
            return config.LANGUAGES[0]
        speech = get_speech_timestamps(audio)
        if speech:  # judge the speech only: background noise skews the guess
            audio = np.concatenate(collect_chunks(audio, speech)[0])
        _, _, probs = self.langid.detect_language(audio)
        scores: dict[str, float] = {}
        for lang, p in probs:
            lang = "no" if lang == "nn" else lang  # Nynorsk -> Norwegian
            if not config.LANGUAGES or lang in config.LANGUAGES:
                scores[lang] = scores.get(lang, 0) + p
        best = max(scores, key=scores.get)
        if best == "en":
            keeps = [lang for lang in KEEPS_ENGLISH if scores.get(lang, 0) >= KEEPS_ENGLISH_MIN]
            if keeps:
                return max(keeps, key=scores.get)
        return best

    def transcribe_audio(
        self, audio: np.ndarray, language: str | None = None, prompt: str | None = None
    ) -> tuple[str, str | None]:
        """16 kHz float32 audio -> (text, language). Thread-safe."""
        with self._lock:
            if not get_speech_timestamps(audio):
                return "", language
            language = language or self._pick_language(audio)
            segments, info = self.model.transcribe(
                audio,
                language=language,
                beam_size=config.BEAM_SIZE,
                vad_filter=True,
                # Avoids the repeat loops Whisper falls into on long/quiet audio.
                condition_on_previous_text=False,
                initial_prompt=prompt or None,
            )
            text = "".join(segment.text for segment in segments).strip()
            return collapse_repeats(text), info.language

    def transcribe(self, data: bytes, language: str | None = None, prompt: str | None = None) -> dict:
        """Decode audio bytes in memory and return text plus metadata."""
        start = time.perf_counter()
        audio = decode_audio(data)
        text, language = self.transcribe_audio(audio, language, prompt)
        return {
            "text": text,
            "language": language,
            "duration_s": round(len(audio) / SAMPLE_RATE, 2),
            "processing_ms": int((time.perf_counter() - start) * 1000),
        }
