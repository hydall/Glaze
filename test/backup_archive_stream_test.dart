import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/backup/archive_stream.dart';

ArchiveFile _entry(String content) =>
    ArchiveFile.bytes('tables/x.jsonl', utf8.encode(content));

void main() {
  group('readArchiveFileLines', () {
    test('splits plain LF-delimited lines', () async {
      final lines = await readArchiveFileLines(
        _entry('one\ntwo\nthree'),
        chunkSize: 4,
      ).toList();
      expect(lines, ['one', 'two', 'three']);
    });

    test('handles a chunk ending exactly on a newline', () async {
      // Each 8-byte chunk is exactly `aaaaaaa\n`, so the naive reader would
      // hold the last line back and concatenate it with the next chunk.
      final content = '${List.generate(100, (i) => 'aaaaaaa').join('\n')}\n';
      final expected = List.generate(100, (i) => 'aaaaaaa');
      final lines = await readArchiveFileLines(
        _entry(content),
        chunkSize: 8,
      ).toList();
      expect(lines, expected);
    });

    test('preserves multi-byte characters split across chunks', () async {
      // 1 ASCII byte + 12 Cyrillic bytes; 3-byte chunks slice the characters.
      final lines = await readArchiveFileLines(
        _entry('aпривет\nмир'),
        chunkSize: 3,
      ).toList();
      expect(lines, ['aпривет', 'мир']);
    });

    test('handles CRLF and no trailing newline', () async {
      final lines = await readArchiveFileLines(
        _entry('a\r\nb\r\nc'),
        chunkSize: 2,
      ).toList();
      expect(lines, ['a', 'b', 'c']);
    });
  });
}
