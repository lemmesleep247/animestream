import 'dart:typed_data';

import 'package:animestream/core/commons/streams/mediaSegment.dart';
import 'package:encrypt/encrypt.dart';
import 'package:http/http.dart' as http;

class HlsEncryptionKey {
  final String method;
  final String uri;
  final String? iv;

  HlsEncryptionKey({required this.method, required this.uri, required this.iv});

  // Cached per URI, not per instance: many playlists repeat the same #EXT-X-KEY line before every segment
  // (sometimes with a different IV), which creates a new instance each time. Lives as long as the isolate.
  static final Map<String, Future<Uint8List>> _bytesByUri = {};

  Future<Uint8List> fetch({Map<String, String> headers = const {}}) {
    return _bytesByUri[uri] ??= _load(headers).catchError((Object e) {
      _bytesByUri.remove(uri); // let the next segment retry
      throw e;
    });
  }

  Future<Uint8List> _load(Map<String, String> headers) async {
    final res = await http.get(Uri.parse(uri), headers: headers);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception("Failed to fetch encryption key from $uri. Status code: ${res.statusCode}");
    }
    return res.bodyBytes;
  }
}

class HlsSegment implements MediaSegment {
  @override
  final String url;
  final double duration;
  final int sequenceNumber;
  final HlsEncryptionKey? encryptionKey;

  /// `#EXT-X-MAP` init segment (fMP4 HLS)
  @override
  final bool isInit;

  HlsSegment({
    required this.url,
    required this.duration,
    required this.sequenceNumber,
    required this.encryptionKey,
    this.isInit = false,
  });

  @override
  String? get byteRange => null;

  @override
  Future<Uint8List> prepare(Uint8List raw, {Map<String, String> headers = const {}}) async {
    final key = encryptionKey;
    if (key == null) return raw;
    if (key.method != "AES-128") {
      throw UnsupportedError("HLS encryption method '${key.method}' isn't supported");
    }

    final keyBytes = await key.fetch(headers: headers);
    final decrypted = Encrypter(AES(Key(keyBytes), mode: AESMode.cbc)).decryptBytes(Encrypted(raw), iv: IV(_iv(key)));
    return Uint8List.fromList(decrypted);
  }

  Uint8List _iv(HlsEncryptionKey key) {
    if (key.iv != null) {
      // Explicit IV as hex, e.g. "0x00000000000000000000000000000001"
      final hex = key.iv!.replaceFirst(RegExp('^0[xX]'), '').padLeft(32, '0');
      return Uint8List.fromList(List.generate(16, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)));
    }
    // Default: 16-byte big-endian media sequence number
    final iv = Uint8List(16);
    ByteData.view(iv.buffer).setUint64(8, sequenceNumber, Endian.big);
    return iv;
  }
}
