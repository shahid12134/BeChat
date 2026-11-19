/// Firestore security rules, exercised against the Firebase Emulator Suite.
///
/// Requires the emulators to be running:
///
///   firebase emulators:start --only auth,firestore --project bechat-43a4f
///
/// Without them the suite is skipped (reported, not silently passed). Data
/// lives only in the local emulator process — production is never touched.
///
/// `cloud_firestore` cannot run under `flutter test` (platform channels), so
/// the rules are driven through the emulators' REST APIs with real anonymous
/// ID tokens: every allow/deny below is the rules engine's own answer.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _project = 'bechat-43a4f';
const _auth = 'http://localhost:9099';
const _docs =
    'http://localhost:8080/v1/projects/$_project/databases/(default)/documents';
/// Commit writes address documents by resource name, not URL.
const _resource = 'projects/$_project/databases/(default)/documents';

Future<bool> _portOpen(int port) async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(milliseconds: 500),
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> main() async {
  final emulatorsUp = await _portOpen(8080) && await _portOpen(9099);
  const skipped =
      'Firebase emulators not running — start them with: '
      'firebase emulators:start --only auth,firestore --project $_project';

  group('firestore security rules (emulator)', () {
    late _User alice; // owns device-a, device-b
    late _User bob; // owns device-c, device-d
    late _User eve; // owns device-e, no stake in the conversation

    setUpAll(() async {
      // Fresh state: documents left by a previous run would be owned by a
      // different anonymous uid and poison every registration assertion.
      final cleared = await _send(
        'DELETE',
        'http://localhost:8080/emulator/v1/projects/$_project'
        '/databases/(default)/documents',
      );
      expect(cleared.status, 200, reason: 'clear emulator: ${cleared.body}');

      alice = await _signIn();
      bob = await _signIn();
      eve = await _signIn();
      await _bind(alice, 'device-a');
      await _bind(alice, 'device-b');
      await _bind(bob, 'device-c');
      await _bind(bob, 'device-d');
      await _bind(eve, 'device-e');

      // Full profiles plus one accepted contact (alice↔bob): the request
      // and message rules gate online messaging on an accepted connection,
      // so every later group starts from the state Add People would have
      // produced. Profiles are created through the same two writes the app
      // performs (private profile, then the public claim).
      await _createProfile(
        alice,
        publicId: 'BC-AAAA-AAAA',
        deviceId: 'device-a',
      );
      await _createProfile(
        bob,
        publicId: 'BC-BBBB-BBBB',
        deviceId: 'device-c',
      );
      await _createProfile(
        eve,
        publicId: 'BC-EEEE-EEEE',
        deviceId: 'device-e',
      );
      await _acceptRequest(
        requester: alice,
        requesterPublicId: 'BC-AAAA-AAAA',
        requesterDevice: 'device-a',
        recipient: bob,
        recipientPublicId: 'BC-BBBB-BBBB',
        recipientDevice: 'device-d',
      );
    });

    group('deviceRegistry', () {
      test('unauthenticated writes are rejected', () async {
        final res = await _create(
          null,
          'deviceRegistry',
          'device-x',
          _registryFields('uid-anyone', 'device-x'),
        );
        expect(res.status, anyOf(401, 403), reason: res.body);
      });

      test('a device can register itself under its own uid', () async {
        final carol = await _signIn();
        final res = await _create(
          carol,
          'deviceRegistry',
          'device-new',
          _registryFields(carol.uid, 'device-new'),
        );
        expect(res.status, 200, reason: res.body);
        expect(await _uidOf(carol, 'device-new'), carol.uid);
      });

      test('another uid can never overwrite an existing registration', () async {
        // alice tries to take over bob's device-c with a full replace write.
        final res = await _replace(
          alice,
          'deviceRegistry',
          'device-c',
          _registryFields(alice.uid, 'device-c'),
          serverTimeFields: const [],
        );
        expect(res.status, anyOf(401, 403), reason: res.body);
        // The binding is untouched, and reading it back still works.
        expect(await _uidOf(alice, 'device-c'), bob.uid);
      });

      test('registrations are read one at a time, never listed', () async {
        // An exact probe is what a sender needs (and what ownerOf() does
        // server-side): it still resolves.
        expect(await _uidOf(alice, 'device-c'), bob.uid);
        expect(await _uidOf(eve, 'device-a'), alice.uid);

        // Listing the registry — which would expose every device id and the
        // uid behind it — is denied, signed in or not.
        final listed = await _runQuery(alice, 'deviceRegistry');
        expect(listed.status, anyOf(401, 403), reason: listed.body);

        final anon = await _runQuery(null, 'deviceRegistry');
        expect(anon.status, anyOf(401, 403), reason: anon.body);
      });

      test('a registration can never be re-pointed at a different uid', () async {
        final res = await _replace(
          alice,
          'deviceRegistry',
          'device-a',
          _registryFields(bob.uid, 'device-a'),
          serverTimeFields: const [],
        );
        expect(res.status, anyOf(401, 403), reason: res.body);
        expect(await _uidOf(alice, 'device-a'), alice.uid);
      });
    });

    group('users', () {
      test('a profile is readable only by its owner', () async {
        final mine = await _get(alice, 'users', alice.uid);
        expect(mine.status, 200, reason: mine.body);

        final theirs = await _get(eve, 'users', alice.uid);
        expect(theirs.status, anyOf(401, 403), reason: theirs.body);

        final anon = await _get(null, 'users', alice.uid);
        expect(anon.status, anyOf(401, 403), reason: anon.body);
      });

      test('a profile can only be created for yourself', () async {
        final dave = await _signIn();
        final own = await _create(
          dave,
          'users',
          dave.uid,
          _profileFields(publicId: 'BC-DAVE-2345', deviceId: 'device-a'),
        );
        expect(own.status, 200, reason: own.body);

        final erin = await _signIn();
        final stolen = await _create(
          dave,
          'users',
          erin.uid,
          _profileFields(publicId: 'BC-ERNN-2345', deviceId: 'device-a'),
        );
        expect(stolen.status, anyOf(401, 403), reason: stolen.body);
      });

      test('profiles reject unknown fields and are never rewritten', () async {
        final finn = await _signIn();
        final fields = _profileFields(
          publicId: 'BC-FNNN-2345',
          deviceId: 'device-a',
        );
        fields['evil'] = {'stringValue': 'nope'};
        final extra = await _create(finn, 'users', finn.uid, fields);
        expect(extra.status, anyOf(401, 403), reason: extra.body);

        final plain = _profileFields(
          publicId: 'BC-FNNN-2345',
          deviceId: 'device-a',
        );
        final ok = await _create(finn, 'users', finn.uid, plain);
        expect(ok.status, 200, reason: ok.body);

        // There is no update rule: even the owner cannot rewrite a stored
        // profile (the ID is permanent), and no delete rule either.
        plain['displayName'] = {'stringValue': 'Renamed'};
        final rename = await _replace(
          finn,
          'users',
          finn.uid,
          plain,
          serverTimeFields: const [],
        );
        expect(rename.status, anyOf(401, 403), reason: rename.body);

        final del = await _delete(finn, 'users', finn.uid);
        expect(del.status, anyOf(401, 403), reason: del.body);
      });

      test('a profile must carry a well-formed BeChat ID', () async {
        Future<void> expectRejected(String publicId) async {
          final user = await _signIn();
          final res = await _create(
            user,
            'users',
            user.uid,
            _profileFields(publicId: publicId, deviceId: 'device-a'),
          );
          expect(
            res.status,
            anyOf(401, 403),
            reason: '$publicId should be rejected: ${res.body}',
          );
        }

        await expectRejected('bc-ABCD-2345'); // lower case
        await expectRejected('BC-ABCD2345'); // missing separator
        await expectRejected('BC-ABCD-23456'); // too long
        await expectRejected('BC-ABCD-234'); // too short
        await expectRejected('XX-ABCD-2345'); // wrong prefix
        await expectRejected('BC-ABCD-2345 '); // trailing space
      });
    });

    group('publicIds', () {
      test('claims are read by exact ID, never listed', () async {
        // ID search is a single document read — that must keep working.
        final exact = await _get(alice, 'publicIds', 'BC-BBBB-BBBB');
        expect(exact.status, 200, reason: exact.body);

        // Listing every claim (id → uid + display name) is denied.
        final listed = await _runQuery(alice, 'publicIds');
        expect(listed.status, anyOf(401, 403), reason: listed.body);

        final anon = await _runQuery(null, 'publicIds');
        expect(anon.status, anyOf(401, 403), reason: anon.body);
      });

      test('only well-formed BeChat IDs can be claimed', () async {
        Future<void> expectRejected(String publicId) async {
          final user = await _signIn();
          final res = await _create(user, 'publicIds', publicId, {
            'uid': {'stringValue': user.uid},
            'publicId': {'stringValue': publicId},
            'displayName': {'stringValue': 'Claimer'},
            'deviceId': {'stringValue': 'device-a'},
            'createdAt': {'timestampValue': '1970-01-01T00:00:00Z'},
            'updatedAt': {'timestampValue': '1970-01-01T00:00:00Z'},
          });
          expect(
            res.status,
            anyOf(401, 403),
            reason: '$publicId should be rejected: ${res.body}',
          );
        }

        await expectRejected('BC-0000-2345'); // ambiguous 0
        await expectRejected('BC-IIII-2345'); // ambiguous I
        await expectRejected('BC-OOOO-2345'); // ambiguous O
        await expectRejected('bc-ABCD-2345'); // lower case
        await expectRejected('BC-ABCD2345'); // missing separator
        await expectRejected('BC-ABCD-2345 '); // trailing space
        await expectRejected('ABCD-2345'); // missing prefix
        await expectRejected('BC-ABC-23456'); // wrong group lengths
      });

      test('the claim is a minimal preview readable by any signed-in user',
          () async {
        final res = await _get(alice, 'publicIds', 'BC-BBBB-BBBB');
        expect(res.status, 200, reason: res.body);
        final fields = await _fields(alice, 'publicIds', 'BC-BBBB-BBBB');
        expect(fields['uid'], {'stringValue': bob.uid});
        expect(fields['publicId'], {'stringValue': 'BC-BBBB-BBBB'});
        // Exactly the preview fields — nothing private rides along.
        expect(
          fields.keys.toSet(),
          {'uid', 'publicId', 'displayName', 'deviceId', 'createdAt', 'updatedAt'},
        );

        final anon = await _get(null, 'publicIds', 'BC-BBBB-BBBB');
        expect(anon.status, anyOf(401, 403), reason: anon.body);
      });

      test('a claim can only be created for yourself and released by its owner',
          () async {
        final gina = await _signIn();
        final base = {
          'publicId': {'stringValue': 'BC-GNAA-2345'},
          'displayName': {'stringValue': 'Gina'},
          'deviceId': {'stringValue': 'device-a'},
          'createdAt': {'timestampValue': '1970-01-01T00:00:00Z'},
          'updatedAt': {'timestampValue': '1970-01-01T00:00:00Z'},
        };

        // Claiming under someone else's uid is denied.
        final spoof = await _create(gina, 'publicIds', 'BC-GNAA-2345', {
          ...base,
          'uid': {'stringValue': alice.uid},
        });
        expect(spoof.status, anyOf(401, 403), reason: spoof.body);

        // The field must equal the document id (the lookup key).
        final mismatch = await _create(gina, 'publicIds', 'BC-GNAA-2345', {
          ...base,
          'publicId': {'stringValue': 'BC-OTHR-2345'},
          'uid': {'stringValue': gina.uid},
        });
        expect(mismatch.status, anyOf(401, 403), reason: mismatch.body);

        final own = await _create(gina, 'publicIds', 'BC-GNAA-2345', {
          ...base,
          'uid': {'stringValue': gina.uid},
        });
        expect(own.status, 200, reason: own.body);

        // Even the owner can never overwrite a claim: publicIds has no
        // update rule, so a replace on an existing claim is a denied
        // update — create-only ownership is enforced server-side, not by
        // the client's pre-check.
        final overwrite = await _replace(
          gina,
          'publicIds',
          'BC-GNAA-2345',
          {
            ...base,
            'uid': {'stringValue': gina.uid},
            'displayName': {'stringValue': 'Overwritten'},
          },
          serverTimeFields: const [],
        );
        expect(overwrite.status, anyOf(401, 403), reason: overwrite.body);
        expect(
          (await _fields(alice, 'publicIds', 'BC-GNAA-2345'))['displayName'],
          {'stringValue': 'Gina'},
          reason: 'the stored claim is untouched',
        );

        // A second account cannot take the same ID (create-only claim).
        final harry = await _signIn();
        final collide = await _create(harry, 'publicIds', 'BC-GNAA-2345', {
          ...base,
          'displayName': {'stringValue': 'Harry'},
          'uid': {'stringValue': harry.uid},
        });
        expect(collide.status, anyOf(400, 403, 409), reason: collide.body);

        // Only the owner can release the claim.
        final byAlice = await _delete(alice, 'publicIds', 'BC-GNAA-2345');
        expect(byAlice.status, anyOf(401, 403), reason: byAlice.body);
        final byGina = await _delete(gina, 'publicIds', 'BC-GNAA-2345');
        expect(byGina.status, 200, reason: byGina.body);
      });
    });

    group('connectionRequests', () {
      test('the requester creates a pending request under the canonical id',
          () async {
        final res = await _create(
          alice,
          'connectionRequests',
          _requestId(alice.uid, eve.uid),
          _requestFields(
            requesterUid: alice.uid,
            requesterPublicId: 'BC-AAAA-AAAA',
            requesterDevice: 'device-a',
            recipientUid: eve.uid,
            recipientPublicId: 'BC-EEEE-EEEE',
            recipientDevice: 'device-e',
          ),
        );
        expect(res.status, 200, reason: res.body);
        final fields = await _fields(
          alice,
          'connectionRequests',
          _requestId(alice.uid, eve.uid),
        );
        expect(fields['status'], {'stringValue': 'pending'});
      });

      test('the document id must bind the uid pair', () async {
        final fields = _requestFields(
          requesterUid: alice.uid,
          requesterPublicId: 'BC-AAAA-AAAA',
          requesterDevice: 'device-a',
          recipientUid: eve.uid,
          recipientPublicId: 'BC-EEEE-EEEE',
          recipientDevice: 'device-e',
        );

        // An arbitrary document id carries no pair binding.
        final forged = await _create(
          alice,
          'connectionRequests',
          'request-forged',
          fields,
        );
        expect(forged.status, anyOf(401, 403), reason: forged.body);

        // A valid id — but for a different pair — is still not this
        // write's id: the id must be exactly the sorted (alice, eve).
        final wrongPair = await _create(
          alice,
          'connectionRequests',
          _requestId(bob.uid, eve.uid),
          fields,
        );
        expect(wrongPair.status, anyOf(401, 403), reason: wrongPair.body);
      });

      test('a user can never send a request to themselves', () async {
        final res = await _create(
          alice,
          'connectionRequests',
          _requestId(alice.uid, alice.uid),
          _requestFields(
            requesterUid: alice.uid,
            requesterPublicId: 'BC-AAAA-AAAA',
            requesterDevice: 'device-a',
            recipientUid: alice.uid,
            recipientPublicId: 'BC-AAAA-AAAA',
            recipientDevice: 'device-b',
          ),
        );
        expect(res.status, anyOf(401, 403), reason: res.body);
      });

      test('a duplicate request in either direction is denied', () async {
        // Same direction: the deterministic id collides with the request
        // created by the first test (create-only semantics).
        final again = await _create(
          alice,
          'connectionRequests',
          _requestId(alice.uid, eve.uid),
          _requestFields(
            requesterUid: alice.uid,
            requesterPublicId: 'BC-AAAA-AAAA',
            requesterDevice: 'device-a',
            recipientUid: eve.uid,
            recipientPublicId: 'BC-EEEE-EEEE',
            recipientDevice: 'device-e',
          ),
        );
        expect(again.status, anyOf(400, 403, 409), reason: again.body);

        // Reverse direction: both directions resolve to the SAME sorted
        // document, so eve's submission hits the existing document too —
        // repeated and concurrent submissions from either side can never
        // produce a second document for one pair.
        final reverse = await _create(
          eve,
          'connectionRequests',
          _requestId(eve.uid, alice.uid),
          _requestFields(
            requesterUid: eve.uid,
            requesterPublicId: 'BC-EEEE-EEEE',
            requesterDevice: 'device-e',
            recipientUid: alice.uid,
            recipientPublicId: 'BC-AAAA-AAAA',
            recipientDevice: 'device-a',
          ),
        );
        expect(reverse.status, anyOf(400, 403, 409), reason: reverse.body);
      });

      test('both claimed IDs and devices must resolve to the claimed UIDs',
          () async {
        Map<String, dynamic> fields({
          String? requesterPublicId,
          String? recipientPublicId,
          String? requesterDevice,
        }) {
          return _requestFields(
            requesterUid: alice.uid,
            requesterPublicId: requesterPublicId ?? 'BC-AAAA-AAAA',
            requesterDevice: requesterDevice ?? 'device-a',
            recipientUid: bob.uid,
            recipientPublicId: recipientPublicId ?? 'BC-BBBB-BBBB',
            recipientDevice: 'device-d',
          );
        }

        // Borrowing someone else's public ID as the requester.
        final borrowed = await _create(
          alice,
          'connectionRequests',
          _requestId(alice.uid, bob.uid),
          fields(requesterPublicId: 'BC-BBBB-BBBB'),
        );
        expect(borrowed.status, anyOf(401, 403), reason: borrowed.body);

        // Claiming a recipient ID that belongs to a different uid.
        final wrongRecipient = await _create(
          alice,
          'connectionRequests',
          _requestId(alice.uid, bob.uid),
          fields(recipientPublicId: 'BC-EEEE-EEEE'),
        );
        expect(wrongRecipient.status, anyOf(401, 403), reason: wrongRecipient.body);

        // A device registered to someone else cannot be frozen in.
        final stolenDevice = await _create(
          alice,
          'connectionRequests',
          _requestId(alice.uid, bob.uid),
          fields(requesterDevice: 'device-c'),
        );
        expect(stolenDevice.status, anyOf(401, 403), reason: stolenDevice.body);
      });

      test('a requester whose device is not registered cannot send a request',
          () async {
        // Profile and claim exist (so ID search and registration "look"
        // complete), but this device never wrote deviceRegistry — the shape
        // of the reported Add-tap failure: rules resolve requesterDeviceId
        // through the registry, find nothing, and refuse the create.
        final ivy = await _signIn();
        await _createProfile(
          ivy,
          publicId: 'BC-KVYV-2345',
          deviceId: 'device-ivy-unregistered',
        );

        final res = await _create(
          ivy,
          'connectionRequests',
          _requestId(ivy.uid, eve.uid),
          _requestFields(
            requesterUid: ivy.uid,
            requesterPublicId: 'BC-KVYV-2345',
            requesterDevice: 'device-ivy-unregistered',
            recipientUid: eve.uid,
            recipientPublicId: 'BC-EEEE-EEEE',
            recipientDevice: 'device-e',
          ),
        );
        expect(res.status, anyOf(401, 403), reason: res.body);
      });

      test('a recipient whose device is not registered cannot be requested',
          () async {
        final jane = await _signIn();
        await _createProfile(
          jane,
          publicId: 'BC-JANE-2345',
          deviceId: 'device-jane-unregistered',
        );

        final res = await _create(
          alice,
          'connectionRequests',
          _requestId(alice.uid, jane.uid),
          _requestFields(
            requesterUid: alice.uid,
            requesterPublicId: 'BC-AAAA-AAAA',
            requesterDevice: 'device-a',
            recipientUid: jane.uid,
            recipientPublicId: 'BC-JANE-2345',
            recipientDevice: 'device-jane-unregistered',
          ),
        );
        expect(res.status, anyOf(401, 403), reason: res.body);
      });

      test('a request that does not exist yet cannot be read', () async {
        // The regression: `allow read: if isParty()` inspects the document's
        // own requester/recipient fields, and a missing document has none, so
        // Firestore denies the read outright. A client that peeks at the
        // deterministic id before creating it therefore sees a
        // permission-denied that has nothing to do with the request being a
        // duplicate — which is exactly how "you may already be connected"
        // appeared for first-time requests.
        final kai = await _signIn();
        final lee = await _signIn();
        await _bind(kai, 'device-kai');
        await _bind(lee, 'device-lee');
        await _createProfile(
          kai,
          publicId: 'BC-KAAK-2345',
          deviceId: 'device-kai',
        );
        await _createProfile(
          lee,
          publicId: 'BC-MEEE-2345',
          deviceId: 'device-lee',
        );

        final id = _requestId(kai.uid, lee.uid);
        final before = await _get(kai, 'connectionRequests', id);
        expect(before.status, anyOf(401, 403), reason: before.body);

        // Creating directly, with both devices registered, needs no read and
        // is what the app does now.
        final created = await _create(
          kai,
          'connectionRequests',
          id,
          _requestFields(
            requesterUid: kai.uid,
            requesterPublicId: 'BC-KAAK-2345',
            requesterDevice: 'device-kai',
            recipientUid: lee.uid,
            recipientPublicId: 'BC-MEEE-2345',
            recipientDevice: 'device-lee',
          ),
        );
        expect(created.status, 200, reason: created.body);

        // Once it exists, the pair can read it.
        expect((await _get(kai, 'connectionRequests', id)).status, 200);
        expect((await _get(lee, 'connectionRequests', id)).status, 200);
      });

      test('an accepted request cannot be overwritten', () async {
        final id = _requestId(alice.uid, bob.uid); // accepted in setUpAll

        // The requester cannot reset it to pending...
        final byRequester = await _replace(
          alice,
          'connectionRequests',
          id,
          _withStatus(
            await _fields(alice, 'connectionRequests', id),
            'pending',
          ),
          serverTimeFields: ['updatedAt'],
        );
        expect(byRequester.status, anyOf(401, 403), reason: byRequester.body);

        // ...and neither party can flip an already answered request.
        final byRecipient = await _replace(
          bob,
          'connectionRequests',
          id,
          _withStatus(
            await _fields(bob, 'connectionRequests', id),
            'declined',
          ),
          serverTimeFields: ['updatedAt'],
        );
        expect(byRecipient.status, anyOf(401, 403), reason: byRecipient.body);

        expect(
          (await _fields(alice, 'connectionRequests', id))['status'],
          {'stringValue': 'accepted'},
          reason: 'the accepted contact is untouched',
        );
      });

      test('unauthenticated creates are rejected', () async {
        final res = await _create(
          null,
          'connectionRequests',
          _requestId('anyone', 'else'),
          _requestFields(
            requesterUid: 'anyone',
            requesterPublicId: 'BC-AAAA-AAAA',
            requesterDevice: 'device-a',
            recipientUid: 'else',
            recipientPublicId: 'BC-BBBB-BBBB',
            recipientDevice: 'device-d',
          ),
        );
        expect(res.status, anyOf(401, 403), reason: res.body);
      });

      test('only the parties can read a request', () async {
        final id = _requestId(alice.uid, eve.uid);

        expect((await _get(alice, 'connectionRequests', id)).status, 200,
            reason: 'the requester reads their own request');
        expect((await _get(eve, 'connectionRequests', id)).status, 200,
            reason: 'the recipient reads their own request');

        final outsider = await _get(bob, 'connectionRequests', id);
        expect(outsider.status, anyOf(401, 403), reason: outsider.body);
        final anon = await _get(null, 'connectionRequests', id);
        expect(anon.status, anyOf(401, 403), reason: anon.body);
      });

      test('the app can query its own requests, but not the whole collection',
          () async {
        // The incoming-requests query the app issues: one equality filter
        // on the caller's own uid.
        final mine = await _runQuery(
          alice,
          'connectionRequests',
          field: 'requesterUid',
          equals: alice.uid,
        );
        expect(mine.status, 200, reason: mine.body);
        expect(mine.body, contains(alice.uid),
            reason: 'her own request must come back');

        // An unfiltered sweep over other people's requests is denied.
        final all = await _runQuery(eve, 'connectionRequests');
        expect(all.status, anyOf(401, 403), reason: all.body);
      });

      test('only the recipient may respond, and only while pending', () async {
        final id = _requestId(alice.uid, eve.uid);

        // The requester cannot accept their own request.
        final byRequester = await _replace(
          alice,
          'connectionRequests',
          id,
          _withStatus(await _fields(alice, 'connectionRequests', id), 'accepted'),
          serverTimeFields: ['updatedAt'],
        );
        expect(byRequester.status, anyOf(401, 403), reason: byRequester.body);

        // A third party cannot respond either. (Read as a party — the
        // outsider's own read is correctly denied — then write as the
        // outsider.)
        final byOutsider = await _replace(
          bob,
          'connectionRequests',
          id,
          _withStatus(
            await _fields(alice, 'connectionRequests', id),
            'accepted',
          ),
          serverTimeFields: ['updatedAt'],
        );
        expect(byOutsider.status, anyOf(401, 403), reason: byOutsider.body);

        // The recipient cannot rewrite the frozen identity fields.
        final tampered = await _fields(eve, 'connectionRequests', id);
        tampered['recipientUid'] = {'stringValue': bob.uid};
        final tamper = await _replace(
          eve,
          'connectionRequests',
          id,
          tampered,
          serverTimeFields: ['updatedAt'],
        );
        expect(tamper.status, anyOf(401, 403), reason: tamper.body);

        // The recipient's accept is accepted.
        final accept = await _replace(
          eve,
          'connectionRequests',
          id,
          _withStatus(await _fields(eve, 'connectionRequests', id), 'accepted'),
          serverTimeFields: ['updatedAt'],
        );
        expect(accept.status, 200, reason: accept.body);
        expect(
          (await _fields(eve, 'connectionRequests', id))['status'],
          {'stringValue': 'accepted'},
        );

        // A responded-to request is frozen: no second transition.
        final again = await _replace(
          eve,
          'connectionRequests',
          id,
          _withStatus(await _fields(eve, 'connectionRequests', id), 'declined'),
          serverTimeFields: ['updatedAt'],
        );
        expect(again.status, anyOf(401, 403), reason: again.body);
      });

      test('either party may remove a request; outsiders may not', () async {
        // A fresh pair (alice↔bob already exists from setUpAll): the
        // recipient's side is removed by the requester here; the messages
        // suite later recreates this pair for its pending/accept flow.
        final id = _requestId(bob.uid, eve.uid);
        final created = await _create(
          bob,
          'connectionRequests',
          id,
          _requestFields(
            requesterUid: bob.uid,
            requesterPublicId: 'BC-BBBB-BBBB',
            requesterDevice: 'device-c',
            recipientUid: eve.uid,
            recipientPublicId: 'BC-EEEE-EEEE',
            recipientDevice: 'device-e',
          ),
        );
        expect(created.status, 200, reason: created.body);

        final byOutsider = await _delete(alice, 'connectionRequests', id);
        expect(byOutsider.status, anyOf(401, 403), reason: byOutsider.body);

        final byParty = await _delete(bob, 'connectionRequests', id);
        expect(byParty.status, 200, reason: byParty.body);
      });
    });

    group('messages', () {
      test('unauthenticated create and read are rejected', () async {
        final fields = _messageFields(
          id: 'm-anon',
          senderUid: alice.uid,
          senderDeviceId: 'device-a',
          recipientUid: bob.uid,
          recipientDeviceId: 'device-d',
        );
        final write = await _commit(
          null,
          _createWrite('$_resource/messages/m-anon', fields),
        );
        expect(write.status, anyOf(401, 403), reason: write.body);

        final read = await _get(null, 'messages', 'm-anon');
        expect(read.status, anyOf(401, 403), reason: read.body);
      });

      test('senderUid must match the authenticated uid', () async {
        final res = await _commit(
          alice,
          _createWrite(
            '$_resource/messages/m-spoofed-sender',
            _messageFields(
              id: 'm-spoofed-sender',
              senderUid: bob.uid, // alice claims to be bob
              senderDeviceId: 'device-a',
              recipientUid: bob.uid,
              recipientDeviceId: 'device-d',
            ),
          ),
        );
        expect(res.status, anyOf(401, 403), reason: res.body);
      });

      test('the sender device must be registered to the sender uid', () async {
        final res = await _commit(
          alice,
          _createWrite(
            '$_resource/messages/m-stolen-device',
            _messageFields(
              id: 'm-stolen-device',
              senderUid: alice.uid,
              senderDeviceId: 'device-c', // bob's device
              recipientUid: bob.uid,
              recipientDeviceId: 'device-d',
            ),
          ),
        );
        expect(res.status, anyOf(401, 403), reason: res.body);
      });

      test('the recipient device must belong to the claimed recipient uid', () async {
        final res = await _commit(
          alice,
          _createWrite(
            '$_resource/messages/m-wrong-recipient',
            _messageFields(
              id: 'm-wrong-recipient',
              senderUid: alice.uid,
              senderDeviceId: 'device-a',
              recipientUid: bob.uid,
              recipientDeviceId: 'device-b', // alice's own device
            ),
          ),
        );
        expect(res.status, anyOf(401, 403), reason: res.body);
      });

      test('the document id must equal messageId', () async {
        final res = await _commit(
          alice,
          _createWrite(
            '$_resource/messages/m-id-mismatch',
            _messageFields(
              id: 'something-else',
              senderUid: alice.uid,
              senderDeviceId: 'device-a',
              recipientUid: alice.uid,
              recipientDeviceId: 'device-b',
            ),
          ),
        );
        expect(res.status, anyOf(401, 403), reason: res.body);
      });

      test('a message may only be created as sent, never delivered', () async {
        final res = await _commit(
          alice,
          _createWrite(
            '$_resource/messages/m-preack',
            _messageFields(
              id: 'm-preack',
              senderUid: alice.uid,
              senderDeviceId: 'device-a',
              recipientUid: alice.uid,
              recipientDeviceId: 'device-b',
              status: 'delivered',
            ),
          ),
        );
        expect(res.status, anyOf(401, 403), reason: res.body);
      });

      test('oversized payloads are rejected', () async {
        final res = await _commit(
          alice,
          _createWrite(
            '$_resource/messages/m-huge',
            _messageFields(
              id: 'm-huge',
              senderUid: alice.uid,
              senderDeviceId: 'device-a',
              recipientUid: alice.uid,
              recipientDeviceId: 'device-b',
              content: 'x' * 5000,
            ),
          ),
        );
        expect(res.status, anyOf(401, 403), reason: res.body);
      });

      test('extra fields are rejected', () async {
        final fields = _messageFields(
          id: 'm-extra',
          senderUid: alice.uid,
          senderDeviceId: 'device-a',
          recipientUid: alice.uid,
          recipientDeviceId: 'device-b',
        );
        fields['evil'] = {'stringValue': 'nope'};
        final res = await _commit(
          alice,
          _createWrite('$_resource/messages/m-extra', fields),
        );
        expect(res.status, anyOf(401, 403), reason: res.body);
      });

      test('a message with valid attachment metadata is accepted', () async {
        final res = await _commit(
          alice,
          _createWrite(
            '$_resource/messages/m-media',
            _messageFields(
              id: 'm-media',
              senderUid: alice.uid,
              senderDeviceId: 'device-a',
              recipientUid: bob.uid,
              recipientDeviceId: 'device-d',
              attachment: _attachmentFields(
                messageId: 'm-media',
                senderDeviceId: 'device-a',
              ),
            ),
          ),
        );
        expect(res.status, 200, reason: res.body);
      });

      test('attachment metadata is rejected when it does not match the message',
          () async {
        Future<void> expectRejected(
          String id,
          Map<String, dynamic> attachment,
        ) async {
          final res = await _commit(
            alice,
            _createWrite(
              '$_resource/messages/$id',
              _messageFields(
                id: id,
                senderUid: alice.uid,
                senderDeviceId: 'device-a',
                recipientUid: bob.uid,
                recipientDeviceId: 'device-d',
                attachment: attachment,
              ),
            ),
          );
          expect(res.status, anyOf(401, 403), reason: '$id: ${res.body}');
        }

        // Path inside another device's folder.
        await expectRejected(
          'm-media-path',
          _attachmentFields(
            messageId: 'm-media-path',
            senderDeviceId: 'device-b',
          ),
        );
        // An "image" carrying a document-sized payload.
        await expectRejected(
          'm-media-big',
          _attachmentFields(
            messageId: 'm-media-big',
            senderDeviceId: 'device-a',
            size: 20 * 1024 * 1024,
          ),
        );
        // Type outside the allowlist.
        await expectRejected(
          'm-media-gif',
          _attachmentFields(
            messageId: 'm-media-gif',
            senderDeviceId: 'device-a',
            mimeType: 'image/gif',
          ),
        );
        // Metadata for a different message id.
        await expectRejected(
          'm-media-id',
          _attachmentFields(
            messageId: 'm-media-id',
            senderDeviceId: 'device-a',
            attachmentId: 'm-other',
          ),
        );
        // Unknown keys inside the metadata map.
        await expectRejected(
          'm-media-extra',
          _attachmentFields(
            messageId: 'm-media-extra',
            senderDeviceId: 'device-a',
            withExtraField: true,
          ),
        );

        // A plain text message is still accepted (attachment is optional).
        final text = await _commit(
          alice,
          _createWrite(
            '$_resource/messages/m-no-media',
            _messageFields(
              id: 'm-no-media',
              senderUid: alice.uid,
              senderDeviceId: 'device-a',
              recipientUid: bob.uid,
              recipientDeviceId: 'device-d',
            ),
          ),
        );
        expect(text.status, 200, reason: text.body);
      });

      test('a valid message is accepted and readable by both endpoints', () async {
        final res = await _commit(
          alice,
          _createWrite(
            '$_resource/messages/m-ok',
            _messageFields(
              id: 'm-ok',
              senderUid: alice.uid,
              senderDeviceId: 'device-a',
              // alice↔bob is the accepted pair seeded in setUpAll: online
              // messaging runs only between accepted contacts.
              recipientUid: bob.uid,
              recipientDeviceId: 'device-d',
            ),
          ),
        );
        expect(res.status, 200, reason: res.body);

        expect((await _get(alice, 'messages', 'm-ok')).status, 200,
            reason: 'the sender may read its own message');
        expect((await _get(bob, 'messages', 'm-ok')).status, 200,
            reason: 'the recipient may read it');
        final outsider = await _get(eve, 'messages', 'm-ok');
        expect(outsider.status, anyOf(401, 403), reason: outsider.body);
        final anonymous = await _get(null, 'messages', 'm-ok');
        expect(anonymous.status, anyOf(401, 403), reason: anonymous.body);
      });

      test('a cross-user message is readable only by sender and recipient', () async {
        final res = await _commit(
          alice,
          _createWrite(
            '$_resource/messages/m-cross',
            _messageFields(
              id: 'm-cross',
              senderUid: alice.uid,
              senderDeviceId: 'device-a',
              recipientUid: bob.uid,
              recipientDeviceId: 'device-d',
            ),
          ),
        );
        expect(res.status, 200, reason: res.body);

        expect((await _get(alice, 'messages', 'm-cross')).status, 200,
            reason: 'the sender may read its own message');
        expect((await _get(bob, 'messages', 'm-cross')).status, 200,
            reason: 'the recipient may read it');
        final outsider = await _get(eve, 'messages', 'm-cross');
        expect(outsider.status, anyOf(401, 403), reason: outsider.body);
        final anonymous = await _get(null, 'messages', 'm-cross');
        expect(anonymous.status, anyOf(401, 403), reason: anonymous.body);
      });

      test('only the recipient may acknowledge final delivery', () async {
        // alice (the sender) tries to mark her own message delivered.
        final senderAck = await _replace(
          alice,
          'messages',
          'm-cross',
          _withAck(await _fields(alice, 'messages', 'm-cross')),
        );
        expect(senderAck.status, anyOf(401, 403), reason: senderAck.body);

        // A third party cannot ack either.
        final eveAck = await _replace(
          eve,
          'messages',
          'm-cross',
          _withAck(await _fields(alice, 'messages', 'm-cross')),
        );
        expect(eveAck.status, anyOf(401, 403), reason: eveAck.body);
        expect((await _fields(alice, 'messages', 'm-cross'))['status'],
            {'stringValue': 'sent'},
            reason: 'neither attempt changed the document');

        // The recipient's ack is accepted.
        final ack = await _replace(
          bob,
          'messages',
          'm-cross',
          _withAck(await _fields(alice, 'messages', 'm-cross')),
        );
        expect(ack.status, 200, reason: ack.body);
        expect((await _fields(bob, 'messages', 'm-cross'))['status'],
            {'stringValue': 'delivered'});
      });

      test('acknowledged messages are immutable: payload, sender and status', () async {
        final delivered = await _fields(alice, 'messages', 'm-cross');

        // Payload change by the recipient — denied even though they own it.
        final tampered = Map<String, dynamic>.from(delivered);
        tampered['content'] = {'stringValue': 'rewritten'};
        final res = await _replace(bob, 'messages', 'm-cross', tampered);
        expect(res.status, anyOf(401, 403), reason: res.body);
        expect((await _fields(alice, 'messages', 'm-cross'))['content'],
            {'stringValue': 'hello'},
            reason: 'the payload is untouched');

        // Status may only become delivered, never anything else.
        final readBack = Map<String, dynamic>.from(delivered);
        readBack['status'] = {'stringValue': 'read'};
        final res2 = await _replace(bob, 'messages', 'm-cross', readBack);
        expect(res2.status, anyOf(401, 403), reason: res2.body);

        // Identity fields are frozen after create.
        final readdressed = Map<String, dynamic>.from(delivered);
        readdressed['recipientUid'] = {'stringValue': eve.uid};
        final res3 = await _replace(bob, 'messages', 'm-cross', readdressed);
        expect(res3.status, anyOf(401, 403), reason: res3.body);
        expect((await _fields(alice, 'messages', 'm-cross'))['recipientUid'],
            {'stringValue': bob.uid});
      });

      test('messages are never deletable', () async {
        final res = await _delete(alice, 'messages', 'm-ok');
        expect(res.status, anyOf(401, 403), reason: res.body);
        expect((await _get(alice, 'messages', 'm-ok')).status, 200);
      });

      test('online messaging requires an accepted contact', () async {
        // A pending request is not enough: the pair has no accepted state.
        final pendingId = _requestId(bob.uid, eve.uid);
        final created = await _create(
          bob,
          'connectionRequests',
          pendingId,
          _requestFields(
            requesterUid: bob.uid,
            requesterPublicId: 'BC-BBBB-BBBB',
            requesterDevice: 'device-c',
            recipientUid: eve.uid,
            recipientPublicId: 'BC-EEEE-EEEE',
            recipientDevice: 'device-e',
          ),
        );
        expect(created.status, 200, reason: created.body);

        final rejected = await _commit(
          bob,
          _createWrite(
            '$_resource/messages/m-pending',
            _messageFields(
              id: 'm-pending',
              senderUid: bob.uid,
              senderDeviceId: 'device-c',
              recipientUid: eve.uid,
              recipientDeviceId: 'device-e',
            ),
          ),
        );
        expect(rejected.status, anyOf(401, 403), reason: rejected.body);

        // Once the recipient accepts, the same message goes through.
        final fields = await _fields(eve, 'connectionRequests', pendingId);
        fields['status'] = {'stringValue': 'accepted'};
        final accepted = await _replace(
          eve,
          'connectionRequests',
          pendingId,
          fields,
          serverTimeFields: ['updatedAt'],
        );
        expect(accepted.status, 200, reason: accepted.body);

        final allowed = await _commit(
          bob,
          _createWrite(
            '$_resource/messages/m-pending',
            _messageFields(
              id: 'm-pending',
              senderUid: bob.uid,
              senderDeviceId: 'device-c',
              recipientUid: eve.uid,
              recipientDeviceId: 'device-e',
            ),
          ),
        );
        expect(allowed.status, 200, reason: allowed.body);
      });
    });
  }, skip: emulatorsUp ? false : skipped);
}

// ---------------------------------------------------------------------------
// Emulator REST helpers
// ---------------------------------------------------------------------------

class _User {
  _User(this.uid, this.token);

  final String uid;
  final String token;
}

Future<({int status, String body})> _send(
  String method,
  String url, {
  _User? user,
  Object? json,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, Uri.parse(url));
    if (user != null) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${user.token}',
      );
    }
    if (json != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(json));
    }
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    return (status: response.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
}

/// Anonymous sign-in against the Auth emulator (test-only project).
Future<_User> _signIn() async {
  final res = await _send(
    'POST',
    '$_auth/identitytoolkit.googleapis.com/v1/accounts:signUp?key=emulator',
    json: {'returnSecureToken': true},
  );
  expect(res.status, 200, reason: 'auth emulator sign-in: ${res.body}');
  final body = jsonDecode(res.body) as Map<String, dynamic>;
  return _User(body['localId'] as String, body['idToken'] as String);
}

Future<({int status, String body})> _create(
  _User? user,
  String collection,
  String docId,
  Map<String, dynamic> fields,
) {
  return _send(
    'POST',
    '$_docs/$collection?documentId=$docId',
    user: user,
    json: {'fields': fields},
  );
}

Future<({int status, String body})> _get(
  _User? user,
  String collection,
  String docId,
) {
  return _send('GET', '$_docs/$collection/$docId', user: user);
}

Future<({int status, String body})> _delete(
  _User? user,
  String collection,
  String docId,
) {
  return _send('DELETE', '$_docs/$collection/$docId', user: user);
}

Future<({int status, String body})> _commit(
  _User? user,
  Map<String, dynamic> write,
) {
  return _send(
    'POST',
    '$_docs:commit',
    user: user,
    json: {
      'writes': [write],
    },
  );
}

/// Creates `docId` in `collection`, failing if it already exists.
Future<({int status, String body})> _replace(
  _User? user,
  String collection,
  String docId,
  Map<String, dynamic> fields, {
  List<String> serverTimeFields = const ['deliveredAt'],
}) {
  return _commit(
    user,
    {
      'update': {
        'name': '$_resource/$collection/$docId',
        'fields': fields,
      },
      'updateTransforms': [
        for (final field in serverTimeFields)
          {'fieldPath': field, 'setToServerValue': 'REQUEST_TIME'},
      ],
    },
  );
}

Future<Map<String, dynamic>> _fields(
  _User? user,
  String collection,
  String docId,
) async {
  final res = await _get(user, collection, docId);
  expect(res.status, 200, reason: 'expected $collection/$docId: ${res.body}');
  final body = jsonDecode(res.body) as Map<String, dynamic>;
  return body['fields'] as Map<String, dynamic>;
}

/// Structured query against a collection — the list half of the read rules
/// (the `get` half is `_get`). Response is newline-delimited JSON frames.
Future<({int status, String body})> _runQuery(
  _User? user,
  String collection, {
  String? field,
  String? equals,
}) {
  // `:runQuery` hangs off the DOCUMENT ROOT, not the collection
  // (`documents/{collection}:runQuery` is a malformed parent name).
  return _send(
    'POST',
    '$_docs:runQuery',
    user: user,
    json: {
      'structuredQuery': {
        'from': [
          {'collectionId': collection},
        ],
        if (field != null)
          'where': {
            'fieldFilter': {
              'field': {'fieldPath': field},
              'op': 'EQUAL',
              'value': {'stringValue': equals},
            },
          },
      },
    },
  );
}

Future<String?> _uidOf(_User user, String deviceId) async {
  final fields = await _fields(user, 'deviceRegistry', deviceId);
  final uid = fields['uid'];
  return uid is Map ? uid['stringValue'] as String? : null;
}

// ---------------------------------------------------------------------------
// Document builders
// ---------------------------------------------------------------------------

Map<String, dynamic> _registryFields(String uid, String deviceId) => {
  'uid': {'stringValue': uid},
  'deviceId': {'stringValue': deviceId},
};

Future<void> _bind(_User user, String deviceId) async {
  final res = await _create(user, 'deviceRegistry', deviceId, {
    'uid': {'stringValue': user.uid},
    'deviceId': {'stringValue': deviceId},
  });
  expect(res.status, 200, reason: 'register $deviceId: ${res.body}');
}

Map<String, dynamic> _profileFields({
  required String publicId,
  required String deviceId,
  String name = 'Test user',
}) => {
  'publicId': {'stringValue': publicId},
  'displayName': {'stringValue': name},
  'deviceId': {'stringValue': deviceId},
  'createdAt': {'timestampValue': '1970-01-01T00:00:00Z'},
  'updatedAt': {'timestampValue': '1970-01-01T00:00:00Z'},
};

/// The two writes `PeopleService.ensureMyProfile` performs: the private
/// profile under the uid, then the public claim under the ID itself.
Future<void> _createProfile(
  _User user, {
  required String publicId,
  required String deviceId,
}) async {
  final profile = _profileFields(publicId: publicId, deviceId: deviceId);
  final users = await _create(user, 'users', user.uid, profile);
  expect(users.status, 200, reason: 'users profile: ${users.body}');
  final claim = await _create(user, 'publicIds', publicId, {
    'uid': {'stringValue': user.uid},
    ...profile,
  });
  expect(claim.status, 200, reason: 'public claim: ${claim.body}');
}

/// Same construction as `connectionRequestId` in `people_service.dart`:
/// the sorted pair — `firestore.rules` refuses any other document id, so
/// both directions and concurrent submissions land on one document.
String _requestId(String requesterUid, String recipientUid) =>
    requesterUid.compareTo(recipientUid) <= 0
    ? '$requesterUid.$recipientUid'
    : '$recipientUid.$requesterUid';

Map<String, dynamic> _requestFields({
  required String requesterUid,
  required String requesterPublicId,
  required String requesterDevice,
  required String recipientUid,
  required String recipientPublicId,
  required String recipientDevice,
  String status = 'pending',
}) => {
  'requesterUid': {'stringValue': requesterUid},
  'requesterPublicId': {'stringValue': requesterPublicId},
  'requesterDeviceId': {'stringValue': requesterDevice},
  'recipientUid': {'stringValue': recipientUid},
  'recipientPublicId': {'stringValue': recipientPublicId},
  'recipientDeviceId': {'stringValue': recipientDevice},
  'status': {'stringValue': status},
  'createdAt': {'timestampValue': '1970-01-01T00:00:00Z'},
  'updatedAt': {'timestampValue': '1970-01-01T00:00:00Z'},
};

/// Runs the app's exact two-step flow: create as the requester, then the
/// recipient's atomic status update (the only write that can change it).
Future<void> _acceptRequest({
  required _User requester,
  required String requesterPublicId,
  required String requesterDevice,
  required _User recipient,
  required String recipientPublicId,
  required String recipientDevice,
}) async {
  final id = _requestId(requester.uid, recipient.uid);
  final created = await _create(
    requester,
    'connectionRequests',
    id,
    _requestFields(
      requesterUid: requester.uid,
      requesterPublicId: requesterPublicId,
      requesterDevice: requesterDevice,
      recipientUid: recipient.uid,
      recipientPublicId: recipientPublicId,
      recipientDevice: recipientDevice,
    ),
  );
  expect(created.status, 200, reason: 'create request: ${created.body}');

  final fields = await _fields(recipient, 'connectionRequests', id);
  fields['status'] = {'stringValue': 'accepted'};
  final accepted = await _replace(
    recipient,
    'connectionRequests',
    id,
    fields,
    serverTimeFields: ['updatedAt'],
  );
  expect(accepted.status, 200, reason: 'accept request: ${accepted.body}');
}

/// The same document with only the status changed — every other field is
/// re-supplied byte-identical, so only `status`/`updatedAt` are affected
/// and the update rule's `hasOnly` can hold.
Map<String, dynamic> _withStatus(Map<String, dynamic> fields, String status) {
  final next = Map<String, dynamic>.from(fields);
  next['status'] = {'stringValue': status};
  return next;
}

/// Attachment metadata as Firestore stores it: a map (never bytes).
Map<String, dynamic> _attachmentFields({
  required String messageId,
  required String senderDeviceId,
  String kind = 'image',
  String mimeType = 'image/png',
  int size = 1024 * 1024,
  String? storagePath,
  String? attachmentId,
  String fileName = 'photo.png',
  bool withExtraField = false,
}) => {
  'mapValue': {
    'fields': {
      'attachmentId': {'stringValue': attachmentId ?? messageId},
      'fileName': {'stringValue': fileName},
      'mimeType': {'stringValue': mimeType},
      'size': {'integerValue': '$size'},
      'storagePath': {
        'stringValue': storagePath ?? 'attachments/$senderDeviceId/$messageId',
      },
      'kind': {'stringValue': kind},
      if (withExtraField) 'evil': {'stringValue': 'nope'},
    },
  },
};

Map<String, dynamic> _messageFields({
  required String id,
  required String senderUid,
  required String senderDeviceId,
  required String recipientUid,
  required String recipientDeviceId,
  String content = 'hello',
  String status = 'sent',
  Map<String, dynamic>? attachment,
}) {
  return {
    'messageId': {'stringValue': id},
    'senderUid': {'stringValue': senderUid},
    'senderDeviceId': {'stringValue': senderDeviceId},
    'recipientUid': {'stringValue': recipientUid},
    'recipientDeviceId': {'stringValue': recipientDeviceId},
    'content': {'stringValue': content},
    'status': {'stringValue': status},
    if (attachment != null) 'attachment': attachment,
    // Placeholder: replaced by the write's REQUEST_TIME transform so the
    // `createdAt == request.time` rule can hold for a client write.
    'createdAt': {'timestampValue': '1970-01-01T00:00:00Z'},
    'deliveredAt': {'nullValue': null},
  };
}

Map<String, dynamic> _createWrite(
  String name,
  Map<String, dynamic> fields,
) {
  return {
    'update': {'name': name, 'fields': fields},
    'updateTransforms': [
      {'fieldPath': 'createdAt', 'setToServerValue': 'REQUEST_TIME'},
    ],
    'currentDocument': {'exists': false},
  };
}

/// The same document with the recipient's delivery acknowledgement applied,
/// timestamped by the server so only the intended rule condition can fail.
Map<String, dynamic> _withAck(Map<String, dynamic> fields) {
  final acked = Map<String, dynamic>.from(fields);
  acked['status'] = {'stringValue': 'delivered'};
  return acked;
}
