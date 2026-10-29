import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bechat/services/crypto/native_secure_session_service.dart';

/// The only production construction point for the secure-session gateway.
///
/// Later integration code must go through this provider; none of it may
/// construct a second `bechat/secure_session` channel path. The provider only
/// builds the gateway: it never creates a session, opens a BLE link or owns
/// message delivery, and rebuilding it never closes an existing native
/// session (the native engine owns session lifetime).
final secureSessionGatewayProvider = Provider<SecureSessionGateway>((ref) {
  return NativeSecureSessionGateway();
});
