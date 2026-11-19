import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/core/utils/timestamp_utils.dart';
import 'package:bechat/data/models/peer.dart';

class DatabaseHelper {
  static Database? _database;
  static const String _dbName = AppConstants.databaseName;
  static const int _dbVersion = AppConstants.databaseVersion;

  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);
    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: _onConfigure,
    );
  }

  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  static Future<void> _onCreate(Database db, int version) async {
    await createSchema(db);
  }

  static Future<void> createSchema(Database db) async {
    await _createTables(db);
    await _createIndexes(db);
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await migrateToUtcTimestamps(db);
    }
    if (oldVersion < 3) {
      await migrateToVersion3(db);
    }
    if (oldVersion < 4) {
      await migrateToVersion4(db);
    }
    if (oldVersion < 5) {
      await migrateToVersion5(db);
    }
    if (oldVersion < 6) {
      await migrateToVersion6(db);
    }
    if (oldVersion < 7) {
      await migrateToVersion7(db);
    }
  }

  /// Adds the persistent application settings table without touching user data.
  ///
  /// sqflite runs `onUpgrade` inside a transaction, so this method must not
  /// start a nested transaction.
  static Future<void> migrateToVersion3(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  /// Adds the cryptographic identity and peer-verification metadata columns
  /// (database version 4).
  ///
  /// Purely additive and never destructive:
  ///
  /// * existing identity and peer rows keep their values;
  /// * no key material is generated and no Noise identity is provisioned;
  /// * no peer is promoted to `verified` because it already had a key;
  /// * legacy peers that still hold a usable-looking key are marked
  ///   `unverified`, and peers without a key stay `none`.
  ///
  /// sqflite runs `onUpgrade` inside a transaction, so this method must not
  /// start a nested transaction. Each step is guarded, so running the
  /// migration again (or against a database that already has the columns) is a
  /// no-op instead of a "duplicate column" failure.
  static Future<void> migrateToVersion4(Database db) async {
    await _addColumnIfMissing(db, 'identity', 'public_key_fingerprint', 'TEXT');
    await _addColumnIfMissing(db, 'identity', 'key_algorithm', 'TEXT');
    await _addColumnIfMissing(db, 'identity', 'identity_created_at', 'TEXT');

    await _addColumnIfMissing(db, 'peers', 'public_key_fingerprint', 'TEXT');
    await _addColumnIfMissing(
      db,
      'peers',
      'verification_state',
      "TEXT NOT NULL DEFAULT '${PeerKeyVerificationState.none.name}'",
    );
    await _addColumnIfMissing(db, 'peers', 'key_verified_at', 'TEXT');
    await _addColumnIfMissing(db, 'peers', 'key_changed_at', 'TEXT');

    // An empty or whitespace-only key is not a key: normalize it away so it
    // can never be mistaken for stored key material.
    await db.execute(
      "UPDATE peers SET public_key = NULL "
      "WHERE public_key IS NOT NULL AND TRIM(public_key) = ''",
    );

    // A stored key is not a trusted key. Only a key that exists becomes
    // `unverified`; `verified` and `changed` are never assigned here.
    await db.execute(
      "UPDATE peers SET verification_state = '${PeerKeyVerificationState.unverified.name}' "
      "WHERE public_key IS NOT NULL "
      "AND verification_state = '${PeerKeyVerificationState.none.name}'",
    );
  }

  /// v5: durable multi-hop routing foundations (additive only).
  ///
  /// * `seen_messages` — dedup ledger keyed by envelope id, so a relay drops a
  ///   copy it has already forwarded. `expires_at` lets cleanup find expired
  ///   rows with a plain range scan.
  /// * `relay_queue` — envelopes parked for future forwarding, with hop data,
  ///   attempts, next hop, and a textual state machine.
  ///
  /// No forwarding logic is activated here; this is storage only. Timestamps
  /// use [TimestampUtils] canonical UTC ISO-8601 so expiry comparisons are
  /// correct lexicographic range scans. Runs inside sqflite's upgrade
  /// transaction, so it must not open a nested one.
  static Future<void> migrateToVersion5(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS seen_messages (
        envelope_id TEXT PRIMARY KEY NOT NULL,
        first_seen_at TEXT NOT NULL,
        expires_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_seen_messages_expires_at '
      'ON seen_messages (expires_at)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS relay_queue (
        envelope_id TEXT PRIMARY KEY NOT NULL,
        envelope BLOB NOT NULL,
        origin_device_id TEXT NOT NULL,
        destination_device_id TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        hop_limit INTEGER NOT NULL,
        hop_count INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_hop_device_id TEXT,
        state TEXT NOT NULL DEFAULT 'queued',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_relay_queue_expires_at '
      'ON relay_queue (expires_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_relay_queue_state '
      'ON relay_queue (state)',
    );
  }

  /// v6: the authenticated peer an envelope arrived from, kept on the queue
  /// row so the retry loop can exclude it after a restart (Phase 3D.2B).
  ///
  /// Purely additive and nullable: every existing row keeps its bytes and
  /// stays parked; a NULL incoming peer is never retried (the exclusion set
  /// cannot be trusted without it). Runs inside sqflite's upgrade
  /// transaction, so it must not open a nested one.
  static Future<void> migrateToVersion6(Database db) async {
    await _addColumnIfMissing(
      db,
      'relay_queue',
      'incoming_peer_device_id',
      'TEXT',
    );
  }

  /// v7: media attachment metadata on the message itself (additive).
  ///
  /// Attachment bytes never enter SQLite; this column only holds the JSON
  /// metadata (name, MIME type, size, Storage path) so an attachment always
  /// travels with its message through the existing queue and transports. No
  /// existing row is rewritten and no table is recreated.
  static Future<void> migrateToVersion7(Database db) async {
    await _addColumnIfMissing(db, 'messages', 'attachment_json', 'TEXT');
  }

  /// Adds [column] to [table] unless it already exists.
  ///
  /// Throws a non-secret [StateError] when [table] is missing entirely rather
  /// than skipping silently, so an unexpected schema fails loudly instead of
  /// leaving a half-migrated database.
  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final existing = await _tableColumns(db, table);
    if (existing == null) {
      throw StateError(
        'Cannot migrate database: required table "$table" is missing.',
      );
    }
    if (existing.contains(column)) {
      return;
    }
    await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }

  /// Column names of [table], or null when the table does not exist.
  static Future<Set<String>?> _tableColumns(Database db, String table) async {
    final tables = await db.rawQuery(
      'SELECT name FROM sqlite_master WHERE type = ? AND name = ?',
      ['table', table],
    );
    if (tables.isEmpty) {
      return null;
    }
    final info = await db.rawQuery('PRAGMA table_info($table)');
    return info.map((row) => row['name'] as String).toSet();
  }

  /// Rewrites legacy timestamp columns to the canonical UTC representation.
  ///
  /// Older builds stored outgoing timestamps as naive local ISO strings while
  /// incoming BLE timestamps were stored as UTC. SQLite compares those TEXT
  /// values lexicographically, so a mixed database produced wrong ordering.
  /// This migration preserves the represented instant and only changes the
  /// serialization; no rows are deleted.
  static Future<void> migrateToUtcTimestamps(Database db) async {
    const columns = <(String, String)>[
      ('messages', 'timestamp'),
      ('messages', 'created_at'),
      ('messages', 'updated_at'),
      ('chats', 'last_message_time'),
      ('chats', 'created_at'),
      ('chats', 'updated_at'),
    ];
    for (final (table, column) in columns) {
      await _normalizeTimestampColumn(db, table, column);
    }
  }

  static Future<void> _normalizeTimestampColumn(
    Database db,
    String table,
    String column,
  ) async {
    final rows = await db.query(
      table,
      columns: ['id', column],
      where: '$column IS NOT NULL',
    );
    final batch = db.batch();
    var changed = false;
    for (final row in rows) {
      final raw = row[column] as String?;
      if (raw == null) continue;
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) continue;
      final canonical = TimestampUtils.toUtcIso8601(parsed);
      if (canonical == raw) continue;
      batch.update(
        table,
        {column: canonical},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      changed = true;
    }
    if (changed) {
      await batch.commit(noResult: true);
    }
  }

  static Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE identity (
        id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        public_key TEXT,
        private_key_reference TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        public_key_fingerprint TEXT,
        key_algorithm TEXT,
        identity_created_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE peers (
        id TEXT PRIMARY KEY,
        peer_id TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        device_name TEXT NOT NULL,
        avatar_path TEXT,
        status TEXT NOT NULL DEFAULT 'offline',
        signal_strength INTEGER,
        first_seen TEXT,
        last_seen TEXT,
        public_key TEXT,
        is_blocked INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        public_key_fingerprint TEXT,
        verification_state TEXT NOT NULL DEFAULT 'none',
        key_verified_at TEXT,
        key_changed_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE chats (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL UNIQUE,
        peer_id TEXT NOT NULL,
        title TEXT,
        last_message TEXT,
        last_message_time TEXT,
        unread_count INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (peer_id) REFERENCES peers(peer_id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        message_id TEXT NOT NULL UNIQUE,
        chat_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        receiver_id TEXT NOT NULL,
        content TEXT NOT NULL,
        message_type TEXT NOT NULL DEFAULT 'text',
        attachment_json TEXT,
        timestamp TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'sending',
        transport TEXT NOT NULL DEFAULT 'pending',
        ttl INTEGER NOT NULL DEFAULT 86400,
        is_encrypted INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (chat_id) REFERENCES chats(chat_id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE attachments (
        id TEXT PRIMARY KEY,
        attachment_id TEXT NOT NULL UNIQUE,
        message_id TEXT NOT NULL,
        file_name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        mime_type TEXT,
        file_size INTEGER,
        transfer_status TEXT NOT NULL DEFAULT 'pending',
        created_at TEXT NOT NULL,
        FOREIGN KEY (message_id) REFERENCES messages(message_id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE message_routes (
        id TEXT PRIMARY KEY,
        message_id TEXT NOT NULL,
        next_hop TEXT,
        target_peer TEXT NOT NULL,
        ttl INTEGER NOT NULL DEFAULT 86400,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'queued',
        queued_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (message_id) REFERENCES messages(message_id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    // v5 routing foundations. Kept in sync with [migrateToVersion5].
    await db.execute('''
      CREATE TABLE seen_messages (
        envelope_id TEXT PRIMARY KEY NOT NULL,
        first_seen_at TEXT NOT NULL,
        expires_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE relay_queue (
        envelope_id TEXT PRIMARY KEY NOT NULL,
        envelope BLOB NOT NULL,
        origin_device_id TEXT NOT NULL,
        destination_device_id TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        hop_limit INTEGER NOT NULL,
        hop_count INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_hop_device_id TEXT,
        incoming_peer_device_id TEXT,
        state TEXT NOT NULL DEFAULT 'queued',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _createIndexes(Database db) async {
    await db.execute('CREATE INDEX idx_messages_chat_id ON messages(chat_id)');
    await db.execute(
      'CREATE INDEX idx_messages_timestamp ON messages(timestamp)',
    );
    await db.execute('CREATE INDEX idx_messages_sender ON messages(sender_id)');
    await db.execute(
      'CREATE INDEX idx_messages_receiver ON messages(receiver_id)',
    );
    await db.execute('CREATE INDEX idx_chats_peer_id ON chats(peer_id)');
    await db.execute(
      'CREATE INDEX idx_chats_last_message_time ON chats(last_message_time)',
    );
    await db.execute('CREATE INDEX idx_peers_peer_id ON peers(peer_id)');
    await db.execute('CREATE INDEX idx_peers_status ON peers(status)');
    await db.execute(
      'CREATE INDEX idx_message_routes_target ON message_routes(target_peer)',
    );
    await db.execute(
      'CREATE INDEX idx_message_routes_status ON message_routes(status)',
    );
    await db.execute(
      'CREATE INDEX idx_attachments_message ON attachments(message_id)',
    );
    // v5 routing foundations. Kept in sync with [migrateToVersion5].
    await db.execute(
      'CREATE INDEX idx_seen_messages_expires_at ON seen_messages(expires_at)',
    );
    await db.execute(
      'CREATE INDEX idx_relay_queue_expires_at ON relay_queue(expires_at)',
    );
    await db.execute(
      'CREATE INDEX idx_relay_queue_state ON relay_queue(state)',
    );
  }

  static Future<void> closeDatabase() async {
    final db = await database;
    await db.close();
    _database = null;
  }

  static Future<void> deleteDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);
    await databaseFactory.deleteDatabase(path);
    _database = null;
  }
}
