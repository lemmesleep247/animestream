import 'dart:typed_data';

/// A single downloadable piece of a track, independent of the streaming protocol it came from.
abstract interface class MediaSegment {
  /// Absolute URL of the segment.
  String get url;

  /// Byte range within [url] to request, in `start-end` form (inclusive). `null` means the whole resource.
  String? get byteRange;

  /// Whether this is an initialization segment (fMP4 `ftyp`/`moov`), rather than media data.
  bool get isInit;

  /// Turns the downloaded bytes into usable media bytes (e.g. decryption). Identity for plain segments.
  Future<Uint8List> prepare(Uint8List raw, {Map<String, String> headers = const {}});
}

/// Builds the `Range` header value for a segment's [MediaSegment.byteRange].
String rangeHeaderValue(String byteRange) => byteRange.startsWith('bytes=') ? byteRange : 'bytes=$byteRange';
