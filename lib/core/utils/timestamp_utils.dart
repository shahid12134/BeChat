class TimestampUtils {
  const TimestampUtils._();

  /// Canonical UTC ISO-8601 form used for every persisted timestamp.
  ///
  /// SQLite orders the TEXT columns lexicographically, so all rows must use the
  /// same timezone (UTC) and the same precision (microseconds). Mixed naive
  /// local timestamps and UTC timestamps otherwise sort incorrectly.
  static String toUtcIso8601(DateTime value) {
    final utc = value.toUtc();
    final micros = utc.microsecondsSinceEpoch;
    final wholeSeconds = micros - (micros % Duration.microsecondsPerSecond);
    final fraction = (micros % Duration.microsecondsPerSecond)
        .toString()
        .padLeft(6, '0');
    final base = DateTime.fromMicrosecondsSinceEpoch(
      wholeSeconds,
      isUtc: true,
    ).toIso8601String();
    return '${base.substring(0, 19)}.${fraction}Z';
  }

  static String nowUtcIso8601() => toUtcIso8601(DateTime.now());
}
