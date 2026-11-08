class DashSegment {
  /// The full resolved URL of the segment
  final String url;

  /// Duration of this segment in seconds
  final double duration;

  /// Sequence number or index of the segment
  final int sequenceNumber;

  /// Whether this is an initialization segment (e.g., init.mp4 containing moov/ftyp box)
  final bool isInitSegment;

  /// Optional byte-range for single-file representation (e.g. "bytes=0-1024")
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
  String toString() {
    return 'DashSegment(seq: $sequenceNumber, duration: ${duration}s, init: $isInitSegment, url: $url, range: $byteRange)';
  }
}

