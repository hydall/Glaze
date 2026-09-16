/// Moving blocks and block sets in and out of files.
///
/// Everything here is deliberately free of UI: it picks, parses and writes, and
/// reports what happened. Telling the user is the caller's job, because the
/// same import runs from more than one surface.
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../../../core/services/file_export_service.dart';
import '../../../core/utils/id_generator.dart';
import '../models/block_config.dart';
import '../models/extension_preset.dart';
import 'upstream_block_codec.dart';
import 'upstream_preset_codec.dart';

/// Outcome of reading one or more files.
class BlockImportResult {
  const BlockImportResult({
    required this.blocks,
    required this.unreadable,
    this.cancelled = false,
  });

  const BlockImportResult.cancelled()
    : blocks = const [],
      unreadable = const [],
      cancelled = true;

  /// Blocks read, in file order.
  final List<BlockConfig> blocks;

  /// Names of files that could not be read at all.
  final List<String> unreadable;

  /// The user dismissed the picker. Not an error, and not worth a message.
  final bool cancelled;

  bool get isEmpty => blocks.isEmpty;
}

/// Reads blocks out of one already-decoded JSON document.
///
/// Accepts every shape that turns up in practice: a single block, a bare array
/// of blocks, or a whole set. Blocks written by this app and blocks written by
/// the original extension are told apart per entry, so a file holding a mix of
/// both still reads correctly.
List<BlockConfig> blocksFromJson(Object? decoded, {int startOrder = 0}) {
  final blocks = <BlockConfig>[];

  void addOne(Map<String, dynamic> map) {
    if (looksLikeUpstreamBlock(map)) {
      blocks.add(decodeUpstreamBlock(map, order: startOrder + blocks.length));
      return;
    }
    try {
      final own = BlockConfig.fromJson(map);
      blocks.add(
        own.copyWith(
          id: own.id.isEmpty ? generateId() : own.id,
          order: startOrder + blocks.length,
        ),
      );
    } catch (_) {
      // A map that is neither shape is skipped rather than failing the file:
      // a set may legitimately carry entries this version does not know.
    }
  }

  if (decoded is List) {
    for (final entry in decoded) {
      if (entry is Map) addOne(Map<String, dynamic>.from(entry));
    }
    return blocks;
  }

  if (decoded is! Map) return blocks;
  final map = Map<String, dynamic>.from(decoded);

  if (looksLikeUpstreamPreset(map)) {
    return decodeUpstreamPreset(map).blocks;
  }

  // One of our presets exported whole.
  final ownBlocks = map['blocks'];
  if (ownBlocks is List) {
    for (final entry in ownBlocks) {
      if (entry is Map) addOne(Map<String, dynamic>.from(entry));
    }
    return blocks;
  }

  addOne(map);
  return blocks;
}

class BlockTransferService {
  const BlockTransferService();

  /// Asks for one or more JSON files and reads every block out of them.
  Future<BlockImportResult> importBlocks({int startOrder = 0}) async {
    final files = await _pickJsonFiles();
    if (files == null) return const BlockImportResult.cancelled();

    final blocks = <BlockConfig>[];
    final unreadable = <String>[];

    for (final file in files) {
      final text = await _readFile(file);
      if (text == null) {
        unreadable.add(file.name);
        continue;
      }
      try {
        final found = blocksFromJson(
          jsonDecode(text),
          startOrder: startOrder + blocks.length,
        );
        if (found.isEmpty) {
          unreadable.add(file.name);
        } else {
          blocks.addAll(found);
        }
      } catch (_) {
        unreadable.add(file.name);
      }
    }

    return BlockImportResult(blocks: blocks, unreadable: unreadable);
  }

  /// Asks for one JSON file and reads a whole set out of it.
  ///
  /// A file holding only blocks still works — the blocks are wrapped in a new
  /// set named after the file, which is what someone importing a loose export
  /// expects to happen.
  Future<ExtensionPreset?> importPreset() async {
    final files = await _pickJsonFiles(allowMultiple: false);
    if (files == null || files.isEmpty) return null;

    final file = files.first;
    final text = await _readFile(file);
    if (text == null) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }

    final fallbackName = file.name.replaceAll(RegExp(r'\.json$', caseSensitive: false), '');

    if (decoded is Map && looksLikeUpstreamPreset(Map<String, dynamic>.from(decoded))) {
      return decodeUpstreamPreset(
        Map<String, dynamic>.from(decoded),
        fallbackName: fallbackName,
      );
    }

    final blocks = blocksFromJson(decoded);
    if (blocks.isEmpty) return null;

    final name = decoded is Map ? (decoded['name'] as String? ?? '').trim() : '';

    return ExtensionPreset(
      id: generateId(),
      name: name.isNotEmpty ? name : fallbackName,
      blocks: blocks,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Writes one block out in the original extension's format.
  ///
  /// Returns the saved path, or the empty string when the user dismissed the
  /// save dialog — cancelling is not an error.
  Future<String> exportBlock(BlockConfig block) => FileExportService.export(
    data: _pretty(encodeUpstreamBlock(block)),
    filename: '${_safeFileName(block.name.isEmpty ? 'block' : block.name)}.json',
    subfolder: 'ExtBlocks',
  );

  /// Writes a whole set out in the original extension's format.
  Future<String> exportPreset(ExtensionPreset preset) => FileExportService.export(
    data: _pretty(encodeUpstreamPreset(preset)),
    filename:
        '${_safeFileName(preset.name.isEmpty ? 'extblocks' : preset.name)}.json',
    subfolder: 'ExtBlocks',
  );

  Future<List<PlatformFile>?> _pickJsonFiles({bool allowMultiple = true}) async {
    try {
      final result = await FilePicker.pickFiles(
        // iOS refuses a custom extension filter for JSON, so it gets the
        // unfiltered picker and the parse step catches anything unsuitable.
        type: Platform.isIOS ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isIOS ? null : ['json'],
        allowMultiple: allowMultiple,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return null;
      return result.files;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readFile(PlatformFile file) async {
    try {
      final bytes = file.bytes;
      if (bytes != null) return utf8.decode(bytes);
      final path = file.path;
      if (path == null) return null;
      return await File(path).readAsString();
    } catch (_) {
      return null;
    }
  }

  String _pretty(Map<String, dynamic> json) =>
      const JsonEncoder.withIndent('    ').convert(json);

  /// Block names carry macros and punctuation that no filesystem wants.
  String _safeFileName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    return cleaned.isEmpty ? 'block' : cleaned;
  }
}
