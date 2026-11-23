"""Small transactional SQLite store for administrator-published vocabulary."""

from pathlib import Path
import sqlite3
from typing import Mapping, Optional, Sequence


class VocabularyStore:
    """Persists the active OTA vocabulary outside the app's public source code."""

    def __init__(self, database_path: str | Path):
        self.database_path = Path(database_path)

    def list_entries(self) -> Optional[list[dict[str, object]]]:
        """Return the stored dataset, or ``None`` before the first publication."""
        if not self.database_path.exists():
            return None

        connection = sqlite3.connect(self.database_path, timeout=10)
        try:
            table = connection.execute(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                ("vocabulary",),
            ).fetchone()
            if table is None:
                return None

            connection.row_factory = sqlite3.Row
            rows = connection.execute(
                """
                SELECT fsl_id, word, meaning, gesture_label, video_path, created_at
                FROM vocabulary
                ORDER BY fsl_id
                """
            ).fetchall()
            return [dict(row) for row in rows]
        finally:
            connection.close()

    def replace_entries(self, entries: Sequence[Mapping[str, object]]) -> int:
        """Replace the complete dataset atomically, preserving the previous one on error."""
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(self.database_path, timeout=10)
        try:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS vocabulary (
                    fsl_id INTEGER PRIMARY KEY,
                    word TEXT NOT NULL,
                    meaning TEXT NOT NULL,
                    gesture_label TEXT NOT NULL,
                    video_path TEXT,
                    created_at TEXT
                )
                """
            )
            connection.execute("DELETE FROM vocabulary")
            connection.executemany(
                """
                INSERT INTO vocabulary
                    (fsl_id, word, meaning, gesture_label, video_path, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        entry["fsl_id"],
                        entry["word"],
                        entry["meaning"],
                        entry["gesture_label"],
                        entry.get("video_path"),
                        entry.get("created_at"),
                    )
                    for entry in entries
                ],
            )
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

        return len(entries)

    def remove_entry(self, fsl_id: int) -> bool:
        """Remove one item from a published dataset in a transaction."""
        if not self.database_path.exists():
            return False
        connection = sqlite3.connect(self.database_path, timeout=10)
        try:
            table = connection.execute(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                ("vocabulary",),
            ).fetchone()
            if table is None:
                return False
            cursor = connection.execute(
                "DELETE FROM vocabulary WHERE fsl_id = ?", (fsl_id,)
            )
            connection.commit()
            return cursor.rowcount > 0
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()
