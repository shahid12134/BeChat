import 'package:bechat/services/ble/ble_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retries a transient operation and returns the success value', () async {
    var attempts = 0;
    final result = await retryBleOperation(() async {
      attempts++;
      if (attempts < 3) throw StateError('descriptor write failed: 129');
      return 'ok';
    }, delay: (_) => Duration.zero);

    expect(result, 'ok');
    expect(attempts, 3);
  });

  test('rethrows the last error after exhausting the attempts', () async {
    var attempts = 0;
    await expectLater(
      retryBleOperation(() async {
        attempts++;
        throw StateError('descriptor write failed: $attempts');
      }, delay: (_) => Duration.zero),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'descriptor write failed: 3',
        ),
      ),
    );
    expect(attempts, 3);
  });

  test('does not retry a successful operation', () async {
    var attempts = 0;
    final result = await retryBleOperation(() async {
      attempts++;
      return 42;
    });

    expect(result, 42);
    expect(attempts, 1);
  });
}
