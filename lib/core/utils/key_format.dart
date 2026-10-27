/// Encoding validation for the non-secret key metadata BeChat persists.
///
/// These helpers check *shape* only. A well-formed public key is not a trusted
/// public key: trust comes from the authenticated handshake workflow, never
/// from parsing or from a device identifier matching a stored row.
class KeyFormat {
  const KeyFormat._();

  /// A 32-byte key or digest written as lowercase hex (64 characters).
  static final RegExp hex32 = RegExp(r'^[0-9a-f]{64}$');

  /// Opaque reference to native key material (for example a Keystore alias or
  /// envelope identifier).
  ///
  /// Deliberately narrow: names may only contain `[A-Za-z0-9._:-]` up to 128
  /// characters. That rejects filesystem paths, base64 blobs and anything else
  /// that could smuggle private key material, a decrypted envelope or a
  /// user-specific location into SQLite.
  static final RegExp opaqueReference = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');

  /// Whether [value] is a 32-byte value in the canonical lowercase-hex form.
  ///
  /// Uppercase hex, other lengths or non-hex characters are rejected rather
  /// than normalized: an unexpected encoding means the caller is confused
  /// about what it is storing.
  static bool isHex32(String value) => hex32.hasMatch(value);

  /// Whether [value] is a safe opaque reference (see [opaqueReference]).
  ///
  /// A 32-byte hex value is refused even though its characters are allowed:
  /// that is the exact shape of BeChat key material and fingerprints, and a
  /// reference must never be a key.
  static bool isOpaqueReference(String value) =>
      !isHex32(value) && opaqueReference.hasMatch(value);
}
