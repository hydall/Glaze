import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/memory_book.dart';
import '../../../features/extensions/models/info_block.dart';
import '../../../features/image_gen/services/image_tag_markup.dart';
import '../../chat/composer_empty_action_provider.dart';
import '../../chat/composer_pins_provider.dart';
import '../../chat/hidden_composer_actions_provider.dart';
import '../../chat/quick_replies_provider.dart';
import '../../chat/services/magic_drawer_layout_service.dart';
import '../../tools/tools_layout_service.dart';
import '../cloud_adapter.dart';
import '../sync_models.dart';

class SyncSerialization {
  static const pipelineSettingsKey = 'pipelineSettings';
  static const activeStudioPresetKey = 'activeStudioPresetId';
  static const globalRegexScriptsKey = 'gz_global_regex_scripts';
  static const studioRegexScriptsKey = 'gz_studio_regex_scripts';
  static const appSettingsKey = 'appSettings';
  static const chatLayoutKey = 'chatLayout';
  static const includeApiKeysPrefKey = 'gz_sync_include_api_keys';

  /// Preferences that make up the chat layout the user arranges by hand: the
  /// buttons under the composer, the quick replies, and the order of the chat
  /// drawer and the Tools screen. Each holds either a string or a string list.
  static const chatLayoutPrefKeys = [
    ComposerPinsNotifier.storageKey,
    ComposerPinsNotifier.legacyStorageKey,
    HiddenComposerActionsNotifier.storageKey,
    ComposerEmptyActionNotifier.storageKey,
    QuickRepliesNotifier.storageKey,
    MagicDrawerLayoutService.itemsKey,
    MagicDrawerLayoutService.deletedItemsKey,
    ToolsLayoutService.orderKey,
    ToolsLayoutService.sizesKey,
    ToolsLayoutService.deletedKey,
  ];

  /// Whether the user asked for API keys to travel with the sync. Read from
  /// preferences rather than passed around so every push — manual, automatic
  /// or the one after a conflict — honours the same switch.
  static bool includeApiKeys(SharedPreferences prefs) =>
      prefs.get(includeApiKeysPrefKey) == true;

  /// The stored chat layout, or null when the user never changed any of it.
  /// Null keeps the local_storage hash of an untouched install as it was.
  static Map<String, dynamic>? readChatLayout(SharedPreferences prefs) {
    final out = <String, dynamic>{};
    for (final key in chatLayoutPrefKeys) {
      final value = prefs.get(key);
      if (value is String) {
        out[key] = value;
      } else if (value is List) {
        out[key] = value.cast<String>().toList();
      }
    }
    return out.isEmpty ? null : out;
  }

  /// Writes a pulled chat layout. A key the source device does not have is
  /// removed here too, so a reset on one device resets the other.
  static Future<void> applyChatLayout(
    SharedPreferences prefs,
    Map<String, dynamic> layout,
  ) async {
    for (final key in chatLayoutPrefKeys) {
      final value = layout[key];
      if (value is String) {
        await prefs.setString(key, value);
      } else if (value is List) {
        await prefs.setStringList(key, value.map((e) => '$e').toList());
      } else {
        await prefs.remove(key);
      }
    }
  }

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

  /// Normalizes an InfoBlock for cloud storage: a finished image is replaced
  /// by the instruction that produced it, so the block can be regenerated on
  /// pull and no device-local path ever leaves the device. A block holding no
  /// image is stored as-is.
  ///
  /// The test is the content, not the block's type. It used to be
  /// `blockType == 'imageGen'`, which was safe only while images could come
  /// from nothing else; now that any generated block can draw one, that check
  /// would upload the file paths of every block the old image type did not
  /// cover.
  static Map<String, dynamic> normalizeInfoBlockForSync(InfoBlock block) {
    final json = block.toJson();
    final normalized = normalizeImageGenContent(block.content);
    if (normalized == block.content) return json;
    return Map<String, dynamic>.from(json)..['content'] = normalized;
  }

  /// Replaces [IMG:RESULT:/abs/path|json] → [IMG:GEN:json]
  /// and [IMG:ERROR:...] → [IMG:GEN] so that pulled blocks can be regenerated.
  ///
  /// The stored `<img data-iig-…>` form of a finished block goes the same way:
  /// the image file itself never leaves the device, so what is uploaded is the
  /// instruction that can produce it again.
  static String normalizeImageGenContent(String content) =>
      ImageTagMarkup.reduceBlocksToInstructions(content);

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
    Map<String, dynamic>? chatLayout,
  }) {
    return {
      '__localStorage': true,
      pipelineSettingsKey: ?pipelineSettings,
      activeStudioPresetKey: ?activeStudioPresetId,
      globalRegexScriptsKey: ?globalRegexScripts,
      studioRegexScriptsKey: ?studioRegexScripts,
      appSettingsKey: ?appSettings,
      chatLayoutKey: ?chatLayout,
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
