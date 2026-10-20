import 'package:intl/intl.dart';

class AppDateUtils {
  static String formatChatTimestamp(DateTime? dateTime) {
    if (dateTime == null) return '';
    final local = dateTime.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(local.year, local.month, local.day);

    if (messageDate == today) {
      return DateFormat('h:mm a').format(local);
    }
    if (messageDate == today.subtract(const Duration(days: 1))) {
      return 'Yesterday';
    }
    if (now.difference(local).inDays < 7) {
      return DateFormat('EEEE').format(local);
    }
    return DateFormat('MMM d').format(local);
  }

  static String formatMessageTimestamp(DateTime? dateTime) {
    if (dateTime == null) return '';
    return DateFormat('h:mm a').format(dateTime.toLocal());
  }

  static String formatFullTimestamp(DateTime? dateTime) {
    if (dateTime == null) return '';
    final local = dateTime.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(local.year, local.month, local.day);

    if (messageDate == today) {
      return 'Today at ${DateFormat('h:mm a').format(local)}';
    }
    if (messageDate == today.subtract(const Duration(days: 1))) {
      return 'Yesterday at ${DateFormat('h:mm a').format(local)}';
    }
    return DateFormat('MMM d, y h:mm a').format(local);
  }

  static String formatRelativeTime(DateTime? dateTime) {
    if (dateTime == null) return '';
    final local = dateTime.toLocal();
    final diff = DateTime.now().difference(local);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return DateFormat('MMM d').format(local);
  }
}
