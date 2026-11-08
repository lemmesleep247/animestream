import 'package:animestream/core/commons/hlsParser/audioStream.dart';
import 'package:animestream/core/commons/hlsParser/qualityStream.dart';
import 'package:xml/xml.dart';

/// Represents parsed subtitle stream inside DASH manifest
class DashSubtitleStream {
  final String language;
  final String url;
  final String format;
  final String name;

  const DashSubtitleStream({
    required this.language,
    required this.url,
    required this.format,
    required this.name,
  });

  @override
  String toString() {
    return 'DashSubtitleStream(lang: $language, format: $format, url: $url)';
  }
}

/// Represents a single DASH Representation node and its segment configuration
class DashRepresentation {
  final String id;
  final String contentType; // "video", "audio", "text"
  final int bandwidth;
  final int? width;
  final int? height;
  final String? codecs;
  final String? frameRate;
  final int? audioSamplingRate;
  final String? language;
  final String? mimeType;

  /// Effective BaseURL after resolving through MPD -> Period -> AdaptationSet -> Representation
  final Uri effectiveBaseUri;

  /// The XML representation element
  final XmlElement representationElement;

  /// Parent AdaptationSet element
  final XmlElement adaptationSetElement;

  /// Parent Period element
  final XmlElement periodElement;

  /// Effective SegmentTemplate element, if defined
  final XmlElement? segmentTemplate;

  /// Effective SegmentList element, if defined
  final XmlElement? segmentList;

  const DashRepresentation({
    required this.id,
    required this.contentType,
    required this.bandwidth,
    this.width,
    this.height,
    this.codecs,
    this.frameRate,
    this.audioSamplingRate,
    this.language,
    this.mimeType,
    required this.effectiveBaseUri,
    required this.representationElement,
    required this.adaptationSetElement,
    required this.periodElement,
    this.segmentTemplate,
    this.segmentList,
  });

  String get resolutionString => (width != null && height != null) ? "${width}x$height" : "??";
  String get qualityString => height != null ? "${height}p" : "default";

  @override
  String toString() {
    return 'DashRepresentation(id: $id, type: $contentType, quality: $qualityString, bw: $bandwidth)';
  }
}

/// Represents the top-level parsed DASH manifest
class DashManifest {
  /// Video streams mapped into AnimeStream's standard [QualityStream] for compatibility
  final List<QualityStream> qualityStreams;

  /// Audio streams mapped into AnimeStream's standard [AudioStream] for compatibility
  final List<AudioStream> audioStreams;

  /// Embedded subtitle streams, if any
  final List<DashSubtitleStream> subtitleStreams;

  /// Total duration of the media presentation
  final Duration? duration;

  /// Whether this is a dynamic (live) stream or static (VOD)
  final bool isLive;

  /// All parsed raw representations with their underlying XML and templates
  final List<DashRepresentation> representations;

  /// The original manifest URL
  final String manifestUrl;

  const DashManifest({
    required this.qualityStreams,
    required this.audioStreams,
    required this.subtitleStreams,
    this.duration,
    required this.isLive,
    required this.representations,
    required this.manifestUrl,
  });

  /// Quick helper to find a representation by stream URL or Representation ID
  DashRepresentation? findRepresentation(String idOrUrl) {
    return representations.where((r) => r.id == idOrUrl || r.effectiveBaseUri.toString() == idOrUrl).firstOrNull;
  }

  @override
  String toString() {
    return 'DashManifest(duration: $duration, live: $isLive, videos: ${qualityStreams.length}, audios: ${audioStreams.length}, subs: ${subtitleStreams.length})';
  }
}

