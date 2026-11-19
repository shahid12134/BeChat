import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:bechat/firebase_options.dart';

/// One-time Firebase startup.
///
/// Idempotent: [Firebase.apps] already holds an app after the first call, so
/// it is safe to invoke from both `main()` and anywhere that wants to be sure
/// Firebase is usable before touching it.
class FirebaseBootstrap {
  static Future<void> ensureInitialized() async {
    if (Firebase.apps.isNotEmpty) return;
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // shortcut: local Firestore write persistence is disabled so an offline
    // write can never queue behind the SQLite outbox that already owns that
    // message — a later flush would deliver it a second time over a second
    // transport. Ceiling = the app has no Firestore-side offline write queue;
    // upgrade path = one shared write-outbox keyed by messageId.
    try {
      FirebaseFirestore.instance.settings = Settings(persistenceEnabled: false);
    } catch (_) {
      // Web has no persistenceEnabled; it keeps its own cache policy.
    }
  }
}
