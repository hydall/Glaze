import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// One file in a zip, as its central directory describes it.
class ZipEntry {
  final String name;
  final int method;
  final int compressedSize;
  final int size;
  final int crc32;
  final int localHeaderOffset;

  const ZipEntry({
    required this.name,
    required this.method,
    required this.compressedSize,
    required this.size,
    required this.crc32,
    required this.localHeaderOffset,
  });

  bool get isDirectory => name.endsWith('/');
}

/// Reads the zip CI makes of the Glaze build (`ZipFile.CreateFromDirectory`):
/// stored and deflated entries, Zip64 sizes included. Inflating goes through
/// dart:io's zlib, which is native, so a hundred megabytes take seconds.
class ZipReader {
  final File file;

  ZipReader(this.file);

  Future<List<ZipEntry>> entries() async {
    final raf = await file.open();
    try {
      final length = await raf.length();
      // The end-of-central-directory record sits in the last 64 KiB + 22.
      final tailLength = length < 65557 ? length : 65557;
      await raf.setPosition(length - tailLength);
      final tail = await raf.read(tailLength);
      final view = ByteData.sublistView(tail);
      var eocd = -1;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (view.getUint32(i, Endian.little) == 0x06054b50) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) throw const FormatException('not a zip file');
      var count = view.getUint16(eocd + 10, Endian.little);
      var dirSize = view.getUint32(eocd + 12, Endian.little);
      var dirOffset = view.getUint32(eocd + 16, Endian.little);

      // Zip64: the record before it points at the real numbers.
      if (eocd >= 20 &&
          view.getUint32(eocd - 20, Endian.little) == 0x07064b50) {
        final recordOffset = view.getUint64(eocd - 12, Endian.little);
        await raf.setPosition(recordOffset);
        final record = ByteData.sublistView(await raf.read(56));
        if (record.getUint32(0, Endian.little) != 0x06064b50) {
          throw const FormatException('broken Zip64 record');
        }
        count = record.getUint64(32, Endian.little);
        dirSize = record.getUint64(40, Endian.little);
        dirOffset = record.getUint64(48, Endian.little);
      }

      await raf.setPosition(dirOffset);
      final dir = await raf.read(dirSize);
      final d = ByteData.sublistView(dir);
      final result = <ZipEntry>[];
      var at = 0;
      for (var i = 0; i < count; i++) {
        if (d.getUint32(at, Endian.little) != 0x02014b50) {
          throw const FormatException('broken central directory');
        }
        final flags = d.getUint16(at + 8, Endian.little);
        final method = d.getUint16(at + 10, Endian.little);
        final crc = d.getUint32(at + 16, Endian.little);
        var compressed = d.getUint32(at + 20, Endian.little);
        var size = d.getUint32(at + 24, Endian.little);
        final nameLength = d.getUint16(at + 28, Endian.little);
        final extraLength = d.getUint16(at + 30, Endian.little);
        final commentLength = d.getUint16(at + 32, Endian.little);
        var offset = d.getUint32(at + 42, Endian.little);
        final nameBytes = dir.sublist(at + 46, at + 46 + nameLength);
        // Bit 11: UTF-8 names. .NET sets it whenever a name needs it.
        final name = (flags & 0x800) != 0
            ? utf8.decode(nameBytes)
            : latin1.decode(nameBytes);

        var extra = at + 46 + nameLength;
        final extraEnd = extra + extraLength;
        while (extra + 4 <= extraEnd) {
          final id = d.getUint16(extra, Endian.little);
          final length = d.getUint16(extra + 2, Endian.little);
          if (id == 0x0001) {
            var field = extra + 4;
            if (size == 0xFFFFFFFF) {
              size = d.getUint64(field, Endian.little);
              field += 8;
            }
            if (compressed == 0xFFFFFFFF) {
              compressed = d.getUint64(field, Endian.little);
              field += 8;
            }
            if (offset == 0xFFFFFFFF) {
              offset = d.getUint64(field, Endian.little);
            }
          }
          extra += 4 + length;
        }

        result.add(
          ZipEntry(
            name: name.replaceAll(r'\', '/'),
            method: method,
            compressedSize: compressed,
            size: size,
            crc32: crc,
            localHeaderOffset: offset,
          ),
        );
        at = extraEnd + commentLength;
      }
      return result;
    } finally {
      await raf.close();
    }
  }

  /// Writes [entry] to [target], reporting every chunk's unpacked bytes.
  Future<void> extract(
    ZipEntry entry,
    File target, {
    void Function(int bytes)? onBytes,
  }) async {
    if (entry.method != 0 && entry.method != 8) {
      throw FormatException(
        '${entry.name}: unsupported method ${entry.method}',
      );
    }
    final raf = await file.open();
    final partial = File('${target.path}.glzpart');
    await target.parent.create(recursive: true);
    final out = await partial.open(mode: FileMode.write);
    try {
      await raf.setPosition(entry.localHeaderOffset);
      final header = ByteData.sublistView(await raf.read(30));
      if (header.getUint32(0, Endian.little) != 0x04034b50) {
        throw FormatException('${entry.name}: broken local header');
      }
      await raf.setPosition(
        entry.localHeaderOffset +
            30 +
            header.getUint16(26, Endian.little) +
            header.getUint16(28, Endian.little),
      );

      final inflate = entry.method == 8
          ? RawZLibFilter.inflateFilter(raw: true)
          : null;
      final crc = _Crc32();
      var written = 0;
      var left = entry.compressedSize;
      Future<void> emit(List<int> data) async {
        if (data.isEmpty) return;
        crc.add(data);
        await out.writeFrom(data);
        written += data.length;
        onBytes?.call(data.length);
      }

      while (left > 0) {
        final chunk = await raf.read(left < 1 << 18 ? left : 1 << 18);
        if (chunk.isEmpty) throw FormatException('${entry.name}: truncated');
        left -= chunk.length;
        if (inflate == null) {
          await emit(chunk);
          continue;
        }
        inflate.process(chunk, 0, chunk.length);
        for (List<int>? piece; (piece = inflate.processed()) != null;) {
          await emit(piece!);
        }
      }
      if (inflate != null) {
        inflate.process(const [], 0, 0);
        for (
          List<int>? piece;
          (piece = inflate.processed(flush: true, end: true)) != null;
        ) {
          await emit(piece!);
        }
      }
      if (written != entry.size || crc.value != entry.crc32) {
        throw FormatException('${entry.name}: damaged in the setup file');
      }
    } catch (_) {
      await out.close();
      if (await partial.exists()) await partial.delete();
      rethrow;
    } finally {
      await raf.close();
    }
    await out.close();
    if (await target.exists()) await target.delete();
    await partial.rename(target.path);
  }
}

/// Where [name] lands under [root], or null when it would land outside it.
String? safeTarget(String root, String name) {
  final target = p.normalize(p.join(root, name));
  return p.isWithin(root, target) ? target : null;
}

class _Crc32 {
  static final _table = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  int _crc = 0xFFFFFFFF;

  void add(List<int> data) {
    var c = _crc;
    for (final b in data) {
      c = _table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    _crc = c;
  }

  int get value => _crc ^ 0xFFFFFFFF;
}
