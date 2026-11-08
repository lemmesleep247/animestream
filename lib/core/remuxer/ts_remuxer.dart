import 'dart:typed_data';

import 'aac_parser.dart';
import 'base_remuxer.dart';
import 'h264_parser.dart';
import 'mkv_muxer.dart';
import 'ts_demuxer.dart';

/// A high-level class that orchestrates the conversion of MPEG-TS chunks into an MKV file.
class TsToMkvRemuxer extends BaseMkvRemuxer {
  final TsDemuxer _videoDemuxer = TsDemuxer();
  final TsDemuxer _audioDemuxer = TsDemuxer();
  final H264Parser _h264Parser = H264Parser();
  final AacParser _aacParser = AacParser();

  int? _firstVideoPts;
  int? _audioPtsOffset;

  TsToMkvRemuxer(
    super.outputPath, {
    super.hasSeparateAudio,
    super.audioLanguage,
    super.audioTrackName,
  });

  @override
  Future<void> processVideoChunk(Uint8List videoBytes) async {
    final pesPackets = _videoDemuxer.process(videoBytes);

    for (final pes in pesPackets) {
      if (pes.streamType == 0x1B) {
        // H.264
        final frame = _h264Parser.processPes(pes.payload, pes.pts, pes.dts);
        if (frame != null && frame.lengthPrefixedData.isNotEmpty) {
          _firstVideoPts ??= frame.pts;
          int uPts = videoPtsUnwrapper.unwrap(frame.pts);
          int uDts = videoDtsUnwrapper.unwrap(frame.dts);
          queueBlock(1, frame.lengthPrefixedData, uPts, uDts, frame.isKeyframe);
        }
      } else if (pes.streamType == 0x0F && !hasSeparateAudio) {
        // AAC inside video TS (single-stream mode)
        final frames = _aacParser.processPes(pes.payload, pes.pts, pes.dts);
        for (final f in frames) {
          int uPts = audioPtsUnwrapper.unwrap(f.pts);
          int uDts = audioDtsUnwrapper.unwrap(f.dts);
          queueBlock(2, f.data, uPts, uDts, true);
        }
      }

      await _checkOpenMuxer();

      if (muxerOpened && queue.length > 200) {
        flushQueue();
      }
    }
  }

  @override
  Future<void> processAudioChunk(Uint8List audioBytes) async {
    if (audioBytes.isEmpty) return;

    // Detect raw ADTS AAC: syncword 0xFFF (0xFF followed by high 4 bits 1)
    final isRawAac = audioBytes.length > 1 &&
        audioBytes[0] == 0xFF &&
        (audioBytes[1] & 0xF0) == 0xF0;

    if (isRawAac) {
      final frames = _aacParser.processPes(audioBytes, null, null);
      if (_audioPtsOffset == null && _firstVideoPts != null) {
        _audioPtsOffset = _firstVideoPts;
      }
      final offset = _audioPtsOffset ?? 0;

      for (final f in frames) {
        int uPts = audioPtsUnwrapper.unwrap(f.pts + offset);
        int uDts = audioDtsUnwrapper.unwrap(f.dts + offset);
        queueBlock(2, f.data, uPts, uDts, true);
      }
    } else {
      final pesPackets = _audioDemuxer.process(audioBytes);
      for (final pes in pesPackets) {
        if (pes.streamType == 0x0F) {
          final frames = _aacParser.processPes(pes.payload, pes.pts, pes.dts);
          for (final f in frames) {
            int uPts = audioPtsUnwrapper.unwrap(f.pts);
            int uDts = audioDtsUnwrapper.unwrap(f.dts);
            queueBlock(2, f.data, uPts, uDts, true);
          }
        }
      }
    }

    await _checkOpenMuxer();

    if (muxerOpened && queue.length > 200) {
      flushQueue();
    }
  }

  Future<void> _checkOpenMuxer() async {
    if (muxerOpened) return;

    final avcc = _h264Parser.buildAvcc();
    final aacConfig = _aacParser.buildAudioSpecificConfig();

    final canOpen = avcc != null && (!hasSeparateAudio ? (aacConfig != null) : aacConfig != null);

    if (canOpen) {
      final sps = _h264Parser.spsInfo;
      final audioTracks = <MkvAudioTrack>[];
      audioTracks.add(
        MkvAudioTrack(
          trackNumber: 2,
          codecPrivate: aacConfig,
          sampleRate: _aacParser.getSamplingRate(),
          channels: _aacParser.getOutputChannels(),
          language: audioLanguage,
          name: audioTrackName,
          isDefault: true,
        ),
      );

      final subtitleTracks = <MkvSubtitleTrack>[];
      if (subtitleCues.isNotEmpty) {
        subtitleTracks.add(
          MkvSubtitleTrack(
            trackNumber: audioTracks.isNotEmpty ? 3 : 2,
            codecId: subtitleCodecId,
            isDefault: true,
          ),
        );
      }

      await muxer.openWithTracks(
        avcc: avcc,
        audioTracks: audioTracks,
        subtitleTracks: subtitleTracks,
        width: sps?.width ?? 1920,
        height: sps?.height ?? 1080,
        fps: sps?.fps ?? 0.0,
      );
      muxerOpened = true;
    }
  }

  @override
  Future<void> close() async {
    // Flush remaining video frames
    final lastVideo = _h264Parser.processPes(null, null, null);
    if (lastVideo != null && lastVideo.lengthPrefixedData.isNotEmpty) {
      int uPts = videoPtsUnwrapper.unwrap(lastVideo.pts);
      int uDts = videoDtsUnwrapper.unwrap(lastVideo.dts);
      queueBlock(1, lastVideo.lengthPrefixedData, uPts, uDts, lastVideo.isKeyframe);
    }

    // Flush remaining audio frames
    final lastAudio = _aacParser.processPes(null, null, null);
    for (final a in lastAudio) {
      int uPts = audioPtsUnwrapper.unwrap(a.pts);
      int uDts = audioDtsUnwrapper.unwrap(a.dts);
      queueBlock(2, a.data, uPts, uDts, true);
    }

    // Ensure muxer is opened before finishing
    if (!muxerOpened) {
      final avcc = _h264Parser.buildAvcc();
      final aacConfig = _aacParser.buildAudioSpecificConfig();
      final sps = _h264Parser.spsInfo;

      final audioTracks = <MkvAudioTrack>[];
      if (aacConfig != null) {
        audioTracks.add(
          MkvAudioTrack(
            trackNumber: 2,
            codecPrivate: aacConfig,
            sampleRate: _aacParser.getSamplingRate(),
            channels: _aacParser.getOutputChannels(),
            language: audioLanguage,
            name: audioTrackName,
            isDefault: true,
          ),
        );
      }

      final subtitleTracks = <MkvSubtitleTrack>[];
      if (subtitleCues.isNotEmpty) {
        subtitleTracks.add(
          MkvSubtitleTrack(
            trackNumber: audioTracks.isNotEmpty ? 3 : 2,
            codecId: subtitleCodecId,
            isDefault: true,
          ),
        );
      }

      await muxer.openWithTracks(
        avcc: avcc,
        audioTracks: audioTracks,
        subtitleTracks: subtitleTracks,
        width: sps?.width ?? 1920,
        height: sps?.height ?? 1080,
        fps: sps?.fps ?? 0.0,
      );
      muxerOpened = true;
    }

    await finalizeMuxer();
  }
}
