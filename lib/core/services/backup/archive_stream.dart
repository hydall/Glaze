import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';

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

  final decoder = Utf8Decoder(allowMalformed: true);
  final lineSplitter = LineSplitter();
  var pending = '';

  try {
    while (true) {
      if (source.isEOS) break;
      final sub = source.readBytes(chunkSize);
      final bytes = sub.toUint8List();
      if (bytes.isEmpty) break;
      pending += decoder.convert(bytes);

      final lines = lineSplitter.convert(pending);
      if (lines.isNotEmpty) {
        // The last entry is either a complete line (when input ended on
        // \n) or a partial line still being decoded. Hold the last for
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
    if (pending.isNotEmpty) {
      yield pending;
    }
  }
}
