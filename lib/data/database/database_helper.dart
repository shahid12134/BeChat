import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:bechat/core/constants/app_constants.dart';

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
    await _createTables(db);
    await _createIndexes(db);
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Future migrations go here
    // if (oldVersion < 2) { await _migrateToV2(db); }
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
  }

  static Future<void> _createIndexes(Database db) async {
    await db.execute('CREATE INDEX idx_messages_chat_id ON messages(chat_id)');
    await db.execute('CREATE INDEX idx_messages_timestamp ON messages(timestamp)');
    await db.execute('CREATE INDEX idx_messages_sender ON messages(sender_id)');
    await db.execute('CREATE INDEX idx_messages_receiver ON messages(receiver_id)');
    await db.execute('CREATE INDEX idx_chats_peer_id ON chats(peer_id)');
    await db.execute('CREATE INDEX idx_chats_last_message_time ON chats(last_message_time)');
    await db.execute('CREATE INDEX idx_peers_peer_id ON peers(peer_id)');
    await db.execute('CREATE INDEX idx_peers_status ON peers(status)');
    await db.execute('CREATE INDEX idx_message_routes_target ON message_routes(target_peer)');
    await db.execute('CREATE INDEX idx_message_routes_status ON message_routes(status)');
    await db.execute('CREATE INDEX idx_attachments_message ON attachments(message_id)');
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
