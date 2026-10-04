import 'package:freezed_annotation/freezed_annotation.dart';

part 'memory_book_api_settings.freezed.dart';
part 'memory_book_api_settings.g.dart';

/// MemoryBook generation LLM settings — the model/endpoint/key used by manual
/// MemoryBook draft generation.
///
/// Nested inside [PipelineSettings] under the `memoryBookApi` field.
///
/// `generationSource='custom'` → use `generationEndpoint/ApiKey/Model`.
/// `apiConfigId` selects a saved API connection. An empty or missing id falls
/// back to the active chat connection. `generationModel` overrides that
/// connection's model when non-empty.
@freezed
abstract class MemoryBookApiSettings with _$MemoryBookApiSettings {
  const factory MemoryBookApiSettings({
    @Default('current') String generationSource,
    @Default('') String apiConfigId,
    @Default('') String generationModel,
    @Default('') String generationEndpoint,
    @Default('') String generationApiKey,
    @Default(null) double? generationTemperature,
    @Default(null) int? generationMaxTokens,
  }) = _MemoryBookApiSettings;

  factory MemoryBookApiSettings.fromJson(Map<String, dynamic> json) =>
      _$MemoryBookApiSettingsFromJson(json);
}
