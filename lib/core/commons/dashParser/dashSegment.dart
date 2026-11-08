import 'dart:typed_data';

import 'package:animestream/core/commons/streams/mediaSegment.dart';

class DashSegment implements MediaSegment {
  /// The full resolved URL of the segment
  @override
  final String url;

  /// Duration of this segment in seconds
  final double duration;

  /// Sequence number or index of the segment
  final int sequenceNumber;

  /// Whether this is an initialization segment (e.g., init.mp4 containing moov/ftyp box)
  final bool isInitSegment;

  /// Optional byte range within [url], as given in the manifest (e.g. "0-1024")
  @override
  final String? byteRange;

  /// Custom HTTP headers required to fetch the segment, if any
  final Map<String, String>? headers;

  const DashSegment({
    required this.url,
    required this.duration,
    required this.sequenceNumber,
    this.isInitSegment = false,
    this.byteRange,
    this.headers,
  });

  @override
  bool get isInit => isInitSegment;

  // DRM-protected representations are rejected at manifest level, so segments are plain.
  @override
  Future<Uint8List> prepare(Uint8List raw, {Map<String, String> headers = const {}}) async => raw;

  @override
  String toString() {
    return 'DashSegment(seq: $sequenceNumber, duration: ${duration}s, init: $isInitSegment, url: $url, range: $byteRange)';
  }
}
