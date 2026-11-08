import 'dart:typed_data';

/// Represents metadata for an audio or video track extracted from the DASH/fMP4 init segment (`moov`).
class M4sTrackInfo {
  final int trackId;
  final bool isVideo;
  final bool isAudio;
  final String codec; // e.g. "avc1", "mp4a", "hvc1", "opus"
  final int timescale;
  final int? width;
  final int? height;
  final int? channels;
  final double? sampleRate;

  /// Codec configuration bytes ready for MKV muxing:
  /// - For H.264 (AVC): the exact `avcC` box payload (SPS/PPS configuration record).
  /// - For AAC: the `AudioSpecificConfig` bytes from `esds`.
  final Uint8List? codecPrivate;

  const M4sTrackInfo({
    required this.trackId,
    required this.isVideo,
    required this.isAudio,
    required this.codec,
    required this.timescale,
    this.width,
    this.height,
    this.channels,
    this.sampleRate,
    this.codecPrivate,
  });

  @override
  String toString() {
    return 'M4sTrackInfo(id: $trackId, codec: $codec, video: $isVideo, timescale: $timescale, '
        'res: ${width}x$height, audio: ${channels}ch@${sampleRate}Hz)';
  }
}

/// A parsed audio or video sample from an `.m4s` media segment (`moof` + `mdat`).
class M4sSample {
  final int trackId;

  /// The raw sample payload:
  /// - For H.264 video: 4-byte length-prefixed NALUs (AVCC format), ready for MKV block writing.
  /// - For AAC audio: raw AAC audio frame.
  final Uint8List data;

  /// Presentation timestamp in standard 90kHz scale (compatible with TsDemuxer and MkvMuxer).
  final int pts;

  /// Decode timestamp in standard 90kHz scale.
  final int dts;

  /// Sample duration in 90kHz scale.
  final int duration;

  /// Whether this sample is a keyframe / IDR sync frame.
  final bool isKeyframe;

  /// Whether this is a video sample (true) or audio sample (false).
  final bool isVideo;

  const M4sSample({
    required this.trackId,
    required this.data,
    required this.pts,
    required this.dts,
    required this.duration,
    required this.isKeyframe,
    required this.isVideo,
  });

  @override
  String toString() {
    return 'M4sSample(track: $trackId, pts: $pts, dts: $dts, len: ${data.length}, key: $isKeyframe, video: $isVideo)';
  }
}

/// Demuxer for fragmented MP4 (fMP4 / `.m4s`) streams used by MPEG-DASH and HLS fMP4.
class M4sDemuxer {
  final Map<int, M4sTrackInfo> _tracks = {};

  /// All tracks discovered from initialization segments (`moov`).
  Map<int, M4sTrackInfo> get tracks => Map.unmodifiable(_tracks);

  /// Primary video track, if present.
  M4sTrackInfo? get videoTrack => _tracks.values.where((t) => t.isVideo).firstOrNull;

  /// Primary audio track, if present.
  M4sTrackInfo? get audioTrack => _tracks.values.where((t) => t.isAudio).firstOrNull;

  /// Parses an initialization segment (`init.mp4` / `init.m4s`) containing the `moov` box.
  ///
  /// Extracts track metadata (dimensions, sample rates, timescales, and `codecPrivate` like `avcC` or `esds`).
  List<M4sTrackInfo> parseInitSegment(Uint8List initBytes) {
    final moovBox = _findBox(initBytes, 0, initBytes.length, 'moov');
    if (moovBox == null) return [];

    final discovered = <M4sTrackInfo>[];
    final trakBoxes = _findAllBoxes(initBytes, moovBox.payloadOffset, moovBox.payloadEnd, 'trak');

    for (final trak in trakBoxes) {
      final info = _parseTrak(initBytes, trak.payloadOffset, trak.payloadEnd);
      if (info != null) {
        _tracks[info.trackId] = info;
        discovered.add(info);
      }
    }

    return discovered;
  }

  /// Processes an `.m4s` media chunk (`moof` + `mdat`) and returns individual media samples.
  ///
  /// Each sample's PTS and DTS are normalized to 90kHz so they can be piped straight into [MkvMuxer].
  List<M4sSample> processChunk(Uint8List chunkBytes) {
    final results = <M4sSample>[];
    int offset = 0;

    while (offset < chunkBytes.length - 8) {
      final moof = _findBox(chunkBytes, offset, chunkBytes.length, 'moof');
      if (moof == null) break;

      final mdat = _findBox(chunkBytes, moof.boxEnd, chunkBytes.length, 'mdat');
      if (mdat == null) break;

      final trafBoxes = _findAllBoxes(chunkBytes, moof.payloadOffset, moof.payloadEnd, 'traf');
      for (final traf in trafBoxes) {
        final samples = _parseTraf(
          bytes: chunkBytes,
          trafStart: traf.payloadOffset,
          trafEnd: traf.payloadEnd,
          moofStart: moof.boxOffset,
          mdatPayloadStart: mdat.payloadOffset,
          mdatPayloadEnd: mdat.payloadEnd,
        );
        results.addAll(samples);
      }

      offset = mdat.boxEnd;
    }

    return results;
  }

  /// Convenience processor that automatically distinguishes between `init` segments and media chunks.
  List<M4sSample> process(Uint8List bytes) {
    if (_findBox(bytes, 0, bytes.length, 'moov') != null) {
      parseInitSegment(bytes);
    }
    if (_findBox(bytes, 0, bytes.length, 'moof') != null) {
      return processChunk(bytes);
    }
    return [];
  }

  M4sTrackInfo? _parseTrak(Uint8List bytes, int start, int end) {
    final tkhd = _findBox(bytes, start, end, 'tkhd');
    final mdia = _findBox(bytes, start, end, 'mdia');
    if (mdia == null) return null;

    int trackId = 1;
    int? width;
    int? height;

    if (tkhd != null) {
      final bd = ByteData.sublistView(bytes, tkhd.payloadOffset, tkhd.payloadEnd);
      final version = bd.getUint8(0);
      trackId = version == 1 ? bd.getUint32(20) : bd.getUint32(12);

      // Width & height are 16.16 fixed point numbers at the end of tkhd
      final widthOffset = version == 1 ? 84 : 72;
      if (widthOffset + 8 <= tkhd.payloadLength) {
        width = bd.getUint32(widthOffset) >> 16;
        height = bd.getUint32(widthOffset + 4) >> 16;
      }
    }

    final hdlr = _findBox(bytes, mdia.payloadOffset, mdia.payloadEnd, 'hdlr');
    final mdhd = _findBox(bytes, mdia.payloadOffset, mdia.payloadEnd, 'mdhd');
    final minf = _findBox(bytes, mdia.payloadOffset, mdia.payloadEnd, 'minf');

    String handlerType = 'vide';
    if (hdlr != null && hdlr.payloadLength >= 12) {
      handlerType = String.fromCharCodes(bytes.sublist(hdlr.payloadOffset + 8, hdlr.payloadOffset + 12));
    }

    final isVideo = handlerType == 'vide';
    final isAudio = handlerType == 'soun';

    int timescale = 90000;
    if (mdhd != null && mdhd.payloadLength >= 16) {
      final bd = ByteData.sublistView(bytes, mdhd.payloadOffset, mdhd.payloadEnd);
      final version = bd.getUint8(0);
      timescale = version == 1 ? bd.getUint32(20) : bd.getUint32(12);
    }

    String codec = isVideo ? 'avc1' : 'mp4a';
    Uint8List? codecPrivate;
    int? channels;
    double? sampleRate;

    if (minf != null) {
      final stbl = _findBox(bytes, minf.payloadOffset, minf.payloadEnd, 'stbl');
      if (stbl != null) {
        final stsd = _findBox(bytes, stbl.payloadOffset, stbl.payloadEnd, 'stsd');
        if (stsd != null && stsd.payloadLength >= 8) {
          // stsd payload has: 4 bytes version/flags + 4 bytes entry count, then sample entry boxes
          final entriesStart = stsd.payloadOffset + 8;
          final sampleEntry = _findAnyBox(bytes, entriesStart, stsd.payloadEnd);

          if (sampleEntry != null) {
            codec = sampleEntry.type;

            if (isVideo) {
              // avc1 / hvc1 sample entry
              if (sampleEntry.payloadLength >= 32) {
                final bd = ByteData.sublistView(bytes, sampleEntry.payloadOffset, sampleEntry.payloadEnd);
                width = bd.getUint16(24);
                height = bd.getUint16(26);
              }

              // Extract avcC / hvcC configuration record
              final avcC = _findBox(bytes, sampleEntry.payloadOffset, sampleEntry.payloadEnd, 'avcC');
              if (avcC != null) {
                codecPrivate = bytes.sublist(avcC.payloadOffset, avcC.payloadEnd);
              } else {
                final hvcC = _findBox(bytes, sampleEntry.payloadOffset, sampleEntry.payloadEnd, 'hvcC');
                if (hvcC != null) {
                  codecPrivate = bytes.sublist(hvcC.payloadOffset, hvcC.payloadEnd);
                }
              }
            } else if (isAudio) {
              // mp4a sample entry
              if (sampleEntry.payloadLength >= 28) {
                final bd = ByteData.sublistView(bytes, sampleEntry.payloadOffset, sampleEntry.payloadEnd);
                channels = bd.getUint16(16);
                sampleRate = (bd.getUint32(22) >> 16).toDouble();
              }

              // Extract AudioSpecificConfig from esds box
              final esds = _findBox(bytes, sampleEntry.payloadOffset, sampleEntry.payloadEnd, 'esds');
              if (esds != null) {
                codecPrivate = _extractAudioSpecificConfigFromEsds(
                  bytes.sublist(esds.payloadOffset, esds.payloadEnd),
                );
              }
            }
          }
        }
      }
    }

    return M4sTrackInfo(
      trackId: trackId,
      isVideo: isVideo,
      isAudio: isAudio,
      codec: codec,
      timescale: timescale,
      width: width,
      height: height,
      channels: channels,
      sampleRate: sampleRate,
      codecPrivate: codecPrivate,
    );
  }

  List<M4sSample> _parseTraf({
    required Uint8List bytes,
    required int trafStart,
    required int trafEnd,
    required int moofStart,
    required int mdatPayloadStart,
    required int mdatPayloadEnd,
  }) {
    final tfhd = _findBox(bytes, trafStart, trafEnd, 'tfhd');
    if (tfhd == null || tfhd.payloadLength < 4) return [];

    final bdTfhd = ByteData.sublistView(bytes, tfhd.payloadOffset, tfhd.payloadEnd);
    final tfhdFlags = bdTfhd.getUint32(0) & 0x00FFFFFF;
    final trackId = bdTfhd.getUint32(4);

    int tfhdCursor = 8;
    int? baseDataOffset;
    int? defaultSampleDuration;
    int? defaultSampleSize;
    int? defaultSampleFlags;

    if ((tfhdFlags & 0x000001) != 0 && tfhdCursor + 8 <= tfhd.payloadLength) {
      baseDataOffset = bdTfhd.getUint64(tfhdCursor);
      tfhdCursor += 8;
    }
    if ((tfhdFlags & 0x000002) != 0) tfhdCursor += 4; // skip sample_description_index
    if ((tfhdFlags & 0x000008) != 0 && tfhdCursor + 4 <= tfhd.payloadLength) {
      defaultSampleDuration = bdTfhd.getUint32(tfhdCursor);
      tfhdCursor += 4;
    }
    if ((tfhdFlags & 0x000010) != 0 && tfhdCursor + 4 <= tfhd.payloadLength) {
      defaultSampleSize = bdTfhd.getUint32(tfhdCursor);
      tfhdCursor += 4;
    }
    if ((tfhdFlags & 0x000020) != 0 && tfhdCursor + 4 <= tfhd.payloadLength) {
      defaultSampleFlags = bdTfhd.getUint32(tfhdCursor);
      tfhdCursor += 4;
    }

    // Read tfdt baseMediaDecodeTime
    int baseDecodeTime = 0;
    final tfdt = _findBox(bytes, trafStart, trafEnd, 'tfdt');
    if (tfdt != null && tfdt.payloadLength >= 4) {
      final bdTfdt = ByteData.sublistView(bytes, tfdt.payloadOffset, tfdt.payloadEnd);
      final version = bdTfdt.getUint8(0);
      baseDecodeTime = version == 1 ? bdTfdt.getUint64(4) : bdTfdt.getUint32(4);
    }

    final trackInfo = _tracks[trackId];
    final timescale = trackInfo?.timescale ?? 90000;
    final isVideo = trackInfo?.isVideo ?? true;

    final results = <M4sSample>[];
    final trunBoxes = _findAllBoxes(bytes, trafStart, trafEnd, 'trun');
    int currentDts = baseDecodeTime;

    for (final trun in trunBoxes) {
      if (trun.payloadLength < 8) continue;
      final bdTrun = ByteData.sublistView(bytes, trun.payloadOffset, trun.payloadEnd);

      final version = bdTrun.getUint8(0);
      final trunFlags = bdTrun.getUint32(0) & 0x00FFFFFF;
      final sampleCount = bdTrun.getUint32(4);

      int trunCursor = 8;
      int dataOffset = 0;
      int? firstSampleFlags;

      if ((trunFlags & 0x000001) != 0 && trunCursor + 4 <= trun.payloadLength) {
        dataOffset = bdTrun.getInt32(trunCursor);
        trunCursor += 4;
      }
      if ((trunFlags & 0x000004) != 0 && trunCursor + 4 <= trun.payloadLength) {
        firstSampleFlags = bdTrun.getUint32(trunCursor);
        trunCursor += 4;
      }

      // Calculate where sample payload data starts
      int sampleDataOffset;
      if ((trunFlags & 0x000001) != 0) {
        sampleDataOffset = (baseDataOffset ?? moofStart) + dataOffset;
      } else {
        sampleDataOffset = mdatPayloadStart;
      }

      for (int i = 0; i < sampleCount; i++) {
        int duration = defaultSampleDuration ?? 0;
        int size = defaultSampleSize ?? 0;
        int flags = (i == 0 && firstSampleFlags != null) ? firstSampleFlags : (defaultSampleFlags ?? 0);
        int compositionTimeOffset = 0;

        if ((trunFlags & 0x000100) != 0 && trunCursor + 4 <= trun.payloadLength) {
          duration = bdTrun.getUint32(trunCursor);
          trunCursor += 4;
        }
        if ((trunFlags & 0x000200) != 0 && trunCursor + 4 <= trun.payloadLength) {
          size = bdTrun.getUint32(trunCursor);
          trunCursor += 4;
        }
        if ((trunFlags & 0x000400) != 0 && trunCursor + 4 <= trun.payloadLength) {
          flags = bdTrun.getUint32(trunCursor);
          trunCursor += 4;
        }
        if ((trunFlags & 0x000800) != 0 && trunCursor + 4 <= trun.payloadLength) {
          compositionTimeOffset = version == 0 ? bdTrun.getUint32(trunCursor) : bdTrun.getInt32(trunCursor);
          trunCursor += 4;
        }

        if (sampleDataOffset + size <= bytes.length && sampleDataOffset >= 0) {
          final samplePayload = bytes.sublist(sampleDataOffset, sampleDataOffset + size);

          // Keyframe determination:
          // 1. In audio, all samples are keyframes.
          // 2. In video, sample_is_non_sync_sample flag (0x00010000) == 0 means keyframe.
          // 3. Fallback: inspect first NALU header for IDR slice (type 5).
          bool isKeyframe = !isVideo;
          if (isVideo) {
            if ((flags & 0x00010000) == 0 && flags != 0) {
              isKeyframe = true;
            } else if (samplePayload.length > 4) {
              // Read NAL unit type (AVCC length prefix is 4 bytes)
              final nalType = samplePayload[4] & 0x1F;
              if (nalType == 5 || nalType == 7) {
                isKeyframe = true;
              }
            }
          }

          // Scale timestamps to standard 90kHz
          final pts90k = ((currentDts + compositionTimeOffset) * 90000) ~/ timescale;
          final dts90k = (currentDts * 90000) ~/ timescale;
          final duration90k = (duration * 90000) ~/ timescale;

          results.add(M4sSample(
            trackId: trackId,
            data: samplePayload,
            pts: pts90k,
            dts: dts90k,
            duration: duration90k,
            isKeyframe: isKeyframe,
            isVideo: isVideo,
          ));

          sampleDataOffset += size;
        }

        currentDts += duration;
      }
    }

    return results;
  }

  /// Parses MPEG-4 elementary stream descriptor (`esds`) to locate the `AudioSpecificConfig`.
  static Uint8List? _extractAudioSpecificConfigFromEsds(Uint8List esdsData) {
    if (esdsData.length < 5) return null;
    int offset = 4; // Skip version (1) + flags (3)

    int readTagLength() {
      int len = 0;
      for (int i = 0; i < 4; i++) {
        if (offset >= esdsData.length) break;
        final b = esdsData[offset++];
        len = (len << 7) | (b & 0x7F);
        if ((b & 0x80) == 0) break;
      }
      return len;
    }

    while (offset < esdsData.length - 2) {
      final tag = esdsData[offset++];
      final length = readTagLength();

      if (tag == 0x03) {
        // ES_Descriptor
        offset += 3; // skip ES_ID (2) + streamPriority (1)
      } else if (tag == 0x04) {
        // DecoderConfigDescriptor
        offset += 13; // skip objectType (1) + streamType (1) + bufferSize (3) + bitrates (8)
      } else if (tag == 0x05) {
        // DecoderSpecificInfo contains the exact AudioSpecificConfig
        if (offset + length <= esdsData.length) {
          return esdsData.sublist(offset, offset + length);
        }
        break;
      } else {
        offset += length;
      }
    }

    return null;
  }

  // --- Low-level ISOBMFF Box Scanning Utilities ---

  static _BoxRef? _findBox(Uint8List bytes, int start, int end, String targetType) {
    int offset = start;
    while (offset + 8 <= end && offset + 8 <= bytes.length) {
      final bd = ByteData.sublistView(bytes, offset, offset + 8);
      int size = bd.getUint32(0);
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));

      int headerSize = 8;
      if (size == 1 && offset + 16 <= end && offset + 16 <= bytes.length) {
        size = ByteData.sublistView(bytes, offset + 8, offset + 16).getUint64(0);
        headerSize = 16;
      } else if (size == 0) {
        size = end - offset;
      }

      if (size < headerSize) break;

      if (type == targetType) {
        return _BoxRef(
          type: type,
          boxOffset: offset,
          headerSize: headerSize,
          boxLength: size,
        );
      }

      offset += size;
    }
    return null;
  }

  static _BoxRef? _findAnyBox(Uint8List bytes, int start, int end) {
    if (start + 8 > end || start + 8 > bytes.length) return null;
    final bd = ByteData.sublistView(bytes, start, start + 8);
    int size = bd.getUint32(0);
    final type = String.fromCharCodes(bytes.sublist(start + 4, start + 8));

    int headerSize = 8;
    if (size == 1 && start + 16 <= end) {
      size = ByteData.sublistView(bytes, start + 8, start + 16).getUint64(0);
      headerSize = 16;
    } else if (size == 0) {
      size = end - start;
    }

    if (size < headerSize) return null;

    return _BoxRef(
      type: type,
      boxOffset: start,
      headerSize: headerSize,
      boxLength: size,
    );
  }

  static List<_BoxRef> _findAllBoxes(Uint8List bytes, int start, int end, String targetType) {
    final list = <_BoxRef>[];
    int offset = start;

    while (offset + 8 <= end && offset + 8 <= bytes.length) {
      final bd = ByteData.sublistView(bytes, offset, offset + 8);
      int size = bd.getUint32(0);
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));

      int headerSize = 8;
      if (size == 1 && offset + 16 <= end && offset + 16 <= bytes.length) {
        size = ByteData.sublistView(bytes, offset + 8, offset + 16).getUint64(0);
        headerSize = 16;
      } else if (size == 0) {
        size = end - offset;
      }

      if (size < headerSize) break;

      if (type == targetType) {
        list.add(_BoxRef(
          type: type,
          boxOffset: offset,
          headerSize: headerSize,
          boxLength: size,
        ));
      }

      offset += size;
    }

    return list;
  }
}

class _BoxRef {
  final String type;
  final int boxOffset;
  final int headerSize;
  final int boxLength;

  _BoxRef({
    required this.type,
    required this.boxOffset,
    required this.headerSize,
    required this.boxLength,
  });

  int get payloadOffset => boxOffset + headerSize;
  int get boxEnd => boxOffset + boxLength;
  int get payloadEnd => boxOffset + boxLength;
  int get payloadLength => boxLength - headerSize;
}

