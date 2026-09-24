import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';

/// Collects decoded strings from a chunked UTF-8 conversion.
class _BufferSink implements Sink<String> {
  final StringBuffer buffer;

  _BufferSink(this.buffer);

  @override
  void add(String data) => buffer.write(data);

  @override
  void close() {}
}

/// Streamed read of an [ArchiveFile] as lines (JSONL-friendly).
///
/// [ArchiveFile.readBytes] decompresses the entire entry into memory, which
/// is fine for small files (avatars, lorebook JSON) but blows up for large
/// chat JSONL files. This helper iterates the underlying [InputStream] in
/// fixed-size chunks, decoding UTF-8 incrementally and emitting one line
/// at a time.
///
/// Backpressure: only one chunk + the current decoded buffer are in
/// memory at any given moment, so even a multi-GB chat file won't OOM.
Stream<String> readArchiveFileLines(
  ArchiveFile file, {
  int chunkSize = 64 * 1024, // 64 KB
}) async* {
  final source = file.getContent();
  if (source == null) return;
  source.reset();

  // A persistent chunked conversion keeps multi-byte characters that straddle
  // a chunk boundary (Cyrillic, CJK, emoji) intact. A fresh `convert` per
  // chunk would replace both halves with U+FFFD.
  final buffer = StringBuffer();
  final conversion = const Utf8Decoder(
    allowMalformed: true,
  ).startChunkedConversion(_BufferSink(buffer));
  final lineSplitter = LineSplitter();
  var pending = '';

  try {
    while (true) {
      if (source.isEOS) break;
      final sub = source.readBytes(chunkSize);
      final bytes = sub.toUint8List();
      if (bytes.isEmpty) break;

      buffer.clear();
      conversion.add(bytes);
      pending += buffer.toString();

      // `LineSplitter` strips line terminators, so a chunk that ends exactly
      // on a newline must be treated as complete — otherwise the last line is
      // held back and silently concatenated with the next chunk's first line.
      final endsWithTerminator =
          pending.endsWith('\n') || pending.endsWith('\r');
      final lines = lineSplitter.convert(pending);
      if (endsWithTerminator) {
        for (final line in lines) {
          if (line.isNotEmpty) yield line;
        }
        pending = '';
      } else if (lines.isNotEmpty) {
        // The last entry is a partial line still being decoded. Hold it for
        // the next chunk.
        pending = lines.removeLast();
        for (final line in lines) {
          if (line.isNotEmpty) yield line;
        }
      }
      // Yield occasionally so cancellation propagates.
      await Future<void>.delayed(Duration.zero);
    }
  } finally {
    buffer.clear();
    conversion.close();
    pending += buffer.toString();
    if (pending.isNotEmpty) {
      yield pending;
    }
  }
}
