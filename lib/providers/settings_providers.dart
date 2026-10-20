import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/data/models/identity.dart';
import 'package:bechat/data/repositories/identity_repository.dart';
import 'package:bechat/data/database/database_helper.dart';

final identityRepositoryProvider = Provider<IdentityRepository>((ref) {
  return IdentityRepository();
});

final identityProvider = StateNotifierProvider<IdentityNotifier, AsyncValue<Identity?>>((ref) {
  return IdentityNotifier(ref.read(identityRepositoryProvider));
});

class IdentityNotifier extends StateNotifier<AsyncValue<Identity?>> {
  final IdentityRepository _repository;

  IdentityNotifier(this._repository) : super(const AsyncValue.loading()) {
    loadIdentity();
  }

  Future<void> loadIdentity() async {
    state = const AsyncValue.loading();
    try {
      final identity = await _repository.getIdentity();
      state = AsyncValue.data(identity);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> updateDisplayName(String name) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final updated = current.copyWith(
      displayName: name,
      updatedAt: DateTime.now(),
    );
    await _repository.updateIdentity(updated);
    state = AsyncValue.data(updated);
  }
}

final databaseInfoProvider = FutureProvider<Map<String, int>>((ref) async {
  final db = await DatabaseHelper.database;
  final tables = ['peers', 'chats', 'messages', 'attachments', 'identity', 'message_routes'];
  final counts = <String, int>{};
  for (final table in tables) {
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM $table');
    counts[table] = (result.first['count'] as int?) ?? 0;
  }
  return counts;
});
