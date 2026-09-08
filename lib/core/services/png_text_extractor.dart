import 'dart:convert';
import 'dart:typed_data';

class PngTextChunk {
  final String keyword;
  final String text;
  PngTextChunk({required this.keyword, required this.text});
}

List<PngTextChunk> extractPngTextChunks(Uint8List pngBytes) {
  final chunks = <PngTextChunk>[];
  final data = ByteData.sublistView(pngBytes);

  if (pngBytes.length < 8) return chunks;

  final signature = Uint8List.sublistView(pngBytes, 0, 8);
  final validSig = <int>[137, 80, 78, 71, 13, 10, 26, 10];
  bool isPng = true;
  for (int i = 0; i < 8; i++) {
    if (signature[i] != validSig[i]) {
      isPng = false;
      break;
    }
  }
  if (!isPng) return chunks;

  int offset = 8;
  while (offset < pngBytes.length - 4) {
    final length = data.getUint32(offset, Endian.big);
    offset += 4;

    if (offset + 4 > pngBytes.length) break;
    final typeBytes = Uint8List.sublistView(pngBytes, offset, offset + 4);
    final type = String.fromCharCodes(typeBytes);
    offset += 4;

    if (offset + length > pngBytes.length) break;
    final chunkData = Uint8List.sublistView(pngBytes, offset, offset + length);
    offset += length;

    offset += 4; // CRC

    if (type == 'tEXt') {
      int nullIndex = -1;
      for (int i = 0; i < chunkData.length; i++) {
        if (chunkData[i] == 0) {
          nullIndex = i;
          break;
        }
      }
      if (nullIndex != -1 && nullIndex + 1 < chunkData.length) {
        final keyword = String.fromCharCodes(
            Uint8List.sublistView(chunkData, 0, nullIndex));
        final textBytes =
            Uint8List.sublistView(chunkData, nullIndex + 1);
        final base64Text = String.fromCharCodes(textBytes);
        try {
          final decoded = base64Decode(base64Text);
          final text = utf8.decode(decoded);
          chunks.add(PngTextChunk(keyword: keyword, text: text));
        } catch (_) {}
      }
    }

    if (type == 'IEND') break;
  }

  return chunks;
}

Map<String, dynamic>? extractCharacterDataFromPng(Uint8List pngBytes) {
  final chunks = extractPngTextChunks(pngBytes);
  for (final chunk in chunks) {
    if (chunk.keyword == 'ccv3' || chunk.keyword == 'chara') {
      try {
        return jsonDecode(chunk.text) as Map<String, dynamic>;
      } catch (_) {}
    }
  }
  return null;
}
