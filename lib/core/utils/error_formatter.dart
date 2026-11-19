import 'dart:async';

import 'package:flutter/services.dart';

/// Turns any caught error into a single-line, human-readable sentence for the
/// normal UI.
///
/// Never returns a stack trace. `PlatformException.toString()` embeds the whole
/// Java stack trace (`code, message, details, stacktrace`) and several Dart
/// errors embed multi-line diagnostics — both used to land verbatim in the
/// Nearby and Settings banners.
///
/// The full detail is still available through [describeErrorDiagnostics].
String describeErrorForUser(Object error) {
  if (error is StackTrace) {
    return 'An unexpected internal error occurred.';
  }
  if (error is TimeoutException) {
    return 'The operation timed out.';
  }
  if (error is PlatformException) {
    return _platformMessage(error);
  }
  return _oneLine(error.toString());
}

/// The full technical detail of [error] — code, native message, details and
/// stack trace.
///
/// For logs and an expandable "Technical details" section only; never for the
/// normal UI, and never as the sole message.
String describeErrorDiagnostics(Object error, [StackTrace? stackTrace]) {
  if (error is PlatformException) {
    final parts = <String>[
      'code: ${error.code}',
      if (error.message != null && error.message!.isNotEmpty)
        'message: ${error.message}',
      if (error.details != null) 'details: ${error.details}',
      if (error.stacktrace != null && error.stacktrace!.isNotEmpty)
        'stacktrace: ${error.stacktrace}',
    ];
    return parts.join('\n');
  }
  final text = error.toString().trim();
  final detail = text.isEmpty ? error.runtimeType.toString() : text;
  return stackTrace == null ? detail : '$detail\n$stackTrace';
}

/// The user-facing sentence for a [PlatformException].
String _platformMessage(PlatformException error) {
  final message = error.message;
  if (message == null || message.isEmpty) {
    return _friendlyGatt(error) ?? 'A system error occurred.';
  }
  // The native side prefixes its message with the Java exception type, e.g.
  // "java.lang.IllegalStateException: Write descriptor failed with status: 1."
  // — the type name is noise for the user.
  final cleaned = message.replaceFirst(_javaExceptionPrefix, '');
  final friendly = _friendlyGatt(error, cleaned);
  return friendly ?? _oneLine(cleaned);
}

/// Matches a *Java* exception prefix (which always contains package dots, e.g.
/// `java.lang.IllegalStateException:`) but never Dart's own `StateError:`.
final _javaExceptionPrefix = RegExp(r'^\s*[\w.$]*\.[\w.$]*(?:Exception|Error):\s*');

/// Rewrites the GATT failures BeChat actually sees into a sentence that tells
/// the user what to do next, instead of quoting Android's wording.
String? _friendlyGatt(PlatformException error, [String? message]) {
  final text = message ?? error.message ?? '';
  if (text.contains('Write descriptor failed')) {
    return 'Bluetooth could not enable notifications on that device.';
  }
  if (text.contains('GATT is disconnected')) {
    return 'The Bluetooth connection was lost.';
  }
  if (text.contains('Discover services failed')) {
    return 'Bluetooth could not read that device\'s capabilities.';
  }
  if (text.contains('Connect failed')) {
    return 'Could not reach that device over Bluetooth.';
  }
  return null;
}

/// First non-empty line of [text], with any leading Java exception type
/// removed. Falls back to a generic sentence rather than leaking internals.
String _oneLine(String text) {
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (_looksLikeStackTraceFrame(line)) continue;
    final cleaned = line.replaceFirst(_javaExceptionPrefix, '');
    if (cleaned.trim().isNotEmpty) return cleaned.trim();
  }
  return 'An unexpected error occurred.';
}

/// Matches a Dart/Java stack frame, so traces interleaved with a message are
/// never surfaced as the headline.
bool _looksLikeStackTraceFrame(String line) =>
    line.startsWith('at ') ||
    line.startsWith('#') ||
    line.endsWith('.dart') ||
    RegExp(r'^[\w<>/.$]+\.[\w<>]+\(.*\)$').hasMatch(line);
