"""Transcript history. Only text and metadata are stored; audio never touches disk."""

import os
import sqlite3
from contextlib import closing
from datetime import datetime, timezone

from . import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS transcripts (
    id            INTEGER PRIMARY KEY,
    created_at    TEXT    NOT NULL,
    source        TEXT    NOT NULL,
    language      TEXT,
    duration_s    REAL,
    processing_ms INTEGER,
    text          TEXT    NOT NULL,
    recording_id  TEXT
);
"""


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(config.DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init() -> None:
    os.makedirs(os.path.dirname(os.path.abspath(config.DB_PATH)), exist_ok=True)
    with closing(_connect()) as conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.executescript(SCHEMA)
        columns = {row["name"] for row in conn.execute("PRAGMA table_info(transcripts)")}
        if "recording_id" not in columns:  # databases created before recording IDs
            conn.execute("ALTER TABLE transcripts ADD COLUMN recording_id TEXT")
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS transcripts_recording_id"
            " ON transcripts (recording_id) WHERE recording_id IS NOT NULL"
        )
        conn.commit()


def add(
    text: str,
    source: str,
    language: str,
    duration_s: float,
    processing_ms: int,
    recording_id: str | None = None,
) -> dict:
    """Saves a transcript. A recording that was already saved returns its existing row."""
    created_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    with closing(_connect()) as conn, conn:
        cur = conn.execute(
            "INSERT INTO transcripts"
            " (created_at, source, language, duration_s, processing_ms, text, recording_id)"
            " VALUES (?, ?, ?, ?, ?, ?, ?)"
            " ON CONFLICT (recording_id) WHERE recording_id IS NOT NULL DO NOTHING",
            (created_at, source, language, duration_s, processing_ms, text, recording_id),
        )
        if cur.rowcount == 0:
            return find_recording(recording_id, conn)
        return get(cur.lastrowid, conn)


def find_recording(recording_id: str, conn: sqlite3.Connection | None = None) -> dict | None:
    if conn is None:
        with closing(_connect()) as conn:
            return find_recording(recording_id, conn)
    row = conn.execute("SELECT * FROM transcripts WHERE recording_id = ?", (recording_id,)).fetchone()
    return dict(row) if row else None


def get(transcript_id: int, conn: sqlite3.Connection | None = None) -> dict | None:
    if conn is None:
        with closing(_connect()) as conn:
            return get(transcript_id, conn)
    row = conn.execute("SELECT * FROM transcripts WHERE id = ?", (transcript_id,)).fetchone()
    return dict(row) if row else None


def search(query: str = "", limit: int = 50, before_id: int | None = None) -> list[dict]:
    # Plain LIKE rather than FTS: it matches Korean substrings (회의 in 회의를) and is
    # fast enough for a personal history of hundreds of thousands of rows.
    sql = "SELECT * FROM transcripts WHERE 1=1"
    params: list = []
    if query:
        escaped = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        sql += " AND text LIKE ? ESCAPE '\\'"
        params.append(f"%{escaped}%")
    if before_id is not None:
        sql += " AND id < ?"
        params.append(before_id)
    sql += " ORDER BY id DESC LIMIT ?"
    params.append(limit)
    with closing(_connect()) as conn:
        return [dict(row) for row in conn.execute(sql, params)]


def delete(transcript_id: int) -> bool:
    with closing(_connect()) as conn, conn:
        return conn.execute("DELETE FROM transcripts WHERE id = ?", (transcript_id,)).rowcount > 0
