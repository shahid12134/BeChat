import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bechat/core/utils/error_formatter.dart';

void main() {
  // The exact error reported from Android in the field.
  final gattError = PlatformException(
    code: 'error',
    message:
        'java.lang.IllegalStateException: Write descriptor failed with '
        'status: 1.',
    details: null,
    stacktrace: '#0   CentralManagerImpl.onDescriptorWrite\n'
        '#1   BluetoothGattCallbackImpl.onDescriptorWrite\n'
        'at dev.zeekr.bluetooth_low_energy_android.CentralManagerImpl',
  );

  group('describeErrorForUser', () {
    test('never leaks the Java stack trace of a PlatformException', () {
      final shown = describeErrorForUser(gattError);
      expect(shown, isNot(contains('java.lang')));
      expect(shown, isNot(contains('#0')));
      expect(shown, isNot(contains('at dev.zeekr')));
      expect(shown, isNot(contains('stacktrace')));
      expect(shown.split('\n'), hasLength(1));
    });

    test('rewrites the descriptor-write failure into an actionable sentence', () {
      expect(
        describeErrorForUser(gattError),
        'Bluetooth could not enable notifications on that device.',
      );
    });

    test('keeps a meaningful message when the native side gives none', () {
      expect(
        describeErrorForUser(PlatformException(code: 'error', message: '')),
        'A system error occurred.',
      );
      expect(
        describeErrorForUser(PlatformException(code: 'error')),
        'A system error occurred.',
      );
    });

    test('passes through an unrelated native message as one line', () {
      expect(
        describeErrorForUser(
          PlatformException(
            code: 'error',
            message: 'java.lang.SecurityException: permission denied',
          ),
        ),
        'permission denied',
      );
    });

    test('never returns a multi-line Dart error or a bare stack trace', () {
      expect(describeErrorForUser(StateError('no value')), 'Bad state: no value');
      expect(describeErrorForUser(StackTrace.current), isNot(contains('#0')));
      expect(describeErrorForUser(StackTrace.current), isNotEmpty);
      expect(
        describeErrorForUser(
          Exception('first line\n#0 frame\nat Thing.run (x.dart:1)'),
        ),
        'Exception: first line',
      );
    });

    test('a timeout reads as a timeout', () {
      expect(
        describeErrorForUser(
          TimeoutException('slow', const Duration(seconds: 5)),
        ),
        'The operation timed out.',
      );
    });
  });

  group('describeErrorDiagnostics', () {
    test('keeps every detail the UI must not show', () {
      final detail = describeErrorDiagnostics(gattError);
      expect(detail, contains('code: error'));
      expect(detail, contains('Write descriptor failed with status: 1.'));
      expect(detail, contains('CentralManagerImpl.onDescriptorWrite'));
      expect(detail, contains('stacktrace:'));
    });

    test('appends the Dart stack trace when one is supplied', () {
      final detail = describeErrorDiagnostics(
        StateError('no value'),
        StackTrace.current,
      );
      expect(detail, contains('Bad state: no value'));
      expect(detail, contains('\n'));
    });
  });
}
