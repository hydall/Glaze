import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../db/app_db.dart';
import '../image_storage_service.dart';
import 'backup_helpers.dart';
import 'profile_resolver.dart';
import 'service_prefs_writer.dart';

class JsApiConfigImporter extends BackupHelpers {
  @override
  final AppDatabase db;
  @override
  final ImageStorageService imageStorage;

  JsApiConfigImporter(this.db, this.imageStorage);

  Future<void> importApiConfigs(Map<String, dynamic> kv,
      Map<String, dynamic> ls,
      [Map<String, dynamic>? topLevel]) async {
    final profilesRaw = ls['gz_provider_profiles'];
    Map<String, dynamic>? serviceProfileMap;
    for (final src in [ls, kv]) {
      final spmRaw = src['gz_service_profile_map'];
      if (spmRaw is String) {
        try {
          serviceProfileMap = jsonDecode(spmRaw) as Map<String, dynamic>;
          break;
        } catch (_) {}
      } else if (spmRaw is Map<String, dynamic>) {
        serviceProfileMap = spmRaw;
        break;
      }
    }

    Map<String, dynamic>? connPreset;
    final connPresetsRaw = kv['gz_api_connection_presets'];
    if (connPresetsRaw != null) {
      final presets = <Map<String, dynamic>>[];
      extractPresetsFromRaw(connPresetsRaw, presets);
      if (presets.isNotEmpty) connPreset = presets.first;
    }

    if (profilesRaw != null) {
      final allProfiles = <Map<String, dynamic>>[];
      extractPresetsFromRaw(profilesRaw, allProfiles);

      final activeLlmId = ls['gz_active_llm_profile_id'] as String? ??
          kv['gz_active_llm_profile_id'] as String?;
      final resolved = resolveProfiles(allProfiles, serviceProfileMap, activeLlmId);

      final imggenApiKeys = <String>{};
      for (final k in [
        'gz_imggen_api_key',
        'gz_imggen_routmy_api_key',
        'gz_imggen_naistera_api_key',
      ]) {
        final v = ls[k] as String?;
        if (v != null && v.isNotEmpty) imggenApiKeys.add(v);
      }

      final seenIds = <String>{};
      for (final p in allProfiles) {
        final pid = p['id'] as String? ?? '';
        if (seenIds.contains(pid)) continue;
        seenIds.add(pid);

        if (resolved.skipIds.contains(pid)) continue;
        final pMode = p['mode'] as String?;
        if (pMode == 'embedding' || pMode == 'image_gen' || pMode == 'memory_books') continue;
        if (pid != resolved.llmProfileId) {
          final ep = (p['endpoint'] as String?) ?? '';
          final ak = (p['apiKey'] as String?) ?? (p['key'] as String?) ?? '';
          final mdl = (p['model'] as String?) ?? '';
          if (ep.isEmpty && mdl.isEmpty) continue;
          if (ep.isEmpty && imggenApiKeys.contains(ak)) continue;
          if (resolved.embedding.profile != null) {
            final embEp = (resolved.embedding.profile!['endpoint'] as String?) ?? '';
            final embMdl = (resolved.embedding.profile!['model'] as String?) ?? '';
            final isEmbDuplicate = (ep.isNotEmpty && embEp.isNotEmpty && ep == embEp) &&
                (mdl.isNotEmpty && embMdl.isNotEmpty && mdl == embMdl);
            if (isEmbDuplicate) continue;
          }
          if (resolved.embedding.useSameAsLlm && ep.isNotEmpty) {
            final embEndpoint = ls['gz_embedding_endpoint'] as String? ??
                kv['gz_embedding_endpoint'] as String? ?? '';
            final embModel = ls['gz_embedding_model'] as String? ??
                kv['gz_embedding_model'] as String? ?? '';
            final isEmbDuplicate = (ep == embEndpoint) && (mdl == embModel);
            if (isEmbDuplicate) continue;
          }
        }

        String embEndpoint = '';
        String embApiKey = '';
        String embModel = '';
        bool embSame = resolved.embedding.useSameAsLlm;
        bool embEnabled = false;
        int embMaxChunk = 512;

        if (resolved.embedding.profile != null &&
            pid == resolved.llmProfileId &&
            !resolved.embedding.useSameAsLlm) {
          embEndpoint = resolved.embedding.profile!['endpoint'] as String? ?? '';
          embApiKey = resolved.embedding.profile!['apiKey'] as String? ??
              resolved.embedding.profile!['key'] as String? ??
              '';
          embModel = resolved.embedding.profile!['model'] as String? ?? '';
          embSame = false;
          embEnabled = true;
        } else if (resolved.embedding.useSameAsLlm && pid == resolved.llmProfileId) {
          embSame = true;
          embEnabled = true;
        }

        final merged = <String, dynamic>{};
        for (final e in p.entries) {
          if (e.value != null && e.value != '') {
            merged[e.key] = e.value;
          }
        }
        if (pid == resolved.llmProfileId && connPreset != null) {
          merged.addAll(connPreset);
          if (connPreset['key'] != null && connPreset['apiKey'] == null) {
            merged['apiKey'] = connPreset['key'];
          }
          merged.remove('key');
        } else {
          merged['max_tokens'] = ls['api-max-tokens'] ?? kv['api-max-tokens'] ?? merged['max_tokens'];
          merged['context'] = ls['api-context'] ?? kv['api-context'] ?? merged['context'];
          merged['temp'] = ls['gz_api_temp'] ?? kv['gz_api_temp'] ?? merged['temp'];
          merged['topp'] = ls['gz_api_topp'] ?? kv['gz_api_topp'] ?? merged['topp'];
        }

        await insertApiConfig(merged, 'chat',
            embeddingUseSame: embSame,
            embeddingEnabled: embEnabled,
            embeddingEndpoint: embEndpoint,
            embeddingApiKey: embApiKey,
            embeddingModel: embModel,
            embeddingMaxChunkTokens: embMaxChunk);
      }

      await writeImgGenPrefs(resolved.imageGen.profile, resolved.imageGen.useSameAsLlm);
      await writeMemoryBooksPrefs(resolved.memoryBooks.profile, resolved.memoryBooks.useSameAsLlm);

      return;
    }

    final presets = <Map<String, dynamic>>[];
    for (final source in [kv, ls]) {
      for (final key in [
        'gz_api_connection_presets',
        'sc_api_connection_presets',
        'silly_cradle_api_presets',
        'api_connection_presets',
      ]) {
        final raw = source[key];
        if (raw == null) continue;
        extractPresetsFromRaw(raw, presets);
      }
    }

    if (topLevel != null) {
      final raw = topLevel['apiPresets'];
      if (raw != null) extractPresetsFromRaw(raw, presets);
    }

    if (presets.isEmpty) {
      final endpoint = ls['api-endpoint'] as String? ??
          kv['api-endpoint'] as String?;
      final apiKey =
          ls['api-key'] as String? ?? kv['api-key'] as String?;
      final model =
          ls['api-model'] as String? ?? kv['api-model'] as String?;
      if (endpoint != null && endpoint.isNotEmpty) {
        presets.add({
          'id': 'default',
          'name': 'Default',
          'endpoint': endpoint,
          'key': apiKey ?? '',
          'apiKey': apiKey ?? '',
          'model': model ?? '',
          'max_tokens': ls['api-max-tokens'] ?? kv['api-max-tokens'],
          'context': ls['api-context'] ?? kv['api-context'],
          'temp': ls['gz_api_temp'] ?? kv['gz_api_temp'],
          'topp': ls['gz_api_topp'] ?? kv['gz_api_topp'],
          'stream': ls['gz_api_stream'] ?? kv['gz_api_stream'],
          'reasoning_effort': ls['gz_api_reasoning_effort'] ??
              kv['gz_api_reasoning_effort'],
          'reasoning_enabled': ls['gz_api_request_reasoning'] ??
              kv['gz_api_request_reasoning'],
          'reasoning_start': ls['gz_api_reasoning_start'] ??
              kv['gz_api_reasoning_start'],
          'reasoning_end':
              ls['gz_api_reasoning_end'] ?? kv['gz_api_reasoning_end'],
          'omit_reasoning': ls['gz_api_omit_reasoning'] ??
              kv['gz_api_omit_reasoning'],
          'omit_reasoning_effort': ls['gz_api_omit_reasoning_effort'] ??
              kv['gz_api_omit_reasoning_effort'],
        });
      }
    }

    for (final preset in presets) {
      final presetMode = preset['mode'] as String? ?? 'chat';
      if (presetMode == 'embedding') {
        final embEndpoint = (preset['embedding_endpoint'] ??
                ls['gz_embedding_endpoint'] ??
                kv['gz_embedding_endpoint'] ??
                preset['endpoint']) as String? ??
            '';
        final embApiKey = (preset['embedding_key'] ??
                ls['gz_embedding_key'] ??
                kv['gz_embedding_key'] ??
                preset['apiKey'] ??
                preset['key']) as String? ??
            '';
        final embModel = (preset['embedding_model'] ??
                ls['gz_embedding_model'] ??
                kv['gz_embedding_model'] ??
                preset['model']) as String? ??
            '';
        final chatConfig = await db.select(db.apiConfigs).getSingleOrNull();
        if (chatConfig != null) {
          await (db.update(db.apiConfigs)
                ..where((t) => t.configId.equals(chatConfig.configId)))
              .write(ApiConfigsCompanion(
            embeddingUseSame: const Value(false),
            embeddingEnabled: const Value(true),
            embeddingEndpoint: Value(embEndpoint),
            embeddingApiKey: Value(embApiKey),
            embeddingModel: Value(embModel),
          ));
        }
        continue;
      }

      final embEnabled = preset['embedding_enabled'] ??
          ls['gz_embedding_enabled'] ??
          kv['gz_embedding_enabled'];
      final embUseSame = preset['embedding_use_same'] ??
          ls['gz_embedding_use_same'] ??
          kv['gz_embedding_use_same'];
      final embEndpoint = preset['embedding_endpoint'] ??
          ls['gz_embedding_endpoint'] ??
          kv['gz_embedding_endpoint'] as String?;
      final embApiKey = preset['embedding_key'] ??
          ls['gz_embedding_key'] ??
          kv['gz_embedding_key'] as String?;
      final embModel = preset['embedding_model'] ??
          ls['gz_embedding_model'] ??
          kv['gz_embedding_model'] as String?;

      await insertApiConfig(
          preset, presetMode,
          embeddingUseSame: embUseSame == 'true' || embUseSame == true,
          embeddingEnabled: embEnabled == 'true' || embEnabled == true,
          embeddingEndpoint: (embEndpoint ?? '') as String,
          embeddingApiKey: (embApiKey ?? '') as String,
          embeddingModel: (embModel ?? '') as String);
    }

    final presetOrderRaw =
        ls['gz_preset_order'] ?? kv['gz_preset_order'];
    if (presetOrderRaw != null) {
      List<String> order;
      if (presetOrderRaw is List) {
        order = presetOrderRaw.map((e) => e.toString()).toList();
      } else if (presetOrderRaw is String) {
        try {
          final decoded = jsonDecode(presetOrderRaw);
          order = decoded is List
              ? decoded.map((e) => e.toString()).toList()
              : <String>[];
        } catch (_) {
          order = <String>[];
        }
      } else {
        order = <String>[];
      }
      if (order.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('presetOrder', jsonEncode(order));
      }
    }
  }

  Future<void> insertApiConfig(
      Map<String, dynamic> preset, String mode,
      {bool embeddingUseSame = true,
      bool embeddingEnabled = false,
      String embeddingEndpoint = '',
      String embeddingApiKey = '',
      String embeddingModel = '',
      int embeddingMaxChunkTokens = 512}) async {
    await db.into(db.apiConfigs).insertOnConflictUpdate(
          ApiConfigsCompanion.insert(
            configId: preset['id'] as String? ?? '',
            name: preset['name'] as String? ?? '',
            providerId: Value(preset['providerId'] as String? ??
                preset['provider'] as String? ??
                preset['providerType'] as String? ??
                'openai_compatible'),
            endpoint: preset['endpoint'] != null
                ? Value(preset['endpoint'] as String)
                : const Value.absent(),
            apiKey: Value(
                preset['apiKey'] as String? ?? preset['key'] as String?),
            model: Value(preset['model'] as String?),
            mode: Value(mode),
            maxTokens: Value(toInt(preset['max_tokens']) ?? 8000),
            contextSize: Value(toInt(preset['context']) ?? 32000),
            temperature: Value(toDouble(preset['temp']) ?? 0.7),
            topP: Value(toDouble(preset['topp']) ?? 0.9),
            topK: Value(toInt(preset['top_k']) ?? 0),
            frequencyPenalty:
                Value(toDouble(preset['frequency_penalty']) ?? 0.0),
            presencePenalty:
                Value(toDouble(preset['presence_penalty']) ?? 0.0),
            stream: Value(preset['stream'] as bool? ?? true),
            reasoningEffort: Value(preset['reasoningEffort'] as String? ??
                preset['reasoning_effort'] as String? ??
                extractReasoningEffort(preset)),
            requestReasoning: Value(
                preset['requestReasoning'] as bool? ??
                    preset['reasoning_enabled'] as bool? ??
                    false),
            reasoningTagStart: Value(preset['reasoningTagStart'] as String? ??
                (preset['reasoningTags'] as Map<String, dynamic>?)
                    ?['start'] as String?),
            reasoningTagEnd: Value(preset['reasoningTagEnd'] as String? ??
                (preset['reasoningTags'] as Map<String, dynamic>?)
                    ?['end'] as String?),
            omitTemperature:
                Value(preset['omit_temperature'] as bool? ?? false),
            omitTopP: Value(preset['omit_top_p'] as bool? ?? false),
            omitReasoning:
                Value(preset['omit_reasoning'] as bool? ?? false),
            omitReasoningEffort:
                Value(preset['omit_reasoning_effort'] as bool? ?? false),
            embeddingUseSame: Value(embeddingUseSame),
            embeddingEnabled: Value(embeddingEnabled),
            embeddingEndpoint: Value(embeddingEndpoint),
            embeddingApiKey: Value(embeddingApiKey),
            embeddingModel: Value(embeddingModel),
            embeddingMaxChunkTokens: Value(embeddingMaxChunkTokens),
          ),
        );
  }
}
