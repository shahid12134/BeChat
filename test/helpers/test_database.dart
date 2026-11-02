import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openTestDatabase({bool singleInstance = false}) async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: AppConstants.databaseVersion,
      singleInstance: singleInstance,
      onCreate: (db, version) => DatabaseHelper.createSchema(db),
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    ),
  );
}

/// Frozen copy of the database **version 3** schema.
///
/// Migration tests must start from the real previous shape, so this file spells
/// the version 3 tables out instead of calling [DatabaseHelper.createSchema].
/// `createSchema` always describes the *current* schema (version 4 and later),
/// which would let a broken migration test pass by accident. This fixture is
/// historical evidence and must not be updated to match new schema versions.
Future<void> createVersion3Schema(Database db) async {
  await db.execute('''
    CREATE TABLE identity (
      id TEXT PRIMARY KEY,
      device_id TEXT NOT NULL UNIQUE,
      display_name TEXT NOT NULL,
      public_key TEXT,
      private_key_reference TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
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
      updated_at TEXT NOT NULL
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
}

/// Frozen copy of the database **version 4** schema.
///
/// Same rule as [createVersion3Schema]: migration tests start from the real
/// previous shape, spelled out here, rather than calling
/// [DatabaseHelper.createSchema] (which always describes the *current*
/// schema). This fixture is historical evidence and must not be updated to
/// match new schema versions.
Future<void> createVersion4Schema(Database db) async {
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
}
