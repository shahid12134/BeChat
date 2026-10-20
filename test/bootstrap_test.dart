import 'package:bechat/app/bootstrap_host.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('bootstrap failure shows a recoverable error screen', (
    tester,
  ) async {
    var attempts = 0;

    await tester.pumpWidget(
      BootstrapHost(
        bootstrap: () async {
          attempts++;
          throw StateError('database unavailable');
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Startup failed'), findsOneWidget);
    expect(find.textContaining('database unavailable'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(attempts, 1);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('Startup failed'), findsOneWidget);
  });

  testWidgets('bootstrap success builds the app', (tester) async {
    await tester.pumpWidget(
      ProviderScope(child: BootstrapHost(bootstrap: () async {})),
    );
    await tester.pumpAndSettle();

    expect(find.text('BeChat'), findsOneWidget);
  });
}
