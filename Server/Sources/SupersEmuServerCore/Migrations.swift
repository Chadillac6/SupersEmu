import GRDB

/// Schema for Phase 1, already shaped for Phase 2 (users, groups, per-game permissions).
/// Tracks add later migrations in their own files and append them in `registerTrackMigrations`.
public enum ServerMigrations {
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_core") { db in
            try db.execute(sql: """
                CREATE TABLE users (
                    id TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    role TEXT NOT NULL CHECK (role IN ('admin', 'player')),
                    created_at DATETIME NOT NULL,
                    revoked_at DATETIME
                );
                CREATE TABLE devices (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    token_hash TEXT NOT NULL UNIQUE,
                    created_at DATETIME NOT NULL,
                    last_seen_at DATETIME,
                    revoked_at DATETIME
                );
                CREATE TABLE api_tokens (
                    id TEXT PRIMARY KEY,
                    owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    scopes TEXT NOT NULL,
                    token_hash TEXT NOT NULL UNIQUE,
                    created_at DATETIME NOT NULL,
                    revoked_at DATETIME
                );
                CREATE TABLE groups (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE
                );
                CREATE TABLE group_members (
                    group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    PRIMARY KEY (group_id, user_id)
                );
                CREATE TABLE games (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    system TEXT NOT NULL,
                    year INTEGER,
                    genre TEXT,
                    summary TEXT,
                    cover_artwork TEXT,
                    needs_review INTEGER NOT NULL DEFAULT 0,
                    created_at DATETIME NOT NULL
                );
                CREATE TABLE game_files (
                    id TEXT NOT NULL,
                    game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                    filename TEXT NOT NULL,
                    role TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    disc_number INTEGER,
                    stored_path TEXT NOT NULL,
                    PRIMARY KEY (game_id, id)
                );
                CREATE TABLE game_permissions (
                    game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                    principal_type TEXT NOT NULL CHECK (principal_type IN ('everyone', 'user', 'group')),
                    principal_id TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY (game_id, principal_type, principal_id)
                );
                CREATE TABLE save_revisions (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    game_id TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('native', 'auto', 'manual')),
                    slot TEXT NOT NULL DEFAULT '',
                    parent_id TEXT,
                    sha256 TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    core_id TEXT NOT NULL,
                    core_version TEXT NOT NULL,
                    device_id TEXT,
                    stored_path TEXT NOT NULL,
                    created_at DATETIME NOT NULL
                );
                CREATE INDEX save_revisions_lookup ON save_revisions (user_id, game_id, kind, slot, created_at);
                CREATE TABLE audit_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    at DATETIME NOT NULL,
                    actor_user_id TEXT,
                    actor_credential TEXT,
                    action TEXT NOT NULL,
                    detail TEXT
                );
                """)
        }
        registerTrackMigrations(&migrator)
        return migrator
    }

    /// Later tracks append their migrations here (one line each) to keep merge conflicts trivial.
    static func registerTrackMigrations(_ migrator: inout DatabaseMigrator) {
    }
}
