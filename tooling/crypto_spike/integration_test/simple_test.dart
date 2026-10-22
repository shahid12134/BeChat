import 'package:crypto_spike/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Spike UI renders', (tester) async {
    await tester.pumpWidget(const SpikeApp());
    expect(find.text('Run self-test'), findsOneWidget);
    expect(
      find.textContaining('does not provide production E2EE'),
      findsOneWidget,
    );
  });
}
