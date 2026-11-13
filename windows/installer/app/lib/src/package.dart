import 'dart:io';
import 'dart:typed_data';

/// The footer the launcher writes at the end of GlazeSetup.exe — see
/// `Footer` in windows/installer/launcher/launcher.cpp, whose layout this
/// follows byte for byte.
class PackageFooter {
  static const size = 64;
  static const _magic = 'GLZSETUP';
  static const _version = 1;

  final int method;
  final int uiOffset;
  final int uiSize;
  final int uiRawSize;
  final int payloadOffset;
  final int payloadSize;

  const PackageFooter({
    required this.method,
    required this.uiOffset,
    required this.uiSize,
    required this.uiRawSize,
    required this.payloadOffset,
    required this.payloadSize,
  });

  /// The footer of [bytes] (the file's last [size] bytes), or null.
  static PackageFooter? parse(Uint8List bytes) {
    if (bytes.length != size) return null;
    if (String.fromCharCodes(bytes.sublist(0, 8)) != _magic) return null;
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(8, Endian.little) != _version) return null;
    return PackageFooter(
      method: data.getUint32(12, Endian.little),
      uiOffset: data.getUint64(16, Endian.little),
      uiSize: data.getUint64(24, Endian.little),
      uiRawSize: data.getUint64(32, Endian.little),
      payloadOffset: data.getUint64(40, Endian.little),
      payloadSize: data.getUint64(48, Endian.little),
    );
  }

  Uint8List toBytes() {
    final bytes = Uint8List(size);
    bytes.setAll(0, _magic.codeUnits);
    ByteData.sublistView(bytes)
      ..setUint32(8, _version, Endian.little)
      ..setUint32(12, method, Endian.little)
      ..setUint64(16, uiOffset, Endian.little)
      ..setUint64(24, uiSize, Endian.little)
      ..setUint64(32, uiRawSize, Endian.little)
      ..setUint64(40, payloadOffset, Endian.little)
      ..setUint64(48, payloadSize, Endian.little);
    return bytes;
  }

  static Future<PackageFooter?> read(File file) async {
    final raf = await file.open();
    try {
      final length = await raf.length();
      if (length < size) return null;
      await raf.setPosition(length - size);
      return parse(await raf.read(size));
    } finally {
      await raf.close();
    }
  }
}

/// Writes the setup without the Glaze build it carries: the launcher and the
/// setup window, about a third of the file. Kept in the install folder as the
/// uninstaller the Apps entry runs.
Future<void> writeUninstaller(File package, File target) async {
  final footer = await PackageFooter.read(package);
  if (footer == null) {
    throw const FormatException('the setup file has no footer');
  }
  await target.parent.create(recursive: true);
  final partial = File('${target.path}.part');
  final input = await package.open();
  final output = await partial.open(mode: FileMode.write);
  try {
    var left = footer.payloadOffset;
    while (left > 0) {
      final chunk = await input.read(left < 1 << 20 ? left : 1 << 20);
      if (chunk.isEmpty) throw const FormatException('the setup file is short');
      await output.writeFrom(chunk);
      left -= chunk.length;
    }
    await output.writeFrom(
      PackageFooter(
        method: footer.method,
        uiOffset: footer.uiOffset,
        uiSize: footer.uiSize,
        uiRawSize: footer.uiRawSize,
        payloadOffset: footer.payloadOffset,
        payloadSize: 0,
      ).toBytes(),
    );
  } finally {
    await input.close();
    await output.close();
  }
  if (await target.exists()) await target.delete();
  await partial.rename(target.path);
}
