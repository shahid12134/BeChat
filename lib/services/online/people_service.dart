import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:bechat/services/online/device_registry.dart';
import 'package:bechat/services/online/firebase_bootstrap.dart';

const usersCollection = 'users';
const publicIdsCollection = 'publicIds';
const requestsCollection = 'connectionRequests';

const requestPending = 'pending';
const requestAccepted = 'accepted';
const requestDeclined = 'declined';

/// Crockford-style alphabet: no 0/O/1/I/L, so an ID read over the phone
/// cannot be mistyped into a different one.
const _idAlphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
const _idLength = 8;

/// Generates a shareable BeChat ID such as `BC-7K9P-42MX`.
///
/// Uniqueness is enforced by the `publicIds/{id}` document id in Firestore,
/// not by this generator: a collision surfaces as an already-exists error and
/// the caller claims another ID. The 32^8 space only makes that rare.
String generatePublicId([Random? random]) {
  final rng = random ?? Random.secure();
  final body = List.generate(
    _idLength,
    (_) => _idAlphabet[rng.nextInt(_idAlphabet.length)],
  ).join();
  return 'BC-${body.substring(0, 4)}-${body.substring(4)}';
}

/// Normalizes user input (`bc-7k9p 42mx`, lower case, stray spaces) to the
/// canonical `BC-XXXX-XXXX` form, or null when it cannot be an ID. Ambiguous
/// characters (0/O/1/I/L) are rejected rather than guessed.
String? normalizePublicId(String input) {
  final raw = input.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
  if (raw.length != 2 + _idLength || !raw.startsWith('BC')) return null;
  final body = raw.substring(2);
  for (final char in body.split('')) {
    if (!_idAlphabet.contains(char)) return null;
  }
  return 'BC-${body.substring(0, 4)}-${body.substring(4)}';
}

/// Deterministic request id: the pair of uids sorted, so both directions —
/// and any concurrent submission from either side — resolve to the SAME
/// document, and Firestore's create-only semantics make duplicates
/// impossible even under concurrency. `firestore.rules` derives the
/// identical id (`pairId`) and refuses any write whose document id is not
/// the sorted pair.
String connectionRequestId(String requesterUid, String recipientUid) =>
    requesterUid.compareTo(recipientUid) <= 0
    ? '$requesterUid.$recipientUid'
    : '$recipientUid.$requesterUid';

/// Friendly failure for the UI: always a single readable sentence, never a
/// raw platform or Firestore error dump.
class PeopleException implements Exception {
  const PeopleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Shown when this device's `deviceRegistry` binding belongs to another
/// account: the rules would refuse every request it sends, so say why.
const deviceConflictMessage =
    'This device is already linked to a different BeChat account, so it '
    'cannot send connection requests. Open BeChat on the account that '
    'registered it, or reinstall to register this device again.';

/// Why a connection request cannot be created, decided from `publicIds` and
/// `deviceRegistry` state alone. `firestore.rules` gates the create on exactly
/// these facts, so checking them first turns a bare `permission-denied` into a
/// message that names the actual problem.
enum ConnectionRequestBlocker {
  /// `publicIds/{id}` is missing or belongs to someone else.
  targetProfileInvalid,

  /// The target device has no `deviceRegistry` binding at all.
  targetDeviceMissing,

  /// The target device is bound to an account other than the claimed ID.
  targetDeviceMismatch,
}

/// The first reason [targetUid] cannot be requested, or null when nothing
/// blocks it. Pure: the caller supplies the already-read owners.
ConnectionRequestBlocker? connectionRequestBlocker({
  required String targetUid,
  required String? targetProfileUid,
  required String? targetDeviceOwnerUid,
}) {
  if (targetProfileUid != targetUid) {
    return ConnectionRequestBlocker.targetProfileInvalid;
  }
  if (targetDeviceOwnerUid == null) {
    return ConnectionRequestBlocker.targetDeviceMissing;
  }
  return targetDeviceOwnerUid == targetUid
      ? null
      : ConnectionRequestBlocker.targetDeviceMismatch;
}

/// User-facing explanation for [blocker]. No ids or raw Firestore errors.
String connectionRequestBlockerMessage(ConnectionRequestBlocker blocker) {
  switch (blocker) {
    case ConnectionRequestBlocker.targetProfileInvalid:
      return 'That BeChat ID is no longer active. Search for it again.';
    case ConnectionRequestBlocker.targetDeviceMissing:
      return 'That person has not finished setting up BeChat on their '
          'device yet. Ask them to open BeChat, then try again.';
    case ConnectionRequestBlocker.targetDeviceMismatch:
      return 'That BeChat ID is linked to a different device. Ask them to '
          'reopen BeChat, then try again.';
  }
}

/// Message for a request document that already exists for this pair. A second
/// create is impossible (the deterministic id is create-only), so this is what
/// the user is told instead. [incoming] describes the direction: whether the
/// existing request was addressed to this user.
String existingRequestMessage(String status, {bool incoming = false}) {
  switch (status) {
    case requestAccepted:
      return 'You are already connected with this person — message them from '
          'Contacts.';
    case requestDeclined:
      return incoming
          ? 'You declined their request. Remove it from Incoming before '
                'sending a new one.'
          : 'This person declined an earlier request. Remove it from Sent '
                'requests before sending another.';
    default:
      return incoming
          ? 'They already sent you a request — accept it from Incoming.'
          : 'You already sent this person a request.';
  }
}

/// Minimal public profile shown by ID search and stored on requests.
class BeChatProfile {
  const BeChatProfile({
    required this.uid,
    required this.publicId,
    required this.displayName,
    required this.deviceId,
  });

  factory BeChatProfile.fromMap(String uid, Map<String, dynamic> data) =>
      BeChatProfile(
        uid: uid,
        publicId: data['publicId'] as String? ?? '',
        displayName: data['displayName'] as String? ?? 'BeChat user',
        deviceId: data['deviceId'] as String? ?? '',
      );

  final String uid;
  final String publicId;
  final String displayName;
  final String deviceId;

  Map<String, dynamic> toMap() => {
    'publicId': publicId,
    'displayName': displayName,
    'deviceId': deviceId,
  };
}

class ConnectionRequest {
  const ConnectionRequest({
    required this.requestId,
    required this.requesterUid,
    required this.requesterPublicId,
    required this.requesterDeviceId,
    required this.recipientUid,
    required this.recipientPublicId,
    required this.recipientDeviceId,
    required this.status,
    required this.createdAt,
  });

  factory ConnectionRequest.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final createdAt = data['createdAt'];
    return ConnectionRequest(
      requestId: doc.id,
      requesterUid: data['requesterUid'] as String? ?? '',
      requesterPublicId: data['requesterPublicId'] as String? ?? '',
      requesterDeviceId: data['requesterDeviceId'] as String? ?? '',
      recipientUid: data['recipientUid'] as String? ?? '',
      recipientPublicId: data['recipientPublicId'] as String? ?? '',
      recipientDeviceId: data['recipientDeviceId'] as String? ?? '',
      status: data['status'] as String? ?? requestPending,
      createdAt: createdAt is Timestamp ? createdAt.toDate() : null,
    );
  }

  final String requestId;
  final String requesterUid;
  final String requesterPublicId;
  final String requesterDeviceId;
  final String recipientUid;
  final String recipientPublicId;
  final String recipientDeviceId;
  final String status;
  final DateTime? createdAt;

  /// The BeChat profile of the other party, from this request's own frozen
  /// fields — no extra reads to render a contact or request row.
  BeChatProfile otherParty(String myUid) => myUid == requesterUid
      ? BeChatProfile(
          uid: recipientUid,
          publicId: recipientPublicId,
          displayName: '',
          deviceId: recipientDeviceId,
        )
      : BeChatProfile(
          uid: requesterUid,
          publicId: requesterPublicId,
          displayName: '',
          deviceId: requesterDeviceId,
        );
}

/// Firebase-backed public IDs, connection requests and accepted contacts.
///
/// All authorization is enforced by `firestore.rules`; this service only
/// keeps the client honest (self-request and duplicate checks) and turns
/// failures into readable messages.
class PeopleService {
  PeopleService({
    required String? Function() localDeviceId,
    required String Function() displayName,
    FirebaseFirestore? db,
    FirebaseAuth? auth,
    this.timeout = const Duration(seconds: 10),
  }) : _localDeviceId = localDeviceId,
       _displayName = displayName,
       _dbOverride = db,
       _authOverride = auth;

  final String? Function() _localDeviceId;
  final String Function() _displayName;
  final FirebaseFirestore? _dbOverride;
  final FirebaseAuth? _authOverride;
  final Duration timeout;

  FirebaseFirestore get _db => _dbOverride ?? FirebaseFirestore.instance;
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;

  /// Signs in anonymously when needed and returns the Firebase user, so the
  /// ID/request flows work even when the transport has not started yet.
  Future<User> _requireUser() async {
    await FirebaseBootstrap.ensureInitialized();
    final existing = _auth.currentUser;
    if (existing != null) return existing;
    final result = await _auth.signInAnonymously().timeout(timeout);
    final user = result.user;
    if (user == null) throw const PeopleException('Sign-in failed. Try again.');
    return user;
  }

  DocumentReference<Map<String, dynamic>> _userDoc(String uid) =>
      _db.collection(usersCollection).doc(uid);

  /// The caller's own profile, creating the public ID on first use.
  ///
  /// The ID lives in `users/{uid}` (read by its owner) plus the claimed
  /// `publicIds/{id}` document, which is what other people search. Both are
  /// server-persisted, so the same ID is reused across restarts and is never
  /// regenerated by reconnects.
  Future<BeChatProfile> ensureMyProfile() async {
    try {
      final user = await _requireUser();
      final existing = await _userDoc(user.uid).get().timeout(timeout);
      if (existing.exists) {
        return BeChatProfile.fromMap(user.uid, existing.data()!);
      }
      final deviceId = _localDeviceId();
      if (deviceId == null) {
        throw const PeopleException(
          'This device is not registered yet. Try again once BeChat is online.',
        );
      }
      final name = _displayName();
      for (var attempt = 0; attempt < 5; attempt++) {
        final publicId = generatePublicId();
        final claim = _db.collection(publicIdsCollection).doc(publicId);
        // The claim is create-only: an existing document means someone else
        // owns this ID, so take another one instead of overwriting them.
        // `firestore.rules` backs this up — claims carry no update rule.
        final taken = await claim
            .get(GetOptions(source: Source.server))
            .timeout(timeout);
        if (taken.exists) continue; // collision → retry
        await claim.set({
          'uid': user.uid,
          'publicId': publicId,
          'displayName': name,
          'deviceId': deviceId,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }).timeout(timeout);
        try {
          await _userDoc(user.uid).set({
            'publicId': publicId,
            'displayName': name,
            'deviceId': deviceId,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          }).timeout(timeout);
        } catch (_) {
          // Never leave a claimed ID without its profile: release the claim
          // (best effort) so the next attempt starts clean.
          try {
            await claim.delete().timeout(timeout);
          } catch (_) {}
          rethrow;
        }
        return BeChatProfile(
          uid: user.uid,
          publicId: publicId,
          displayName: name,
          deviceId: deviceId,
        );
      }
      throw const PeopleException(
        'Could not claim a unique BeChat ID right now. Try again.',
      );
    } on PeopleException {
      rethrow;
    } on TimeoutException {
      throw const PeopleException('Firebase is not responding right now.');
    } on FirebaseException catch (error) {
      throw PeopleException(_messageFor(error));
    } catch (_) {
      throw const PeopleException('Could not load your BeChat ID.');
    }
  }

  /// Looks one ID up against the server and returns the minimal preview
  /// (name + public ID + device id — nothing secret).
  Future<BeChatProfile> searchPublicId(String input) async {
    final publicId = normalizePublicId(input);
    if (publicId == null) {
      throw const PeopleException(
        'That does not look like a BeChat ID. It looks like BC-7K9P-42MX.',
      );
    }
    try {
      final user = await _requireUser();
      final snap = await _db
          .collection(publicIdsCollection)
          .doc(publicId)
          .get(GetOptions(source: Source.server))
          .timeout(timeout);
      final data = snap.data();
      if (!snap.exists || data == null) {
        throw const PeopleException('No BeChat user uses that ID.');
      }
      final profile = BeChatProfile.fromMap(data['uid'] as String? ?? '', data);
      if (profile.uid == user.uid) {
        throw const PeopleException('That is your own BeChat ID.');
      }
      if (profile.deviceId.isEmpty || profile.uid.isEmpty) {
        throw const PeopleException('That profile is incomplete.');
      }
      return profile;
    } on PeopleException {
      rethrow;
    } on TimeoutException {
      throw const PeopleException('Firebase is not responding right now.');
    } on FirebaseException catch (error) {
      throw PeopleException(_messageFor(error));
    } catch (_) {
      throw const PeopleException('Search failed. Try again.');
    }
  }

  /// Sends a connection request to [target].
  ///
  /// `firestore.rules` only allows the create when BOTH frozen device ids
  /// resolve to the claimed UIDs through `deviceRegistry`, so this method first
  /// makes sure the local device is registered (reusing the transport's own
  /// binding, never taking over a foreign one) and then checks the target's
  /// claim and device binding. Without those checks the refusal arrives as a
  /// bare `permission-denied`, which says nothing about what is wrong.
  ///
  /// The deterministic request id still gives each pair exactly one document;
  /// the duplicate checks only save a round trip, the rules are what enforce
  /// uniqueness, self-requests and forged identities.
  Future<void> sendRequest(BeChatProfile target) async {
    try {
      final user = await _requireUser();
      if (target.uid == user.uid) {
        throw const PeopleException('You cannot send a request to yourself.');
      }
      // Looked up through the two authorized equality queries, never by
      // reading the deterministic id: a connectionRequests document is
      // readable only by its two parties, and a document that does not exist
      // yet has no parties — so a pre-flight get() on it is itself denied by
      // the rules (that denial used to surface as a bogus failure).
      final pair = await _requestWith(user.uid, target.uid);
      if (pair != null) {
        throw PeopleException(
          existingRequestMessage(
            pair.status,
            incoming: pair.recipientUid == user.uid,
          ),
        );
      }
      final own = await ensureMyProfile();

      // The device frozen into the request must be registered to THIS account,
      // otherwise the rules' ownerOf(senderDeviceId) check fails. The current
      // device wins over a stale profile device id.
      final requesterDeviceId = _localDeviceId() ?? own.deviceId;
      final binding = await ensureDeviceRegistered(
        _db,
        deviceId: requesterDeviceId,
        uid: user.uid,
        timeout: timeout,
      );
      if (binding == RegistryBinding.conflict) {
        throw const PeopleException(deviceConflictMessage);
      }

      final blocker = await _targetBlocker(target);
      if (blocker != null) {
        throw PeopleException(connectionRequestBlockerMessage(blocker));
      }

      // Written directly, with no read of the target document first: it does
      // not exist yet, and reading it is not permitted before it does.
      // `allow create` authorizes this write; a repeat lands on the update
      // rule, which only the recipient's accept/decline can satisfy — so an
      // existing request can never be overwritten, no client check needed.
      await _db
          .collection(requestsCollection)
          .doc(connectionRequestId(user.uid, target.uid))
          .set({
            'requesterUid': user.uid,
            'requesterPublicId': own.publicId,
            'requesterDeviceId': requesterDeviceId,
            'recipientUid': target.uid,
            'recipientPublicId': target.publicId,
            'recipientDeviceId': target.deviceId,
            'status': requestPending,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          })
          .timeout(timeout);
    } on PeopleException {
      rethrow;
    } on TimeoutException {
      throw const PeopleException('Firebase is not responding right now.');
    } on FirebaseException catch (error) {
      if (error.code == 'permission-denied') {
        throw await _explainRefusedRequest(target);
      }
      throw PeopleException(_messageFor(error));
    } catch (_) {
      throw const PeopleException('Could not send the request.');
    }
  }

  /// Reads the target's claim and device binding — the two facts
  /// `connectionRequests.create` checks server-side.
  Future<ConnectionRequestBlocker?> _targetBlocker(
    BeChatProfile target,
  ) async {
    if (target.publicId.isEmpty || target.deviceId.isEmpty) {
      return ConnectionRequestBlocker.targetProfileInvalid;
    }
    final claim = await _db
        .collection(publicIdsCollection)
        .doc(target.publicId)
        .get(GetOptions(source: Source.server))
        .timeout(timeout);
    final claimUid = claim.data()?['uid'];
    final deviceOwner = await registeredOwnerOf(
      _db,
      target.deviceId,
      timeout: timeout,
    );
    return connectionRequestBlocker(
      targetUid: target.uid,
      targetProfileUid: claimUid is String && claimUid.isNotEmpty
          ? claimUid
          : null,
      targetDeviceOwnerUid: deviceOwner,
    );
  }

  /// The one request document for this pair, or null. Both equality queries
  /// filter on the caller's own uid, which is what `allow read` can prove.
  Future<ConnectionRequest?> _requestWith(
    String uid,
    String otherUid,
  ) async {
    final rows = [
      ...await _incomingRequests(uid),
      ...await _sentRequests(uid),
    ].where(
      (r) => r.requesterUid == otherUid || r.recipientUid == otherUid,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Turns a rules refusal into the reason it actually happened, by re-reading
  /// the same facts the rules gate on — through authorized queries and the
  /// registry, never by reading the request document by id. Best effort: if
  /// the re-read itself fails, the caller still gets an honest message instead
  /// of a misleading "already connected".
  Future<PeopleException> _explainRefusedRequest(BeChatProfile target) async {
    try {
      final user = await _requireUser();
      final pair = await _requestWith(user.uid, target.uid);
      if (pair != null) {
        return PeopleException(
          existingRequestMessage(
            pair.status,
            incoming: pair.recipientUid == user.uid,
          ),
        );
      }
      final deviceId = _localDeviceId();
      if (deviceId != null) {
        final owner = await registeredOwnerOf(
          _db,
          deviceId,
          timeout: timeout,
        );
        if (owner != null && owner != user.uid) {
          return const PeopleException(deviceConflictMessage);
        }
      }
      final blocker = await _targetBlocker(target);
      if (blocker != null) {
        return PeopleException(connectionRequestBlockerMessage(blocker));
      }
    } catch (_) {
      // A failed diagnostic must not replace the real failure.
    }
    return const PeopleException(
      'Firebase refused the request. Check your connection and try again.',
    );
  }

  /// Pending requests addressed to me.
  Future<List<ConnectionRequest>> incomingRequests() async {
    try {
      final user = await _requireUser();
      final rows = await _incomingRequests(user.uid);
      return rows.where((r) => r.status == requestPending).toList()
        ..sort((a, b) => b.createdAt?.compareTo(a.createdAt ?? DateTime(0)) ?? 0);
    } on PeopleException {
      rethrow;
    } catch (_) {
      throw const PeopleException('Could not load incoming requests.');
    }
  }

  /// Requests I sent, in their current status (pending/declined/accepted).
  Future<List<ConnectionRequest>> sentRequests() async {
    try {
      final user = await _requireUser();
      final rows = await _sentRequests(user.uid);
      rows.sort(
        (a, b) => b.createdAt?.compareTo(a.createdAt ?? DateTime(0)) ?? 0,
      );
      return rows;
    } on PeopleException {
      rethrow;
    } catch (_) {
      throw const PeopleException('Could not load sent requests.');
    }
  }

  /// Every accepted relationship, from either direction (a pair has at most
  /// one request document, so no dedup is needed).
  Future<List<ConnectionRequest>> contacts() async {
    try {
      final user = await _requireUser();
      final incoming = await _incomingRequests(user.uid);
      final sent = await _sentRequests(user.uid);
      final all = [...incoming, ...sent]
          .where((r) => r.status == requestAccepted)
          .toList();
      all.sort(
        (a, b) => b.createdAt?.compareTo(a.createdAt ?? DateTime(0)) ?? 0,
      );
      return all;
    } on PeopleException {
      rethrow;
    } catch (_) {
      throw const PeopleException('Could not load contacts.');
    }
  }

  /// Accept or decline — only the recipient may do this (enforced by rules).
  Future<void> respond(ConnectionRequest request, String status) async {
    assert(status == requestAccepted || status == requestDeclined);
    try {
      final user = await _requireUser();
      if (request.recipientUid != user.uid) {
        throw const PeopleException(
          'Only the recipient can respond to a request.',
        );
      }
      await _db
          .collection(requestsCollection)
          .doc(request.requestId)
          .update({
            'status': status,
            'updatedAt': FieldValue.serverTimestamp(),
          })
          .timeout(timeout);
    } on PeopleException {
      rethrow;
    } on TimeoutException {
      throw const PeopleException('Firebase is not responding right now.');
    } on FirebaseException catch (error) {
      if (error.code == 'permission-denied') {
        throw const PeopleException('Only the recipient can respond.');
      }
      throw PeopleException(_messageFor(error));
    } catch (_) {
      throw const PeopleException('Could not update the request.');
    }
  }

  /// Removes the relationship (either side) or cancels a request I sent.
  Future<void> removeRequest(ConnectionRequest request) async {
    try {
      await _requireUser();
      await _db
          .collection(requestsCollection)
          .doc(request.requestId)
          .delete()
          .timeout(timeout);
    } on TimeoutException {
      throw const PeopleException('Firebase is not responding right now.');
    } on FirebaseException catch (error) {
      if (error.code == 'permission-denied') {
        throw const PeopleException('You cannot remove this request.');
      }
      throw PeopleException(_messageFor(error));
    } catch (_) {
      throw const PeopleException('Could not remove the request.');
    }
  }

  Future<List<ConnectionRequest>> _incomingRequests(String uid) async {
    final snap = await _db
        .collection(requestsCollection)
        .where('recipientUid', isEqualTo: uid)
        .get()
        .timeout(timeout);
    return snap.docs.map(ConnectionRequest.fromDoc).toList();
  }

  Future<List<ConnectionRequest>> _sentRequests(String uid) async {
    final snap = await _db
        .collection(requestsCollection)
        .where('requesterUid', isEqualTo: uid)
        .get()
        .timeout(timeout);
    return snap.docs.map(ConnectionRequest.fromDoc).toList();
  }

  static String _messageFor(FirebaseException error) {
    switch (error.code) {
      case 'permission-denied':
        return 'Not allowed. Your account may need to be re-registered.';
      case 'unavailable':
      case 'network-request-failed':
        return 'You appear to be offline. Try again once connected.';
      case 'not-found':
        return 'That profile no longer exists.';
      default:
        return 'Firebase error: ${error.message ?? error.code}.';
    }
  }
}
