import 'package:sqflite/sqflite.dart';
import 'package:bechat/data/database/database_helper.dart';

class AppDataRepository {
  AppDataRepository({Future<Database> Function()? database})
    : _openDatabase = database ?? (() => DatabaseHelper.database);

  final Future<Database> Function() _openDatabase;

  Future<Database> get _db => _openDatabase();

  Future<void> clearUserData() async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete('message_routes');
      await txn.delete('attachments');
      await txn.delete('messages');
      await txn.delete('chats');
      await txn.delete('peers');
    });
  }
}
