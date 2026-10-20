import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:bechat/core/utils/date_utils.dart';

void main() {
  sqfliteFfiInit();

  group('AppDateUtils', () {
    test('formats chat timestamp for today', () {
      final now = DateTime.now();
      final result = AppDateUtils.formatChatTimestamp(now);
      expect(result, isNotEmpty);
      // Should contain AM or PM
      expect(result.contains('AM') || result.contains('PM'), true);
    });

    test('formats chat timestamp for yesterday', () {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final result = AppDateUtils.formatChatTimestamp(yesterday);
      expect(result, 'Yesterday');
    });

    test('formats message timestamp', () {
      final now = DateTime.now();
      final result = AppDateUtils.formatMessageTimestamp(now);
      expect(result, isNotEmpty);
    });

    test('formats relative time for recent', () {
      final now = DateTime.now();
      final result = AppDateUtils.formatRelativeTime(now);
      expect(result, 'Just now');
    });

    test('formats relative time for minutes ago', () {
      final fiveMinAgo = DateTime.now().subtract(const Duration(minutes: 5));
      final result = AppDateUtils.formatRelativeTime(fiveMinAgo);
      expect(result, '5m ago');
    });

    test('formats relative time for hours ago', () {
      final threeHoursAgo = DateTime.now().subtract(const Duration(hours: 3));
      final result = AppDateUtils.formatRelativeTime(threeHoursAgo);
      expect(result, '3h ago');
    });

    test('renders UTC timestamps in the device timezone', () {
      final utc = DateTime.utc(2026, 8, 9, 10, 30);
      expect(
        AppDateUtils.formatMessageTimestamp(utc),
        DateFormat('h:mm a').format(utc.toLocal()),
      );
    });

    test('returns empty string for null datetime', () {
      expect(AppDateUtils.formatChatTimestamp(null), '');
      expect(AppDateUtils.formatMessageTimestamp(null), '');
      expect(AppDateUtils.formatRelativeTime(null), '');
    });
  });
}
