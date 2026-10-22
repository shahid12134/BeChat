import 'package:bechat/features/peers/widgets/incoming_request_dialog.dart';
import 'package:bechat/providers/ble_providers.dart';
import 'package:bechat/services/ble/ble_runtime.dart';
import 'package:bechat/services/ble/incoming_connection_request.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('request dialog shows identity context and actions', (
    tester,
  ) async {
    final controller = await _pumpDialog(tester);

    expect(find.text('Connection request'), findsOneWidget);
    expect(find.textContaining('Alice wants to connect'), findsOneWidget);
    expect(find.textContaining('Device ID: 90abcdef'), findsOneWidget);
    expect(find.textContaining('-61 dBm'), findsOneWidget);
    expect(
      find.textContaining('not cryptographically verified'),
      findsOneWidget,
    );
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(find.text('Block'), findsOneWidget);
    expect(controller.acceptedRequestId, isNull);
  });

  testWidgets('accept action forwards the current request id', (tester) async {
    final controller = await _pumpDialog(tester);

    await tester.tap(find.text('Accept'));
    await tester.pump();

    expect(controller.acceptedRequestId, 'request-1');
  });

  testWidgets('decline action forwards the current request id', (tester) async {
    final controller = await _pumpDialog(tester);

    await tester.tap(find.text('Decline'));
    await tester.pump();

    expect(controller.declinedRequestId, 'request-1');
  });

  testWidgets('block action forwards the current request id', (tester) async {
    final controller = await _pumpDialog(tester);

    await tester.tap(find.text('Block'));
    await tester.pump();

    expect(controller.blockedRequestId, 'request-1');
  });

  testWidgets('host opens the dialog and closes it when the request clears', (
    tester,
  ) async {
    late _FakeBleRuntimeController controller;
    final container = ProviderContainer(
      overrides: [
        bleRuntimeProvider.overrideWith((ref) {
          controller = _FakeBleRuntimeController(ref, _request());
          return controller;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: IncomingConnectionRequestHost(
            child: Scaffold(body: Text('Nearby')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Connection request'), findsOneWidget);

    controller.clearIncomingRequestForTest();
    await tester.pumpAndSettle();

    expect(find.text('Connection request'), findsNothing);
  });
}

Future<_FakeBleRuntimeController> _pumpDialog(WidgetTester tester) async {
  late _FakeBleRuntimeController controller;
  final request = _request();
  final container = ProviderContainer(
    overrides: [
      bleRuntimeProvider.overrideWith((ref) {
        controller = _FakeBleRuntimeController(ref, request);
        return controller;
      }),
    ],
  );
  addTearDown(container.dispose);
  container.read(bleRuntimeProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: IncomingConnectionRequestDialog(request: request),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

IncomingConnectionRequest _request() {
  final now = DateTime(2026, 10, 22, 12);
  return IncomingConnectionRequest(
    requestId: 'request-1',
    peerId: 'device-1234567890abcdef',
    displayName: 'Alice',
    deviceName: 'Alice Phone',
    signalStrength: -61,
    requestedAt: now,
    expiresAt: now.add(const Duration(seconds: 30)),
  );
}

class _FakeBleRuntimeController extends BleRuntimeController {
  _FakeBleRuntimeController(super.ref, IncomingConnectionRequest request) {
    state = BleRuntimeState(incomingRequest: request);
  }

  String? acceptedRequestId;
  String? declinedRequestId;
  String? blockedRequestId;

  @override
  Future<void> acceptIncomingRequest(String requestId) async {
    acceptedRequestId = requestId;
  }

  @override
  Future<void> declineIncomingRequest(String requestId) async {
    declinedRequestId = requestId;
  }

  @override
  Future<void> blockIncomingRequest(String requestId) async {
    blockedRequestId = requestId;
  }

  void clearIncomingRequestForTest() {
    state = state.copyWith(clearIncomingRequest: true);
  }
}
