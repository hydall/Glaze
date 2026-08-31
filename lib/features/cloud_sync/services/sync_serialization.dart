import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/memory_book.dart';
import '../../../core/constants/image_gen_patterns.dart';
import '../../../features/extensions/models/info_block.dart';
import '../../../features/image_gen/services/image_tag_markup.dart';
import '../cloud_adapter.dart';
import '../sync_models.dart';

class SyncSerialization {
  static const pipelineSettingsKey = 'pipelineSettings';
  static const activeStudioPresetKey = 'activeStudioPresetId';
  static const globalRegexScriptsKey = 'gz_global_regex_scripts';
  static const studioRegexScriptsKey = 'gz_studio_regex_scripts';
  static const appSettingsKey = 'appSettings';

  /// Content fingerprint for manifest conflict detection (not full session JSON).
  static String computeChatMetadataHash(SessionMetadata metadata) {
    return computeSyncHash({
      'sessionId': metadata.sessionId,
      'characterId': metadata.characterId,
      'sessionIndex': metadata.sessionIndex,
      'updatedAt': metadata.updatedAt,
      'messageCount': metadata.messageCount,
      'lastMessageContent': metadata.lastMessageContent,
      'lastMessageTimestamp': metadata.lastMessageTimestamp,
      'sessionName': metadata.sessionName,
    });
  }

  static String computeSyncHash(dynamic data) {
    final json = jsonEncode(data);
    return sha256.convert(utf8.encode(json)).toString();
  }

  static String computeStudioConfigHash(Map<String, dynamic> json) {
    final content = Map<String, dynamic>.from(json)
      ..remove('createdAt')
      ..remove('updatedAt');
    return computeSyncHash(content);
  }

  /// Device-local / derived fields excluded so parity does not false-conflict.
  static const _memoryBookSettingsHashKeys = {
    'enabled',
    'autoCreateEnabled',
    'autoGenerateEnabled',
    'maxInjectedEntries',
    'memoryExcerptingEnabled',
    'maxInjectionBudgetPercent',
    'maxInjectedTokens',
    'memoryBudgetPreset',
    'autoCreateInterval',
    'autoCreateLagMessages',
    'useDelayedAutomation',
    'injectionTarget',
    'batchSize',
    'vectorSearchEnabled',
    'keyMatchMode',
    'promptPreset',
  };

  static Map<String, dynamic> normalizeMemoryBookForHash(
    Map<String, dynamic> json,
  ) {
    final settings = json['settings'];
    return {
      'sessionId': json['sessionId'],
      'entries': json['entries'] ?? <dynamic>[],
      'settings': _memoryBookSettingsForHash(settings),
    };
  }

  static Map<String, dynamic> _memoryBookSettingsForHash(dynamic settings) {
    if (settings is! Map) return {};
    try {
      final canonical = MemoryBookSettings.fromJson(
        Map<String, dynamic>.from(settings),
      ).toJson();
      return {
        for (final key in _memoryBookSettingsHashKeys)
          if (canonical.containsKey(key)) key: canonical[key],
      };
    } catch (_) {
      return {};
    }
  }

  static String computeMemoryBookHash(Map<String, dynamic> json) {
    try {
      final canonical = MemoryBook.fromJson(json).toJson();
      return computeSyncHash(normalizeMemoryBookForHash(canonical));
    } catch (_) {
      return computeSyncHash(normalizeMemoryBookForHash(json));
    }
  }

  static String computeApiPresetsHash(Iterable<Map<String, dynamic>> items) {
    return computeSyncHash(
      items.map((item) {
        final copy = Map<String, dynamic>.from(item);
        copy['apiKey'] = '';
        copy['embeddingApiKey'] = '';
        return copy;
      }).toList(),
    );
  }

  static Map<String, dynamic> infoBlocksPayload(List<InfoBlock> blocks) {
    return {
      '__infoBlocks': true,
      'items': blocks.map(normalizeInfoBlockForSync).toList(),
    };
  }

  /// Normalizes an InfoBlock for cloud storage:
  /// - imageGen blocks: replaces [IMG:RESULT:/path|json] with [IMG:GEN:json]
  ///   so images can be regenerated on pull without storing device-local paths.
  /// - All other block types: stored as-is.
  static Map<String, dynamic> normalizeInfoBlockForSync(InfoBlock block) {
    final json = block.toJson();
    if (block.blockType != 'imageGen') return json;
    final normalized = Map<String, dynamic>.from(json);
    normalized['content'] = normalizeImageGenContent(block.content);
    return normalized;
  }

  /// Replaces [IMG:RESULT:/abs/path|json] → [IMG:GEN:json]
  /// and [IMG:ERROR:...] → [IMG:GEN] so that pulled blocks can be regenerated.
  ///
  /// The stored `<img data-iig-…>` form of a finished block goes the same way:
  /// the image file itself never leaves the device, so what is uploaded is the
  /// instruction that can produce it again.
  static String normalizeImageGenContent(String content) {
    var result = content;
    // Right to left, so replacing one element leaves the spans of the rest.
    for (final element in ImageTagMarkup.scanResultElements(result).reversed) {
      final instruction = element.payload.instruction;
      result = result.replaceRange(
        element.start,
        element.end,
        instruction.isEmpty ? '[IMG:GEN]' : '[IMG:GEN:$instruction]',
      );
    }
    result = result.replaceAllMapped(ImgGenPatterns.imgResultRegex, (m) {
      final payload = m.group(1) ?? '';
      final pipeIdx = payload.indexOf('|');
      if (pipeIdx >= 0) {
        final instruction = payload.substring(pipeIdx + 1);
        return '[IMG:GEN:$instruction]';
      }
      return '[IMG:GEN]';
    });
    result = result.replaceAll(ImgGenPatterns.imgErrorStripRegex, '[IMG:GEN]');
    return result;
  }

  static String computeBinaryHash(List<int> bytes) {
    return sha256.convert(bytes).toString();
  }

  static String computeImageHash(String dataUrl) {
    final commaIdx = dataUrl.indexOf(',');
    final raw = commaIdx >= 0 ? dataUrl.substring(commaIdx + 1) : dataUrl;
    final bytes = base64Decode(raw);
    return computeBinaryHash(bytes);
  }

  static Map<String, dynamic> localStoragePayload({
    String? pipelineSettings,
    String? activeStudioPresetId,
    String? globalRegexScripts,
    String? studioRegexScripts,
    Map<String, dynamic>? appSettings,
  }) {
    return {
      '__localStorage': true,
      pipelineSettingsKey: ?pipelineSettings,
      activeStudioPresetKey: ?activeStudioPresetId,
      globalRegexScriptsKey: ?globalRegexScripts,
      studioRegexScriptsKey: ?studioRegexScripts,
      appSettingsKey: ?appSettings,
    };
  }

  static String guessImageExt(String dataUrl) {
    final mimeMatch = RegExp(r'data:([^;]+);').firstMatch(dataUrl);
    if (mimeMatch == null) return 'png';
    final mime = mimeMatch[1]!;
    if (mime.contains('jpeg') || mime.contains('jpg')) return 'jpg';
    if (mime.contains('gif')) return 'gif';
    if (mime.contains('webp')) return 'webp';
    return 'png';
  }

  static Future<void> deleteCloudFileIfExists(
    CloudAdapter adapter,
    SyncManifestEntry entry,
  ) async {
    try {
      await adapter.deleteFile(entry.path);
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> readCloudEntity(
    CloudAdapter adapter,
    SyncManifestEntry entry,
  ) async {
    try {
      final raw = await adapter.download(entry.path);
      if (raw.isEmpty) return null;
      if (raw.length > maxSyncPayloadBytes) {
        throw Exception(
          'Payload exceeds ${maxSyncPayloadBytes ~/ 1024 ~/ 1024}MB limit',
        );
      }
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> readRequiredCloudEntity(
    CloudAdapter adapter,
    SyncManifestEntry entry,
  ) async {
    final raw = await adapter.download(entry.path);
    if (raw.isEmpty) {
      throw StateError('Empty cloud entity: ${entry.key}');
    }
    if (raw.length > maxSyncPayloadBytes) {
      throw Exception(
        'Payload exceeds ${maxSyncPayloadBytes ~/ 1024 ~/ 1024}MB limit',
      );
    }
    return jsonDecode(raw) as Map<String, dynamic>;
  }
}
