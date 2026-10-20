import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/app/app.dart';
import 'package:bechat/data/database/database_helper.dart';
import 'package:bechat/data/mock/mock_data.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseHelper.database;
  await MockData.seedIfEmpty();

  runApp(
    const ProviderScope(
      child: BeChatApp(),
    ),
  );
}
