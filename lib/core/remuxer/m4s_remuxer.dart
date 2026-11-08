import 'dart:typed_data';

import 'base_remuxer.dart';
import 'm4s_demuxer.dart';
import 'mkv_muxer.dart';

/// A high-level class that orchestrates the conversion of fragmented MP4 (.m4s) chunks into an MKV file.
class M4sToMkvRemuxer extends BaseMkvRemuxer {
  final M4sDemuxer _videoDemuxer = M4sDemuxer();
  final M4sDemuxer _audioDemuxer = M4sDemuxer();

  M4sToMkvRemuxer(
    super.outputPath, {
    super.hasSeparateAudio,
    super.audioLanguage,
    super.audioTrackName,
  });

  /// Feed video initialization segment bytes (`init.mp4`).
  Future<void> processVideoInit(Uint8List initBytes) async {
    _videoDemuxer.parseInitSegment(initBytes);
    await _checkOpenMuxer();
  }

  /// Feed audio initialization segment bytes (`init.mp4`).
  Future<void> processAudioInit(Uint8List initBytes) async {
    _audioDemuxer.parseInitSegment(initBytes);
    await _checkOpenMuxer();
  }

  @override
  Future<void> processVideoChunk(Uint8List videoBytes) async {
    if (videoBytes.isEmpty) return;

    final samples = _videoDemuxer.process(videoBytes);

    for (final sample in samples) {
      if (sample.isVideo) {
        int uPts = videoPtsUnwrapper.unwrap(sample.pts);
        int uDts = videoDtsUnwrapper.unwrap(sample.dts);
        queueBlock(1, sample.data, uPts, uDts, sample.isKeyframe);
      } else if (!hasSeparateAudio) {
        int uPts = audioPtsUnwrapper.unwrap(sample.pts);
        int uDts = audioDtsUnwrapper.unwrap(sample.dts);
        queueBlock(2, sample.data, uPts, uDts, true);
      }
    }

    await _checkOpenMuxer();

    if (muxerOpened && queue.length > 200) {
      flushQueue();
    }
  }

  @override
  Future<void> processAudioChunk(Uint8List audioBytes) async {
    if (audioBytes.isEmpty) return;

    final samples = _audioDemuxer.process(audioBytes);

    for (final sample in samples) {
      int uPts = audioPtsUnwrapper.unwrap(sample.pts);
      int uDts = audioDtsUnwrapper.unwrap(sample.dts);
      queueBlock(2, sample.data, uPts, uDts, true);
    }

    await _checkOpenMuxer();

    if (muxerOpened && queue.length > 200) {
      flushQueue();
    }
  }

  Future<void> _checkOpenMuxer() async {
    if (muxerOpened) return;

    final videoTrack = _videoDemuxer.videoTrack;
    final audioTrack = hasSeparateAudio
        ? _audioDemuxer.audioTrack
        : (_videoDemuxer.audioTrack ?? _audioDemuxer.audioTrack);

    final canOpen = videoTrack != null && (!hasSeparateAudio || audioTrack != null);

    if (canOpen) {
      // Without the decoder config the muxer would silently drop the video TrackEntry
      // while still writing its blocks, producing an audio-only file.
      if (videoTrack.codecPrivate == null) {
        throw Exception("fMP4 init segment has no avcC/hvcC for video track (codec: ${videoTrack.codec})");
      }
      if (audioTrack != null && audioTrack.codecPrivate == null) {
        throw Exception("fMP4 init segment has no AudioSpecificConfig for audio track (codec: ${audioTrack.codec})");
      }

      final audioTracks = <MkvAudioTrack>[];
      if (audioTrack != null) {
        audioTracks.add(
          MkvAudioTrack(
            trackNumber: 2,
            codecPrivate: audioTrack.codecPrivate,
            sampleRate: audioTrack.sampleRate ?? 44100.0,
            channels: audioTrack.channels ?? 2,
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
        avcc: videoTrack.codecPrivate,
        videoCodecId: videoTrack.isHevc ? 'V_MPEGH/ISO/HEVC' : 'V_MPEG4/ISO/AVC',
        audioTracks: audioTracks,
        subtitleTracks: subtitleTracks,
        width: videoTrack.width ?? 1920,
        height: videoTrack.height ?? 1080,
        fps: 0.0,
      );
      muxerOpened = true;
    }
  }

  @override
  Future<void> close() async {
    if (!muxerOpened) {
      final videoTrack = _videoDemuxer.videoTrack;
      final audioTrack = hasSeparateAudio
          ? _audioDemuxer.audioTrack
          : (_videoDemuxer.audioTrack ?? _audioDemuxer.audioTrack);

      final audioTracks = <MkvAudioTrack>[];
      if (audioTrack != null) {
        audioTracks.add(
          MkvAudioTrack(
            trackNumber: 2,
            codecPrivate: audioTrack.codecPrivate,
            sampleRate: audioTrack.sampleRate ?? 44100.0,
            channels: audioTrack.channels ?? 2,
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
        avcc: videoTrack?.codecPrivate,
        videoCodecId: (videoTrack?.isHevc ?? false) ? 'V_MPEGH/ISO/HEVC' : 'V_MPEG4/ISO/AVC',
        audioTracks: audioTracks,
        subtitleTracks: subtitleTracks,
        width: videoTrack?.width ?? 1920,
        height: videoTrack?.height ?? 1080,
        fps: 0.0,
      );
      muxerOpened = true;
    }

    await finalizeMuxer();
  }
}
