import 'package:bechat/core/utils/timestamp_utils.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) => DatabaseHelper.createSchema(db),
      ),
    );
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'normalizes legacy local and UTC timestamps without losing instants',
    () async {
      final naiveLocal = DateTime(2026, 6, 1, 9, 30, 15, 250);
      final utcTime = DateTime.utc(2026, 6, 1, 4, 0, 5, 125);

      await db.insert('chats', {
        'id': 'chat-row-1',
        'chat_id': 'chat-1',
        'peer_id': 'peer-1',
        'title': 'Peer',
        'last_message': 'Hello',
        'last_message_time': naiveLocal.toIso8601String(),
        'unread_count': 0,
        'created_at': naiveLocal.toIso8601String(),
        'updated_at': naiveLocal.toIso8601String(),
      });
      await db.insert('messages', {
        'id': 'msg-row-1',
        'message_id': 'msg-local',
        'chat_id': 'chat-1',
        'sender_id': 'device-local',
        'receiver_id': 'peer-1',
        'content': 'Local',
        'timestamp': naiveLocal.toIso8601String(),
        'status': 'queued',
        'transport': 'pending',
        'created_at': naiveLocal.toIso8601String(),
        'updated_at': naiveLocal.toIso8601String(),
      });
      await db.insert('messages', {
        'id': 'msg-row-2',
        'message_id': 'msg-utc',
        'chat_id': 'chat-1',
        'sender_id': 'peer-1',
        'receiver_id': 'device-local',
        'content': 'UTC',
        'timestamp': utcTime.toIso8601String(),
        'status': 'delivered',
        'transport': 'ble',
        'created_at': utcTime.toIso8601String(),
        'updated_at': utcTime.toIso8601String(),
      });

      await DatabaseHelper.migrateToUtcTimestamps(db);

      final localRow = (await db.query(
        'messages',
        where: 'message_id = ?',
        whereArgs: ['msg-local'],
      )).single;
      final utcRow = (await db.query(
        'messages',
        where: 'message_id = ?',
        whereArgs: ['msg-utc'],
      )).single;
      final chat = (await db.query('chats')).single;

      expect(localRow['timestamp'], TimestampUtils.toUtcIso8601(naiveLocal));
      expect(
        DateTime.parse(
          localRow['timestamp'] as String,
        ).isAtSameMomentAs(naiveLocal),
        isTrue,
      );
      expect(localRow['created_at'], endsWith('Z'));
      expect(localRow['updated_at'], endsWith('Z'));
      expect(utcRow['timestamp'], TimestampUtils.toUtcIso8601(utcTime));
      expect(
        DateTime.parse(utcRow['timestamp'] as String).isAtSameMomentAs(utcTime),
        isTrue,
      );
      expect(
        chat['last_message_time'],
        TimestampUtils.toUtcIso8601(naiveLocal),
      );
      expect(chat['created_at'], endsWith('Z'));
      expect(chat['updated_at'], endsWith('Z'));
    },
  );

  test('normalization is idempotent', () async {
    final now = DateTime.utc(2026, 7, 8, 9, 10, 11, 12);
    await db.insert('messages', {
      'id': 'msg-row-1',
      'message_id': 'msg-1',
      'chat_id': 'chat-1',
      'sender_id': 'device-local',
      'receiver_id': 'peer-1',
      'content': 'Hello',
      'timestamp': now.toIso8601String(),
      'status': 'queued',
      'transport': 'pending',
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });

    await DatabaseHelper.migrateToUtcTimestamps(db);
    final first = (await db.query('messages')).single['timestamp'];
    await DatabaseHelper.migrateToUtcTimestamps(db);
    final second = (await db.query('messages')).single['timestamp'];

    expect(first, second);
    expect(first, TimestampUtils.toUtcIso8601(now));
  });
}
