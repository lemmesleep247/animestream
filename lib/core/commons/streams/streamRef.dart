import 'package:animestream/core/commons/dashParser/dashParser.dart';
import 'package:animestream/core/commons/hlsParser/hlsParser.dart';
import 'package:animestream/core/commons/streams/mediaSegment.dart';

/// Describes where a single track's segments come from.
///
/// Plain immutable data, so it can be handed to download isolates as is.
/// The parsing happens on demand via [segments], wherever it's called.
sealed class StreamRef {
  const StreamRef();

  Future<List<MediaSegment>> segments({Map<String, String> headers = const {}});
}

/// A HLS media playlist (the per-quality `.m3u8`, not the master playlist).
final class HlsRef extends StreamRef {
  final String playlistUrl;

  const HlsRef(this.playlistUrl);

  @override
  Future<List<MediaSegment>> segments({Map<String, String> headers = const {}}) =>
      HlsParser.parseSegments(playlistUrl, customHeaders: headers);

  @override
  String toString() => 'HlsRef($playlistUrl)';
}

/// One Representation inside a DASH manifest.
final class DashRef extends StreamRef {
  final String manifestUrl;
  final String representationId;

  const DashRef(this.manifestUrl, this.representationId);

  @override
  Future<List<MediaSegment>> segments({Map<String, String> headers = const {}}) async {
    // no cache since when this is run on isolate, Hive boxed arent available.
    final manifest = await DashParser.parseManifest(manifestUrl, customHeader: headers, useCache: false);
    final rep = manifest.findRepresentation(representationId);
    if (rep == null) {
      throw Exception("Representation '$representationId' not found in $manifestUrl");
    }
    return DashParser.parseSegments(rep, overrideDuration: manifest.duration, customHeaders: headers);
  }

  @override
  String toString() => 'DashRef($manifestUrl#$representationId)';
}
