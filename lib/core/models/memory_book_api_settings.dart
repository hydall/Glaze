import 'package:freezed_annotation/freezed_annotation.dart';

part 'memory_book_api_settings.freezed.dart';
part 'memory_book_api_settings.g.dart';

/// MemoryBook generation LLM settings — the model/endpoint/key used by manual
/// MemoryBook draft generation.
///
/// Nested inside [PipelineSettings] under the `memoryBookApi` field.
///
/// `generationSource='custom'` → use `generationEndpoint/ApiKey/Model`.
/// `generationSource='current'` → read the active chat API config and use its
/// endpoint/key/protocol. `generationModel` overrides the model when
/// non-empty.
@freezed
abstract class MemoryBookApiSettings with _$MemoryBookApiSettings {
  const factory MemoryBookApiSettings({
    @Default('current') String generationSource,
    @Default('') String generationModel,
    @Default('') String generationEndpoint,
    @Default('') String generationApiKey,
    @Default(null) double? generationTemperature,
    @Default(null) int? generationMaxTokens,
  }) = _MemoryBookApiSettings;

  factory MemoryBookApiSettings.fromJson(Map<String, dynamic> json) =>
      _$MemoryBookApiSettingsFromJson(json);
}
