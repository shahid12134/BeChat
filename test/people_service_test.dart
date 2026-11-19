/// Pure BeChat-ID logic: generation, normalization and the deterministic
/// request id. `PeopleService` itself drives Firestore (platform channels),
/// which cannot run under `flutter test` — its rules are covered by
/// `firestore_rules_test.dart` against the emulators.
library;

import 'dart:math';

import 'package:bechat/services/online/device_registry.dart';
import 'package:bechat/services/online/people_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('generatePublicId', () {
    test('produces the canonical BC-XXXX-XXXX shape', () {
      for (var i = 0; i < 200; i++) {
        final id = generatePublicId(Random(i));
        expect(id, matches(RegExp(r'^BC-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}$')),
            reason: 'id #$i: $id');
      }
    });

    test('never uses ambiguous characters (0/O/1/I/L)', () {
      for (var i = 0; i < 500; i++) {
        final id = generatePublicId(Random(i));
        expect(id, isNot(contains(RegExp('[0O1IL]'))), reason: id);
      }
    });

    test('a fixed seed is deterministic, different seeds differ', () {
      expect(generatePublicId(Random(7)), generatePublicId(Random(7)));
      expect(
        generatePublicId(Random(7)),
        isNot(generatePublicId(Random(8))),
      );
    });
  });

  group('normalizePublicId', () {
    test('accepts the canonical form', () {
      expect(normalizePublicId('BC-7K9P-42MX'), 'BC-7K9P-42MX');
    });

    test('tolerates lower case, spaces and stray punctuation', () {
      expect(normalizePublicId('bc-7k9p-42mx'), 'BC-7K9P-42MX');
      expect(normalizePublicId(' bc 7k9p 42mx '), 'BC-7K9P-42MX');
      expect(normalizePublicId('BC7K9P42MX'), 'BC-7K9P-42MX');
      expect(normalizePublicId('BC_7K9P_42MX'), 'BC-7K9P-42MX');
    });

    test('rejects input that cannot be an ID', () {
      expect(normalizePublicId(''), isNull);
      expect(normalizePublicId('hello'), isNull);
      expect(normalizePublicId('BC-7K9P'), isNull); // too short
      expect(normalizePublicId('XX-7K9P-42MX'), isNull); // wrong prefix
      // Ambiguous characters are refused rather than guessed.
      expect(normalizePublicId('BC-7K9O-42MX'), isNull); // O
      expect(normalizePublicId('BC-7KI9-42MX'), isNull); // I
      expect(normalizePublicId('BC-7K9P-42M0'), isNull); // 0
      expect(normalizePublicId('BC-7K9P-42MX-extra'), isNull);
    });
  });

  group('connectionRequestId', () {
    test('is deterministic and resolves both directions to one document', () {
      expect(
        connectionRequestId('uid-a', 'uid-b'),
        connectionRequestId('uid-a', 'uid-b'),
      );
      expect(connectionRequestId('uid-a', 'uid-b'), 'uid-a.uid-b');
      // Symmetry is the duplicate guard: whichever side submits first,
      // repeated and concurrent attempts all target the same document
      // (and only one create can win).
      expect(
        connectionRequestId('uid-a', 'uid-b'),
        connectionRequestId('uid-b', 'uid-a'),
      );
      expect(connectionRequestId('uid-b', 'uid-a'), 'uid-a.uid-b');
    });

    test('uids containing the separator characters stay unambiguous', () {
      // A '.' can never occur in a Firebase uid, so splitting at the first
      // '.' recovers one uid exactly — the property firestore.rules relies
      // on when it reconstructs the pair from the path.
      const first = 'ab';
      const second = 'cd_ef';
      final id = connectionRequestId(first, second);
      expect(id, 'ab.cd_ef');
      expect(id.split('.').first, first);
      expect(id.split('.').last, second);
      expect(
        connectionRequestId(second, first),
        id,
        reason: 'the sorted pair is the same document from either side',
      );
    });
  });

  group('connection request preconditions', () {
    test('a fully registered pair has nothing blocking it', () {
      expect(
        connectionRequestBlocker(
          targetUid: 'uid-b',
          targetProfileUid: 'uid-b',
          targetDeviceOwnerUid: 'uid-b',
        ),
        isNull,
      );
    });

    test('a missing local registration is created, not reported as a failure',
        () {
      // The shape of the reported bug: the local device had no deviceRegistry
      // entry, so rules refused the request. A null owner must be treated as
      // "register it now", never as a conflict.
      expect(resolveBinding(null, 'uid-a'), RegistryBinding.created);
      expect(resolveBinding('uid-a', 'uid-a'), RegistryBinding.alreadyOwned);
    });

    test('a missing recipient registration has its own message', () {
      final blocker = connectionRequestBlocker(
        targetUid: 'uid-b',
        targetProfileUid: 'uid-b',
        targetDeviceOwnerUid: null,
      );
      expect(blocker, ConnectionRequestBlocker.targetDeviceMissing);
      final message = connectionRequestBlockerMessage(blocker!);
      expect(message, contains('has not finished setting up BeChat'));
      expect(message, isNot(contains('already connected')));
      expect(message, isNot(contains('permission-denied')));
    });

    test('a device registered to another account is rejected', () {
      expect(resolveBinding('uid-x', 'uid-a'), RegistryBinding.conflict);
      expect(
        connectionRequestBlocker(
          targetUid: 'uid-b',
          targetProfileUid: 'uid-b',
          targetDeviceOwnerUid: 'uid-x',
        ),
        ConnectionRequestBlocker.targetDeviceMismatch,
      );
      expect(deviceConflictMessage, isNot(contains('already connected')));
      expect(deviceConflictMessage, contains('device'));
    });

    test('a claim that does not resolve to the searched uid is rejected', () {
      expect(
        connectionRequestBlocker(
          targetUid: 'uid-b',
          targetProfileUid: null,
          targetDeviceOwnerUid: 'uid-b',
        ),
        ConnectionRequestBlocker.targetProfileInvalid,
      );
      expect(
        connectionRequestBlocker(
          targetUid: 'uid-b',
          targetProfileUid: 'uid-c',
          targetDeviceOwnerUid: 'uid-b',
        ),
        ConnectionRequestBlocker.targetProfileInvalid,
      );
    });

    test('an existing request is reported by its status and direction', () {
      // Found from the caller's own lists, so the direction is known: an
      // accepted pair says "already connected", a pending request never gets
      // mislabelled as one the user sent.
      expect(
        existingRequestMessage(requestAccepted),
        contains('already connected'),
      );
      expect(
        existingRequestMessage(requestAccepted, incoming: true),
        contains('already connected'),
      );
      expect(existingRequestMessage(requestPending), contains('already sent'));
      expect(
        existingRequestMessage(requestPending, incoming: true),
        contains('They already sent you a request'),
      );
      expect(
        existingRequestMessage(requestDeclined),
        isNot(contains('already connected')),
      );
      expect(existingRequestMessage(requestDeclined), contains('declined'));
      expect(
        existingRequestMessage(requestDeclined, incoming: true),
        contains('You declined'),
      );
    });
  });
}
