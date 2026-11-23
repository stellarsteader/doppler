import os


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _parse_tokens(raw: str) -> dict[str, str]:
    """'mac:abc,phone:def' -> {'abc': 'mac', 'def': 'phone'}"""
    tokens = {}
    for pair in filter(None, (p.strip() for p in raw.split(","))):
        device, sep, token = pair.partition(":")
        if not sep or not token:
            raise ValueError(f"STT_TOKENS entry must be device:token, got {pair!r}")
        tokens[token] = device
    return tokens


MODEL = _env("STT_MODEL", "large-v3-turbo")
# Small model used only to pick the language. Detecting with the main model costs a second
# full encoder pass and roughly doubles latency. Empty = use the main model.
LANGID_MODEL = _env("STT_LANGID_MODEL", "small")
DEVICE = _env("STT_DEVICE", "cpu")
COMPUTE_TYPE = _env("STT_COMPUTE_TYPE", "int8")
# 0 = every core. (faster-whisper's own default is only 4 threads.)
CPU_THREADS = int(_env("STT_CPU_THREADS", "0")) or os.cpu_count() or 4
BEAM_SIZE = int(_env("STT_BEAM_SIZE", "5"))
LANGUAGES = [lang.strip() for lang in _env("STT_LANGUAGES", "en,ko,no").split(",") if lang.strip()]
TOKENS = _parse_tokens(_env("STT_TOKENS"))
DB_PATH = _env("STT_DB_PATH", "data/transcripts.db")
MAX_UPLOAD_BYTES = int(_env("STT_MAX_UPLOAD_MB", "50")) * 1024 * 1024
MAX_STREAM_SECONDS = int(_env("STT_MAX_STREAM_MIN", "30")) * 60
STREAM_CUT_AT_S = float(_env("STT_STREAM_CUT_AT_S", "24"))
