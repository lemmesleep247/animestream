import 'package:animestream/core/commons/streams/streamRef.dart';

class QualityStream {
  String quality;
  String url;
  String resolution;
  String? audioGroup;
  int? bandwidth;

  final StreamRef? _ref;

  /// Where this quality's segments come from. Defaults to treating [url] as a HLS media playlist.
  StreamRef get ref => _ref ?? HlsRef(url);

  QualityStream({
    required this.quality,
    required this.url,
    required this.resolution,
    this.audioGroup,
    this.bandwidth,
    StreamRef? ref,
  }) : _ref = ref;

  factory QualityStream.paceholder() {
    return QualityStream(quality: "unset", url: "unknown", resolution: "0x0");
  }

  Map<String, dynamic> toMap() {
    return {
      'quality': quality,
      'url': url,
      'resolution': resolution,
      'audioGroup': audioGroup,
      'bandwidth': bandwidth,
    };
  }

  @override
  String toString() {
    return 'QualityStream(quality: $quality, url: $url, resolution: $resolution, audioGroup: $audioGroup, bandwidth: $bandwidth, ref: $ref)';
  }
}

class QualityStreamBuilder {
  String? quality;
  String? url;
  String? resolution;
  String? audioGroup;
  int? bandwidth;

  void addResolution(String resolution) => this.resolution = resolution;
  void addUrl(String url) => this.url = url;
  void addQuality(String quality) => this.quality = quality;
  void addBandwidth(int bandwidth) => this.bandwidth = bandwidth;
  void addAudioGroup(String audioGroup) => this.audioGroup = audioGroup;

  QualityStream build() {
    if (quality == null || url == null || resolution == null) {
      print("res: $resolution, url: $url, quality: $quality");
      throw Exception("One of the required arguments for the QualityStream was received as null");
    }
    return QualityStream(
      quality: quality!,
      url: url!,
      resolution: resolution!,
      audioGroup: audioGroup,
      bandwidth: bandwidth,
    );
  }
}
