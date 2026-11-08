import 'package:animestream/core/commons/streams/streamRef.dart';

class AudioStream {
  final String language;
  final String url;
  final String name;
  final String channels;
  final String groupId;
  final int? bandwidth;

  final StreamRef? _ref;

  /// Where this track's segments come from. Defaults to treating [url] as a HLS media playlist.
  StreamRef get ref => _ref ?? HlsRef(url);

  const AudioStream({
    required this.groupId,
    required this.name,
    required this.url,
    required this.language,
    required this.channels,
    this.bandwidth,
    StreamRef? ref,
  }) : _ref = ref;

  factory AudioStream.placeholder() {
    return AudioStream(
      groupId: "who cares",
      name: "mic testing!",
      url: "placeholder",
      language: "gibberish",
      channels: "stereo",
    );
  }

  bool get isEnglish {
    final l = language.trim().toLowerCase();
    if (l == 'en' || l == 'eng' || l == 'english' || l.startsWith('en-') || l.startsWith('en_')) {
      return true;
    }
    return RegExp(r'\b(en|eng|english|dub)\b', caseSensitive: false).hasMatch(name);
  }

  @override
  String toString() {
    return 'AudioStream(language: $language, url: $url, name: $name, channels: $channels, groupId: $groupId, ref: $ref)';
  }
}

class AudioStreamBuilder {
  String? language;
  String? url;
  String? name;
  String? channels;
  String? groupId;

  AudioStream build() {
    if (language == null || url == null || name == null || channels == null || groupId == null) {
      throw Exception("One of the required arguments for the AudioStream was received as null");
    }
    return AudioStream(groupId: groupId!, name: name!, url: url!, language: language!, channels: channels!);
  }

  void addGroupId(String groupId) => this.groupId = groupId;

  void addChannels(String channels) => this.channels = channels;

  void addName(String name) => this.name = name;

  void addUrl(String url) => this.url = url;

  void addLanguage(String language) => this.language = language;
}
