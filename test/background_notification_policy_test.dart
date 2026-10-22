import 'package:bechat/services/background/background_ble_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('message notification hides content when previews are disabled', () {
    expect(
      BackgroundNotificationPolicy.messageBody(
        previewsEnabled: false,
        content: 'Private message',
      ),
      'New message',
    );
  });

  test('message notification includes content when previews are enabled', () {
    expect(
      BackgroundNotificationPolicy.messageBody(
        previewsEnabled: true,
        content: 'Private message',
      ),
      'Private message',
    );
  });
}
