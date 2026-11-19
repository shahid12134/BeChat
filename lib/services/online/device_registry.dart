import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

/// `deviceRegistry/{deviceId}` binds a BeChat device id to exactly one
/// Firebase UID. `firestore.rules` resolves both device ids of a connection
/// request (and of every online message) through this collection, so a device
/// that is not registered here cannot take part in online messaging at all.
const deviceRegistryCollection = 'deviceRegistry';

/// Outcome of binding a BeChat `deviceId` to the authenticated Firebase UID.
enum RegistryBinding {
  /// No registration existed; this device now owns the id.
  created,

  /// Already bound to this same UID — the normal restart/reconnect case.
  alreadyOwned,

  /// Owned by a *different* UID. Must not be written: refuse and stay offline.
  conflict,
}

/// Decides how to bind `deviceId` to `uid` given the current owner
/// ([existingOwnerUid], `null` when the device has never registered).
///
/// A registration is never created by, transferred to, or overwritten by a
/// foreign UID. `firestore.rules` enforces exactly this server-side — this is
/// the client-side fail-fast, so the app reports a clear conflict instead of
/// surfacing a permission error later.
RegistryBinding resolveBinding(String? existingOwnerUid, String uid) {
  if (existingOwnerUid == null) return RegistryBinding.created;
  return existingOwnerUid == uid
      ? RegistryBinding.alreadyOwned
      : RegistryBinding.conflict;
}

/// The UID that owns [deviceId], or null when the device has never registered.
///
/// Read from the server (`Source.server`) on purpose: a stale cached "missing"
/// would make the caller claim an id that already has an owner, and a stale
/// cached "present" would let a request through that the rules then refuse.
Future<String?> registeredOwnerOf(
  FirebaseFirestore db,
  String deviceId, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  if (deviceId.isEmpty) return null;
  final snap = await db
      .collection(deviceRegistryCollection)
      .doc(deviceId)
      .get(GetOptions(source: Source.server))
      .timeout(timeout);
  final uid = snap.data()?['uid'];
  return uid is String && uid.isNotEmpty ? uid : null;
}

/// Makes sure [deviceId] is registered to [uid], and reports what happened.
///
/// This is the single place a registration is written: the online transport
/// calls it on connect, and the connection-request flow calls it before
/// freezing the device id into a request (otherwise the rules refuse the write
/// because `get(deviceRegistry/{id})` has no `uid` to compare).
///
/// Re-running it is safe — an existing binding owned by [uid] is reused, and a
/// binding owned by anyone else returns [RegistryBinding.conflict] instead of
/// being overwritten.
Future<RegistryBinding> ensureDeviceRegistered(
  FirebaseFirestore db, {
  required String deviceId,
  required String uid,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final binding = resolveBinding(
    await registeredOwnerOf(db, deviceId, timeout: timeout),
    uid,
  );
  if (binding != RegistryBinding.created) return binding;

  await db
      .collection(deviceRegistryCollection)
      .doc(deviceId)
      .set({
        'uid': uid,
        'deviceId': deviceId,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      })
      .timeout(timeout);
  return binding;
}
