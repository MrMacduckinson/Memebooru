/// Versioned migrations. `user_version` tracks the applied count.
public enum Schema {
    public static let migrations: [String] = [
        // v1 — initial schema
        """
        CREATE TABLE meme (
            id            TEXT PRIMARY KEY,
            kind          TEXT NOT NULL,
            presentation  TEXT NOT NULL DEFAULT 'native',
            created_at    INTEGER NOT NULL,
            updated_at    INTEGER NOT NULL,
            text_exact    TEXT,
            text_verbatim TEXT,
            context       TEXT,
            payload       TEXT,
            deleted_at    INTEGER
        );
        CREATE INDEX meme_created ON meme(created_at DESC) WHERE deleted_at IS NULL;
        CREATE INDEX meme_kind ON meme(kind) WHERE deleted_at IS NULL;

        CREATE TABLE asset (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            meme_id     TEXT NOT NULL REFERENCES meme(id) ON DELETE CASCADE,
            role        TEXT NOT NULL,
            sha256      TEXT NOT NULL,
            ext         TEXT NOT NULL,
            mime        TEXT NOT NULL,
            width       INTEGER,
            height      INTEGER,
            duration_ms INTEGER,
            bytes       INTEGER NOT NULL,
            dhash       INTEGER,
            phash       INTEGER,
            ord         INTEGER NOT NULL DEFAULT 0,
            original_name TEXT
        );
        CREATE INDEX asset_meme ON asset(meme_id);
        CREATE INDEX asset_sha ON asset(sha256);
        CREATE INDEX asset_phash ON asset(phash) WHERE phash IS NOT NULL;

        CREATE TABLE tag (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            name       TEXT NOT NULL UNIQUE,
            kind       TEXT NOT NULL DEFAULT 'normal',
            created_at INTEGER NOT NULL
        );
        CREATE TABLE tag_alias (
            name   TEXT PRIMARY KEY,
            tag_id INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE
        );
        CREATE INDEX tag_alias_tag ON tag_alias(tag_id);

        CREATE TABLE meme_tag (
            meme_id TEXT NOT NULL REFERENCES meme(id) ON DELETE CASCADE,
            tag_id  INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
            PRIMARY KEY (meme_id, tag_id)
        ) WITHOUT ROWID;
        CREATE INDEX meme_tag_tag ON meme_tag(tag_id, meme_id);

        CREATE TABLE relation (
            from_id    TEXT NOT NULL REFERENCES meme(id) ON DELETE CASCADE,
            to_id      TEXT NOT NULL REFERENCES meme(id) ON DELETE CASCADE,
            kind       TEXT NOT NULL,
            note       TEXT,
            created_at INTEGER NOT NULL,
            deleted_at INTEGER,
            PRIMARY KEY (from_id, to_id, kind)
        ) WITHOUT ROWID;
        CREATE INDEX relation_to ON relation(to_id);

        CREATE TABLE dismissed_pair (
            a_id TEXT NOT NULL,
            b_id TEXT NOT NULL,
            PRIMARY KEY (a_id, b_id)
        ) WITHOUT ROWID;

        CREATE VIRTUAL TABLE meme_fts USING fts5(
            meme_id UNINDEXED,
            text_exact, text_verbatim, context,
            tokenize = 'unicode61 remove_diacritics 2'
        );

        CREATE TABLE oplog (
            seq        INTEGER PRIMARY KEY AUTOINCREMENT,
            op_id      TEXT NOT NULL UNIQUE,
            device_id  TEXT NOT NULL,
            hlc        TEXT NOT NULL,
            entity     TEXT NOT NULL,
            entity_id  TEXT NOT NULL,
            field      TEXT NOT NULL,
            value      TEXT,
            applied_at INTEGER NOT NULL
        );
        CREATE INDEX oplog_hlc ON oplog(hlc);
        CREATE INDEX oplog_device ON oplog(device_id, hlc);

        CREATE TABLE peer (
            device_id     TEXT PRIMARY KEY,
            name          TEXT NOT NULL,
            endpoint      TEXT,
            secret        TEXT,
            last_seen_hlc TEXT,
            added_at      INTEGER NOT NULL
        );

        CREATE TABLE tg_file_cache (
            sha256  TEXT PRIMARY KEY,
            file_id TEXT NOT NULL,
            kind    TEXT NOT NULL
        );

        CREATE TABLE staged (
            id           TEXT PRIMARY KEY,
            kind         TEXT NOT NULL,
            source       TEXT NOT NULL,
            original_name TEXT,
            sha256       TEXT NOT NULL,
            ext          TEXT NOT NULL,
            mime         TEXT NOT NULL,
            bytes        INTEGER NOT NULL,
            width        INTEGER,
            height       INTEGER,
            duration_ms  INTEGER,
            dhash        INTEGER,
            phash        INTEGER,
            text_exact   TEXT,
            text_verbatim TEXT,
            context      TEXT,
            payload      TEXT,
            suggested_tags TEXT,
            user_tags    TEXT,
            added_at     INTEGER NOT NULL
        );
        CREATE INDEX staged_sha ON staged(sha256);
        """,
        // v2 — per-field clocks for last-writer-wins merging
        """
        CREATE TABLE field_clock (
            entity    TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            field     TEXT NOT NULL,
            hlc       TEXT NOT NULL,
            PRIMARY KEY (entity, entity_id, field)
        ) WITHOUT ROWID;
        INSERT OR REPLACE INTO field_clock(entity, entity_id, field, hlc)
            SELECT entity, entity_id, field, max(hlc) FROM oplog GROUP BY entity, entity_id, field;
        """,
        // v3 — undo log, background wayback queue, x import cursor
        """
        CREATE TABLE undo_batch (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            kind       TEXT NOT NULL,
            summary    TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            undone     INTEGER NOT NULL DEFAULT 0,
            count      INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE undo_entry (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            batch_id INTEGER NOT NULL REFERENCES undo_batch(id) ON DELETE CASCADE,
            op       TEXT NOT NULL,
            data     TEXT
        );
        CREATE INDEX undo_entry_batch ON undo_entry(batch_id);

        CREATE TABLE wayback_queue (
            meme_id  TEXT PRIMARY KEY,
            url      TEXT NOT NULL,
            added_at INTEGER NOT NULL,
            tries    INTEGER NOT NULL DEFAULT 0,
            done     INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX wayback_pending ON wayback_queue(done, tries);

        CREATE TABLE x_cursor (
            feed       TEXT PRIMARY KEY,
            cursor     TEXT,
            updated_at INTEGER NOT NULL
        );
        """,
        // v4 — per-entry undo (restore individual items from a batch, across the whole history)
        """
        ALTER TABLE undo_entry ADD COLUMN undone INTEGER NOT NULL DEFAULT 0;
        """,
        // v5 — Telegram bot (server-local, never synced): which Telegram file is which collection file,
        // so replies to a meme in any chat find it without downloading; and what was sent inline lately.
        """
        CREATE TABLE tg_file_ref (
            file_unique_id TEXT PRIMARY KEY,
            sha256         TEXT NOT NULL
        );
        CREATE TABLE tg_usage (
            meme_id   TEXT PRIMARY KEY,
            uses      INTEGER NOT NULL DEFAULT 0,
            last_used INTEGER NOT NULL
        );
        """,
        // v6 — formats: codecs of every file, and for a converted file where it came from;
        // per staged item: convert to a popular format / keep the original.
        """
        ALTER TABLE asset ADD COLUMN codecs TEXT;
        ALTER TABLE asset ADD COLUMN source_sha256 TEXT;
        ALTER TABLE asset ADD COLUMN source_ext TEXT;
        ALTER TABLE asset ADD COLUMN source_codecs TEXT;
        CREATE INDEX asset_source_sha ON asset(source_sha256) WHERE source_sha256 IS NOT NULL;
        ALTER TABLE staged ADD COLUMN codecs TEXT;
        ALTER TABLE staged ADD COLUMN convert INTEGER;
        ALTER TABLE staged ADD COLUMN keep_original INTEGER;
        """,
        // v7 — Wayback retries back off (archive.org rate-limits): when the next attempt is due.
        """
        ALTER TABLE wayback_queue ADD COLUMN next_try_at INTEGER NOT NULL DEFAULT 0;
        """,
        // v8 — staged tweet chains: the tweets a staged tweet replies to / quotes ride along with it
        // (`parent_id` = that staged tweet) and are committed or discarded together.
        """
        ALTER TABLE staged ADD COLUMN parent_id TEXT;
        CREATE INDEX staged_parent ON staged(parent_id);
        """,
        // v9 — cropped / trimmed files: what was done to the kept original (JSON `MediaEdit`).
        """
        ALTER TABLE asset ADD COLUMN edit TEXT;
        ALTER TABLE staged ADD COLUMN edit TEXT;
        """,
    ]

    public static var currentVersion: Int { migrations.count }

    public static func migrate(_ db: Database) throws {
        let from = db.userVersion
        guard from < migrations.count else { return }
        try db.transaction {
            for (i, sql) in migrations.enumerated() where i >= from {
                try db.exec(sql)
                try db.setUserVersion(i + 1)
            }
        }
    }
}
