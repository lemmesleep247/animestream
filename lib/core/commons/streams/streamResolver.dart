import 'package:animestream/core/anime/providers/models/videoStream.dart';
import 'package:animestream/core/commons/dashParser/dashParser.dart';
import 'package:animestream/core/commons/hlsParser/audioStream.dart';
import 'package:animestream/core/commons/hlsParser/hlsParser.dart';
import 'package:animestream/core/commons/hlsParser/qualityStream.dart';

/// The downloadable tracks a provider source expands into.
class ResolvedStreams {
  final List<QualityStream> videos;
  final List<AudioStream> audios;
  final String? subtitleUrl;

  const ResolvedStreams({required this.videos, this.audios = const [], this.subtitleUrl});

  static const empty = ResolvedStreams(videos: []);
}

/// Expands a provider [VideoStream] into selectable qualities and audio tracks, whatever the format.
abstract final class StreamResolver {
  static bool isDash(String url) => url.toLowerCase().split('?').first.endsWith('.mpd');

  static bool isMultiQuality(VideoStream source) => source.quality == "multi-quality" || source.quality == "auto";

  /// Whether [source] needs resolving into multiple qualities (rather than being used as is).
  static bool isExpandable(VideoStream source) => isDash(source.url) || isMultiQuality(source);

  static Future<ResolvedStreams> resolve(VideoStream source) async {
    final headers = source.customHeaders;

    if (isDash(source.url)) {
      final manifest = await DashParser.parseManifest(source.url, customHeader: headers);
      if (manifest.isLive) throw Exception("Live DASH streams can't be downloaded");
      return ResolvedStreams(
        videos: manifest.qualityStreams,
        audios: _bestPerLanguage(manifest.audioStreams),
        subtitleUrl: manifest.subtitleStreams.firstOrNull?.url,
      );
    }

    if (isMultiQuality(source)) {
      final playlist = await HlsParser.parseMasterPlaylist(source.url, customHeader: headers);
      return ResolvedStreams(videos: playlist.qualityStreams, audios: playlist.audioStreams);
    }

    return ResolvedStreams(
      videos: [QualityStream(quality: source.quality, url: source.url, resolution: "??")],
    );
  }

  /// DASH lists every bitrate of a language as its own track; keep only the best one per language.
  static List<AudioStream> _bestPerLanguage(List<AudioStream> audios) {
    final best = <String, AudioStream>{};
    for (final audio in audios) {
      // Unlabelled tracks can't be told apart by language, so keep each of them.
      final key = audio.language == 'und' ? audio.name : audio.language;
      final current = best[key];
      if (current == null || (audio.bandwidth ?? 0) > (current.bandwidth ?? 0)) best[key] = audio;
    }
    return best.values.toList();
  }
}
