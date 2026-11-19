import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:bechat/core/constants/app_constants.dart';
import 'package:bechat/data/models/message.dart';
import 'package:bechat/services/online/device_registry.dart';
import 'package:bechat/services/online/firebase_bootstrap.dart';
import 'package:bechat/services/online/online_transport.dart';

const _messages = 'messages';

/// Firestore-backed [OnlineTransport].
///
/// Identity: the device signs in anonymously and binds its BeChat [deviceId]
/// to that Firebase UID in `deviceRegistry`. A registration owned by another
/// UID is never overwritten — the transport simply refuses to come online, so
/// BLE keeps working. Every message document carries both UIDs and both
/// device ids, and `firestore.rules` proves each device id resolves to the
/// UID claimed for it, so a client cannot forge a sender.
class FirestoreOnlineTransport extends OnlineTransport {
  FirestoreOnlineTransport({required this.deviceId});

  final String deviceId;

  /// Upper bound for one Firestore round trip. Exceeding it means the backend
  /// is not answering, so the caller gets its message back instead of an
  /// indefinitely pending claim.
  static const _roundTrip = Duration(seconds: 10);

  FirebaseFirestore? _db;
  String? _uid;
  bool _starting = false;
  OnlineConnectionState _state = OnlineConnectionState.disconnected;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _incoming;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _delivered;

  /// Delivery acks whose write has not been confirmed yet, retried the next
  /// time the backend is reachable — a lost ack must not stay lost.
  final Set<String> _pendingAcks = <String>{};

  @override
  OnlineConnectionState get state => _state;

  @override
  Future<void> start() async {
    if (_starting || _state == OnlineConnectionState.ready) return;
    _starting = true;
    _setState(OnlineConnectionState.connecting);
    try {
      await _connect().timeout(const Duration(seconds: 20));
    } catch (_) {
      // Unconfigured, offline or rejected: stay offline and let BLE take over.
      await _teardown();
    } finally {
      _starting = false;
    }
  }

  Future<void> _connect() async {
    await FirebaseBootstrap.ensureInitialized();
    final auth = FirebaseAuth.instance;
    final user = auth.currentUser ?? (await auth.signInAnonymously()).user;
    if (user == null) throw StateError('Firebase Auth returned no user');

    final db = FirebaseFirestore.instance;
    // Shared with the connection-request flow (`ensureDeviceRegistered`), so a
    // device is bound in exactly one place: an existing binding is reused, a
    // missing one is created, and another UID's is never overwritten.
    final binding = await ensureDeviceRegistered(
      db,
      deviceId: deviceId,
      uid: user.uid,
      timeout: _roundTrip,
    );
    if (binding == RegistryBinding.conflict) {
      // Another identity owns this device id. Never overwrite it, never go
      // online under a stolen id: BLE remains the only transport.
      await _teardown();
      return;
    }

    _db = db;
    _uid = user.uid;
    await _cancelListeners();
    _attach(db, user.uid);
    await _probeServer(db, user.uid);
  }

  Future<void> _teardown() async {
    await _cancelListeners();
    _db = null;
    _uid = null;
    _setState(OnlineConnectionState.disconnected);
  }

  Future<void> _cancelListeners() async {
    await _incoming?.cancel();
    await _delivered?.cancel();
    _incoming = null;
    _delivered = null;
  }

  /// Proves the backend answers rather than guessing from device connectivity:
  /// `Source.server` fails outright when Firestore is unreachable.
  Future<void> _probeServer(FirebaseFirestore db, String uid) async {
    await db
        .collection(_messages)
        .where('recipientUid', isEqualTo: uid)
        .limit(1)
        .get(GetOptions(source: Source.server))
        .timeout(_roundTrip);
    _markReady();
  }

  void _attach(FirebaseFirestore db, String uid) {
    // Queries filter on the UID the rules check, so Firestore can prove the
    // result set is only this device's own conversation before reading it.
    _incoming = db
        .collection(_messages)
        .where('recipientUid', isEqualTo: uid)
        .snapshots()
        .listen(_onIncoming, onError: (Object _) => _markUnreachable());
    _delivered = db
        .collection(_messages)
        .where('senderUid', isEqualTo: uid)
        .where('status', isEqualTo: 'delivered')
        .snapshots()
        .listen(_onDelivered, onError: (Object _) => _markUnreachable());
  }

  void _onIncoming(QuerySnapshot<Map<String, dynamic>> snap) {
    if (!snap.metadata.isFromCache) _markReady();
    // Full scan instead of docChanges: a message whose ack was lost to a
    // dropped connection is still 'sent' here, so it must reach the app again
    // on the next server snapshot. BleMessageStore dedups by message id.
    for (final doc in snap.docs) {
      final data = doc.data();
      if (data['status'] != 'sent') continue;
      final frame = _frame(data);
      if (frame != null) onIncoming?.call(frame);
    }
  }

  void _onDelivered(QuerySnapshot<Map<String, dynamic>> snap) {
    if (!snap.metadata.isFromCache) _markReady();
    for (final change in snap.docChanges) {
      if (change.type == DocumentChangeType.removed) continue;
      final id = change.doc.data()?['messageId'];
      if (id is String) onDelivered?.call(id);
    }
  }

  Map<String, dynamic>? _frame(Map<String, dynamic> data) {
    final messageId = data['messageId'];
    final senderDeviceId = data['senderDeviceId'];
    final receiverDeviceId = data['recipientDeviceId'];
    final content = data['content'];
    if (messageId is! String ||
        senderDeviceId is! String ||
        senderDeviceId.isEmpty ||
        senderDeviceId == deviceId ||
        receiverDeviceId is! String ||
        content is! String ||
        utf8.encode(content).length > AppConstants.maxMessageLength) {
      return null;
    }
    final createdAt = data['createdAt'];
    return {
      'messageId': messageId,
      'senderId': senderDeviceId,
      'receiverId': receiverDeviceId,
      'content': content,
      // Metadata only; the bytes stay in Storage. The manager validates it
      // against the message before showing anything.
      'attachment': data['attachment'],
      'timestamp': createdAt is Timestamp
          ? createdAt.toDate().toUtc().toIso8601String()
          : DateTime.now().toUtc().toIso8601String(),
      'ttl': AppConstants.messageTtlDefault.inSeconds,
    };
  }

  @override
  Future<void> send(Message message) async {
    final db = _db;
    final uid = _uid;
    if (db == null || uid == null || _state != OnlineConnectionState.ready) {
      throw StateError('Firestore transport is not ready');
    }
    try {
      await _write(db, uid, message).timeout(_roundTrip);
    } on TimeoutException {
      throw StateError('Firestore did not accept the message in time');
    }
  }

  Future<void> _write(FirebaseFirestore db, String uid, Message message) async {
    final recipientUid = await registeredOwnerOf(
      db,
      message.receiverId,
      timeout: _roundTrip,
    );
    if (recipientUid == null) {
      throw StateError(
        'recipient device ${message.receiverId} is not registered',
      );
    }
    final ref = db.collection(_messages).doc(message.messageId);
    try {
      // Document id == message id: Firestore enforces uniqueness, so the same
      // id used over BLE can never create a second message.
      await ref.set({
        'messageId': message.messageId,
        'senderUid': uid,
        'senderDeviceId': deviceId,
        'recipientUid': recipientUid,
        'recipientDeviceId': message.receiverId,
        'content': message.content,
        'attachment': message.attachment?.toFirestoreFields(),
        'status': 'sent',
        'createdAt': FieldValue.serverTimestamp(),
        'deliveredAt': null,
      });
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied') rethrow;
      // Rules let a sender create but never rewrite, so a resend of a message
      // Firestore already holds lands here. Confirm it really is ours before
      // calling that a success.
      final existing = await ref.get(GetOptions(source: Source.server));
      if (!existing.exists) rethrow;
    }
  }

  @override
  void sendDelivered(String messageId) {
    _pendingAcks.add(messageId);
    _flushAcks();
  }

  void _flushAcks() {
    final db = _db;
    if (db == null || _state != OnlineConnectionState.ready) return;
    for (final messageId in _pendingAcks.toList()) {
      unawaited(
        db
            .collection(_messages)
            .doc(messageId)
            .update({
              'status': 'delivered',
              'deliveredAt': FieldValue.serverTimestamp(),
            })
            .timeout(_roundTrip)
            .then((_) {
              _pendingAcks.remove(messageId);
            })
            // Still pending: retried on the next reachable snapshot.
            .catchError((Object _) {}),
      );
    }
  }

  void _markReady() {
    if (_state == OnlineConnectionState.ready) return;
    _setState(OnlineConnectionState.ready);
    _flushAcks();
  }

  void _markUnreachable() {
    if (_state == OnlineConnectionState.ready) {
      _setState(OnlineConnectionState.connecting);
    }
  }

  void _setState(OnlineConnectionState next) {
    if (_state == next) return;
    _state = next;
    onStateChanged?.call(next);
  }

  @override
  Future<void> stop() => _teardown();
}
