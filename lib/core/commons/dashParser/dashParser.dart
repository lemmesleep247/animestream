import 'dart:async';

import 'package:animestream/core/commons/dashParser/dashManifest.dart';
import 'package:animestream/core/commons/dashParser/dashSegment.dart';
import 'package:animestream/core/commons/hlsParser/audioStream.dart';
import 'package:animestream/core/commons/hlsParser/qualityStream.dart';
import 'package:animestream/core/commons/streams/streamRef.dart';
import 'package:animestream/core/network/network.dart';
import 'package:xml/xml.dart';

class DashParser {
  /// Checks whether the URL points to a DASH MPD manifest
  static Future<bool> isMpdManifest(String url, {Map<String, String>? customHeader}) async {
    final cleanUrl = url.toLowerCase().split('?').firstOrNull ?? '';
    if (cleanUrl.endsWith('.mpd')) return true;

    try {
      final res = await get(
        Uri.parse(url),
        headers: {
          ...?customHeader,
          'Range': 'bytes=0-4096',
        },
        cacheDuration: const Duration(hours: 1),
      );

      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      return res.body.contains('<MPD') || res.body.contains('<mpd');
    } catch (_) {
      return false;
    }
  }

  /// Parses a DASH MPD manifest URL into a [DashManifest]
  ///
  /// Pass `useCache: false` when calling from an isolate, where the app's cache storage isn't initialised.
  static Future<DashManifest> parseManifest(
    String manifestUrl, {
    Map<String, String>? customHeader,
    bool useCache = true,
  }) async {
    final baseUri = Uri.parse(manifestUrl);
    final res = await get(
      baseUri,
      headers: customHeader,
      cacheDuration: useCache ? const Duration(hours: 1) : null,
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception("Failed to fetch DASH manifest (HTTP ${res.statusCode})");
    }

    final document = XmlDocument.parse(res.body);
    final mpd = document.getElement('MPD') ??
        document.findElements('MPD').firstOrNull ??
        document.rootElement;

    final typeAttr = mpd.getAttribute('type')?.toLowerCase();
    final isLive = typeAttr == 'dynamic';

    final durationAttr = mpd.getAttribute('mediaPresentationDuration');
    final manifestDuration = _parseIsoDuration(durationAttr);

    // BaseURL resolution starts from the manifest URL
    var currentBaseUri = baseUri;
    final mpdBaseUrl = _findDirectChild(mpd, 'BaseURL')?.innerText.trim();
    if (mpdBaseUrl != null && mpdBaseUrl.isNotEmpty) {
      currentBaseUri = currentBaseUri.resolve(mpdBaseUrl);
    }

    final List<QualityStream> qualityStreams = [];
    final List<AudioStream> audioStreams = [];
    final List<DashSubtitleStream> subtitleStreams = [];
    final List<DashRepresentation> rawRepresentations = [];

    final periods = mpd.findElements('Period');
    for (final period in periods) {
      var periodBaseUri = currentBaseUri;
      final periodBaseUrl = _findDirectChild(period, 'BaseURL')?.innerText.trim();
      if (periodBaseUrl != null && periodBaseUrl.isNotEmpty) {
        periodBaseUri = periodBaseUri.resolve(periodBaseUrl);
      }

      final adaptationSets = period.findElements('AdaptationSet');
      for (final adaptationSet in adaptationSets) {
        var adaptBaseUri = periodBaseUri;
        final adaptBaseUrl = _findDirectChild(adaptationSet, 'BaseURL')?.innerText.trim();
        if (adaptBaseUrl != null && adaptBaseUrl.isNotEmpty) {
          adaptBaseUri = adaptBaseUri.resolve(adaptBaseUrl);
        }

        final contentType = _determineContentType(adaptationSet);
        final lang = adaptationSet.getAttribute('lang') ??
            adaptationSet.getAttribute('language') ??
            'und';
        final adaptMime = adaptationSet.getAttribute('mimeType');

        final adaptTemplate = _findDirectChild(adaptationSet, 'SegmentTemplate');
        final adaptList = _findDirectChild(adaptationSet, 'SegmentList');

        final representations = adaptationSet.findElements('Representation');
        for (final rep in representations) {
          var repBaseUri = adaptBaseUri;
          final repBaseUrl = _findDirectChild(rep, 'BaseURL')?.innerText.trim();
          if (repBaseUrl != null && repBaseUrl.isNotEmpty) {
            repBaseUri = repBaseUri.resolve(repBaseUrl);
          }

          final id = rep.getAttribute('id') ?? '${contentType}_${rawRepresentations.length}';
          final bandwidth = int.tryParse(rep.getAttribute('bandwidth') ?? '0') ?? 0;
          final width = int.tryParse(rep.getAttribute('width') ??
              adaptationSet.getAttribute('width') ??
              '');
          final height = int.tryParse(rep.getAttribute('height') ??
              adaptationSet.getAttribute('height') ??
              '');
          final codecs = rep.getAttribute('codecs') ?? adaptationSet.getAttribute('codecs');
          final frameRate = rep.getAttribute('frameRate') ?? adaptationSet.getAttribute('frameRate');
          final audioRate = int.tryParse(rep.getAttribute('audioSamplingRate') ??
              adaptationSet.getAttribute('audioSamplingRate') ??
              '');
          final mimeType = rep.getAttribute('mimeType') ?? adaptMime;

          final repTemplate = _findDirectChild(rep, 'SegmentTemplate') ?? adaptTemplate;
          final repList = _findDirectChild(rep, 'SegmentList') ?? adaptList;

          final dashRep = DashRepresentation(
            id: id,
            contentType: contentType,
            bandwidth: bandwidth,
            width: width,
            height: height,
            codecs: codecs,
            frameRate: frameRate,
            audioSamplingRate: audioRate,
            language: lang,
            mimeType: mimeType,
            effectiveBaseUri: repBaseUri,
            representationElement: rep,
            adaptationSetElement: adaptationSet,
            periodElement: period,
            segmentTemplate: repTemplate,
            segmentList: repList,
          );

          rawRepresentations.add(dashRep);

          // DRM'd media can't be decrypted by us, so don't offer it as a stream
          final isProtected = _findDirectChild(adaptationSet, 'ContentProtection') != null ||
              _findDirectChild(rep, 'ContentProtection') != null;
          if (isProtected) continue;

          // the ref is what identifies the actual track.
          final ref = DashRef(manifestUrl, id);
          if (contentType == 'video') {
            qualityStreams.add(QualityStream(
              quality: dashRep.qualityString,
              url: manifestUrl,
              resolution: dashRep.resolutionString,
              bandwidth: bandwidth > 0 ? bandwidth : null,
              audioGroup: adaptationSet.getAttribute('group') ?? 'audio',
              ref: ref,
            ));
          } else if (contentType == 'audio') {
            final channels = adaptationSet.getAttribute('audioChannelConfiguration') ?? '2';
            audioStreams.add(AudioStream(
              groupId: adaptationSet.getAttribute('group') ?? 'audio',
              name: lang == 'und' ? 'Audio ($id)' : lang.toUpperCase(),
              url: manifestUrl,
              language: lang,
              channels: channels,
              bandwidth: bandwidth > 0 ? bandwidth : null,
              ref: ref,
            ));
          } else if (contentType == 'text') {
            subtitleStreams.add(DashSubtitleStream(
              language: lang,
              url: repBaseUri.toString(),
              format: mimeType ?? 'text/vtt',
              name: lang.toUpperCase(),
            ));
          }
        }
      }
    }

    return DashManifest(
      qualityStreams: qualityStreams,
      audioStreams: audioStreams,
      subtitleStreams: subtitleStreams,
      duration: manifestDuration,
      isLive: isLive,
      representations: rawRepresentations,
      manifestUrl: manifestUrl,
    );
  }

  /// Parses and returns the list of downloadable media segments for a given [DashRepresentation]
  static Future<List<DashSegment>> parseSegments(
    DashRepresentation representation, {
    Duration? overrideDuration,
    Map<String, String>? customHeaders,
  }) async {
    final template = representation.segmentTemplate;
    final segmentList = representation.segmentList;
    final baseUri = representation.effectiveBaseUri;

    // Case 1: SegmentTemplate defined
    if (template != null) {
      return _parseTemplateSegments(
        representation: representation,
        template: template,
        baseUri: baseUri,
        duration: overrideDuration,
        headers: customHeaders,
      );
    }

    // Case 2: SegmentList defined
    if (segmentList != null) {
      return _parseSegmentList(
        segmentList: segmentList,
        baseUri: baseUri,
        headers: customHeaders,
      );
    }

    // Case 3: Single file (BaseURL) representation
    return [
      DashSegment(
        url: baseUri.toString(),
        duration: overrideDuration != null ? overrideDuration.inMilliseconds / 1000 : 0.0,
        sequenceNumber: 1,
        headers: customHeaders,
      ),
    ];
  }

  static List<DashSegment> _parseTemplateSegments({
    required DashRepresentation representation,
    required XmlElement template,
    required Uri baseUri,
    Duration? duration,
    Map<String, String>? headers,
  }) {
    final List<DashSegment> segments = [];

    final mediaTemplate = template.getAttribute('media') ?? '';
    final initTemplate = template.getAttribute('initialization');
    final timescale = int.tryParse(template.getAttribute('timescale') ?? '1') ?? 1;
    final startNumber = int.tryParse(template.getAttribute('startNumber') ?? '1') ?? 1;

    // 1. Add Initialization segment if specified
    if (initTemplate != null && initTemplate.isNotEmpty) {
      final initUrlString = _formatTemplate(
        initTemplate,
        representationId: representation.id,
        bandwidth: representation.bandwidth,
      );
      segments.add(DashSegment(
        url: baseUri.resolve(initUrlString).toString(),
        duration: 0.0,
        sequenceNumber: 0,
        isInitSegment: true,
        headers: headers,
      ));
    }

    // 2. Check for SegmentTimeline
    final timeline = _findDirectChild(template, 'SegmentTimeline');
    if (timeline != null) {
      int currentTime = 0;
      int currentSeq = startNumber;

      final sElements = timeline.findElements('S').toList();
      for (int sIdx = 0; sIdx < sElements.length; sIdx++) {
        final s = sElements[sIdx];
        final tAttr = s.getAttribute('t');
        if (tAttr != null) {
          currentTime = int.tryParse(tAttr) ?? currentTime;
        }

        final d = int.tryParse(s.getAttribute('d') ?? '0') ?? 0;
        if (d <= 0) continue;

        int r = int.tryParse(s.getAttribute('r') ?? '0') ?? 0;

        // DASH standard: r < 0 (e.g. r="-1") means repeat until next <S> or presentation end
        if (r < 0) {
          if (sIdx + 1 < sElements.length) {
            final nextT = int.tryParse(sElements[sIdx + 1].getAttribute('t') ?? '');
            if (nextT != null && nextT > currentTime) {
              r = ((nextT - currentTime) ~/ d) - 1;
            } else {
              r = 0;
            }
          } else if (duration != null) {
            final totalUnits = (duration.inMicroseconds * timescale) ~/ 1000000;
            if (totalUnits > currentTime) {
              r = ((totalUnits - currentTime) ~/ d) - 1;
            } else {
              r = 0;
            }
          } else {
            r = 0;
          }
          if (r < 0) r = 0;
        }

        for (int repIndex = 0; repIndex <= r; repIndex++) {
          final segDuration = d / timescale;
          final formattedMedia = _formatTemplate(
            mediaTemplate,
            representationId: representation.id,
            bandwidth: representation.bandwidth,
            number: currentSeq,
            time: currentTime,
          );

          segments.add(DashSegment(
            url: baseUri.resolve(formattedMedia).toString(),
            duration: segDuration,
            sequenceNumber: currentSeq,
            headers: headers,
          ));

          currentTime += d;
          currentSeq++;
        }
      }
      return segments;
    }

    // 3. Simple duration-based segment template
    final durationAttr = template.getAttribute('duration');
    if (durationAttr != null && duration != null) {
      final segDurationUnits = int.tryParse(durationAttr) ?? timescale;
      final segmentDurationSec = segDurationUnits / timescale;
      final totalSeconds = duration.inMilliseconds / 1000;
      final totalSegments = (totalSeconds / segmentDurationSec).ceil();

      for (int i = 0; i < totalSegments; i++) {
        final seq = startNumber + i;
        final timeOffset = i * segDurationUnits;
        final formattedMedia = _formatTemplate(
          mediaTemplate,
          representationId: representation.id,
          bandwidth: representation.bandwidth,
          number: seq,
          time: timeOffset,
        );

        segments.add(DashSegment(
          url: baseUri.resolve(formattedMedia).toString(),
          duration: segmentDurationSec,
          sequenceNumber: seq,
          headers: headers,
        ));
      }
    }

    return segments;
  }

  static List<DashSegment> _parseSegmentList({
    required XmlElement segmentList,
    required Uri baseUri,
    Map<String, String>? headers,
  }) {
    final List<DashSegment> segments = [];
    final timescale = int.tryParse(segmentList.getAttribute('timescale') ?? '1') ?? 1;
    final durationUnits = int.tryParse(segmentList.getAttribute('duration') ?? '0') ?? 0;
    final segmentDuration = durationUnits > 0 ? durationUnits / timescale : 0.0;

    // Initialization segment
    final init = _findDirectChild(segmentList, 'Initialization');
    if (init != null) {
      final sourceUrl = init.getAttribute('sourceURL');
      final range = init.getAttribute('range');
      final targetUri = sourceUrl != null ? baseUri.resolve(sourceUrl) : baseUri;

      segments.add(DashSegment(
        url: targetUri.toString(),
        duration: 0.0,
        sequenceNumber: 0,
        isInitSegment: true,
        byteRange: range,
        headers: headers,
      ));
    }

    // Segment URLs
    final segmentUrls = segmentList.findElements('SegmentURL');
    int seq = 1;
    for (final seg in segmentUrls) {
      final media = seg.getAttribute('media');
      final mediaRange = seg.getAttribute('mediaRange');
      final targetUri = media != null ? baseUri.resolve(media) : baseUri;

      segments.add(DashSegment(
        url: targetUri.toString(),
        duration: segmentDuration,
        sequenceNumber: seq++,
        byteRange: mediaRange,
        headers: headers,
      ));
    }

    return segments;
  }

  /// Replaces DASH identifier variables ($RepresentationID$, $Number$, $Time$, $Bandwidth$)
  static String _formatTemplate(
    String template, {
    String? representationId,
    int? number,
    int? time,
    int? bandwidth,
  }) {
    return template.replaceAllMapped(
      RegExp(r'\$(RepresentationID|Bandwidth|Number(?:%0(\d+)d)?|Time(?:%0(\d+)d)?|\$)\$'),
      (match) {
        final token = match.group(0)!;
        if (token == r'$$') return r'$';
        if (token == r'$RepresentationID$') return representationId ?? '';
        if (token == r'$Bandwidth$') return (bandwidth ?? 0).toString();

        final full = match.group(1)!;
        if (full.startsWith('Number')) {
          final width = match.group(2) != null ? int.tryParse(match.group(2)!) : null;
          final val = number ?? 1;
          return width != null ? val.toString().padLeft(width, '0') : val.toString();
        }
        if (full.startsWith('Time')) {
          final width = match.group(3) != null ? int.tryParse(match.group(3)!) : null;
          final val = time ?? 0;
          return width != null ? val.toString().padLeft(width, '0') : val.toString();
        }
        return token;
      },
    );
  }

  /// Parses ISO-8601 duration string (e.g. PT1H23M45.67S)
  static Duration? _parseIsoDuration(String? isoString) {
    if (isoString == null || isoString.isEmpty) return null;
    final regex = RegExp(
      r'^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?)?$',
    );
    final match = regex.firstMatch(isoString);
    if (match == null) return null;

    final days = int.tryParse(match.group(3) ?? '') ?? 0;
    final hours = int.tryParse(match.group(4) ?? '') ?? 0;
    final minutes = int.tryParse(match.group(5) ?? '') ?? 0;
    final secondsDouble = double.tryParse(match.group(6) ?? '') ?? 0.0;
    final milliseconds = (secondsDouble * 1000).toInt();

    return Duration(
      days: days,
      hours: hours,
      minutes: minutes,
      milliseconds: milliseconds,
    );
  }

  static String _determineContentType(XmlElement adaptationSet) {
    final explicit = adaptationSet.getAttribute('contentType')?.toLowerCase();
    if (explicit != null && explicit.isNotEmpty) return explicit;

    final mime = adaptationSet.getAttribute('mimeType')?.toLowerCase() ?? '';
    if (mime.startsWith('video/')) return 'video';
    if (mime.startsWith('audio/')) return 'audio';
    if (mime.startsWith('text/') || mime.contains('vtt') || mime.contains('ttml')) return 'text';

    return 'video';
  }

  static XmlElement? _findDirectChild(XmlElement parent, String name) {
    return parent.children
        .whereType<XmlElement>()
        .where((e) => e.name.local == name)
        .firstOrNull;
  }
}

