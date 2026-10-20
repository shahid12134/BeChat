import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

void main() {
  late Database db;
  late IdentityRepository repository;

  final uuidV4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  setUp(() async {
    db = await openTestDatabase();
    repository = IdentityRepository(database: () async => db);
  });

  tearDown(() async {
    await db.close();
  });

  test('fresh initialization creates one UUID identity', () async {
    final identity = await repository.ensureIdentity();

    expect(identity.id, isNotNull);
    expect(identity.id, identity.deviceId);
    expect(uuidV4.hasMatch(identity.deviceId), isTrue);
    expect(identity.displayName, AppConstants.defaultDeviceName);

    final rows = await db.query('identity');
    expect(rows, hasLength(1));
  });

  test('repeated initialization returns the same identity', () async {
    final first = await repository.ensureIdentity();
    final second = await repository.ensureIdentity();
    final third = await repository.ensureIdentity();

    expect(second.deviceId, first.deviceId);
    expect(third.deviceId, first.deviceId);
    expect(await db.query('identity'), hasLength(1));
  });

  test('two independent fresh databases receive different IDs', () async {
    final otherDb = await openTestDatabase();
    addTearDown(otherDb.close);

    final first = await repository.ensureIdentity();
    final second = await IdentityRepository(
      database: () async => otherDb,
    ).ensureIdentity();

    expect(first.deviceId, isNot(second.deviceId));
  });

  test('legacy identity and its message references are repaired', () async {
    final now = DateTime.now().toIso8601String();
    await _seedLegacyData(db, now);

    final identity = await repository.ensureIdentity();

    expect(identity.deviceId, isNot(AppConstants.legacyPlaceholderDeviceId));
    expect(uuidV4.hasMatch(identity.deviceId), isTrue);
    expect(identity.id, isNotNull);
    expect(identity.displayName, 'Legacy User');

    final identityRows = await db.query('identity');
    expect(identityRows, hasLength(1));
    expect(
      identityRows.single['device_id'],
      isNot(AppConstants.legacyPlaceholderDeviceId),
    );

    final messages = await db.query('messages', orderBy: 'message_id ASC');
    expect(messages[0]['receiver_id'], identity.deviceId);
    expect(messages[1]['sender_id'], identity.deviceId);
    expect(messages[2]['sender_id'], 'peer-alice-001');
    expect(messages[2]['receiver_id'], 'peer-bob-002');

    final peer = await db.query(
      'peers',
      where: 'peer_id = ?',
      whereArgs: ['peer-alice-001'],
    );
    expect(peer, hasLength(1));
  });

  test('legacy repair rolls back if a message update fails', () async {
    final now = DateTime.now().toIso8601String();
    await _seedLegacyData(db, now);
    await db.execute('''
      CREATE TRIGGER fail_receiver_repair
      BEFORE UPDATE OF receiver_id ON messages
      WHEN OLD.receiver_id = '${AppConstants.legacyPlaceholderDeviceId}'
      BEGIN
        SELECT RAISE(ABORT, 'receiver repair blocked');
      END
    ''');

    await expectLater(repository.ensureIdentity(), throwsA(anything));

    final identityRows = await db.query('identity');
    expect(
      identityRows.single['device_id'],
      AppConstants.legacyPlaceholderDeviceId,
    );

    final messages = await db.query('messages', orderBy: 'message_id ASC');
    expect(messages[0]['receiver_id'], AppConstants.legacyPlaceholderDeviceId);
    expect(messages[1]['sender_id'], AppConstants.legacyPlaceholderDeviceId);
  });
}

Future<void> _seedLegacyData(Database db, String now) async {
  await db.insert('identity', {
    'device_id': AppConstants.legacyPlaceholderDeviceId,
    'display_name': 'Legacy User',
    'created_at': now,
    'updated_at': now,
  });
  await db.insert('peers', {
    'peer_id': 'peer-alice-001',
    'display_name': 'Alice',
    'device_name': 'Alice Phone',
    'status': 'online',
    'is_blocked': 0,
    'created_at': now,
    'updated_at': now,
  });
  await db.insert('chats', {
    'chat_id': 'chat-alice-001',
    'peer_id': 'peer-alice-001',
    'title': 'Alice',
    'unread_count': 0,
    'created_at': now,
    'updated_at': now,
  });
  await db.insert('messages', {
    'message_id': 'msg-outgoing',
    'chat_id': 'chat-alice-001',
    'sender_id': AppConstants.legacyPlaceholderDeviceId,
    'receiver_id': 'peer-alice-001',
    'content': 'outgoing',
    'message_type': 'text',
    'timestamp': now,
    'status': 'delivered',
    'transport': 'local',
    'ttl': 86400,
    'is_encrypted': 0,
    'created_at': now,
    'updated_at': now,
  });
  await db.insert('messages', {
    'message_id': 'msg-incoming',
    'chat_id': 'chat-alice-001',
    'sender_id': 'peer-alice-001',
    'receiver_id': AppConstants.legacyPlaceholderDeviceId,
    'content': 'incoming',
    'message_type': 'text',
    'timestamp': now,
    'status': 'delivered',
    'transport': 'local',
    'ttl': 86400,
    'is_encrypted': 0,
    'created_at': now,
    'updated_at': now,
  });
  await db.insert('messages', {
    'message_id': 'msg-unrelated',
    'chat_id': 'chat-alice-001',
    'sender_id': 'peer-alice-001',
    'receiver_id': 'peer-bob-002',
    'content': 'unrelated',
    'message_type': 'text',
    'timestamp': now,
    'status': 'delivered',
    'transport': 'local',
    'ttl': 86400,
    'is_encrypted': 0,
    'created_at': now,
    'updated_at': now,
  });
}
