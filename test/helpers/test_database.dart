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
