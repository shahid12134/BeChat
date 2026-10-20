import 'dart:typed_data';

abstract interface class BleTransport {
  int get maximumWriteLength;

  Stream<Uint8List> get incoming;

  Future<void> write(Uint8List value);

  Future<void> close();
}

class BleLinkException implements Exception {
  const BleLinkException(this.message);

  final String message;

  @override
  String toString() => 'BleLinkException: $message';
}
