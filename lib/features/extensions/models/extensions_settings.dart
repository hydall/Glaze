import 'package:freezed_annotation/freezed_annotation.dart';

part 'extensions_settings.freezed.dart';
part 'extensions_settings.g.dart';

@freezed
abstract class ExtensionsSettings with _$ExtensionsSettings {
  const factory ExtensionsSettings({
    @Default(false) bool enabled,
    String? activePresetId,
  }) = _ExtensionsSettings;

  factory ExtensionsSettings.fromJson(Map<String, dynamic> json) =>
      _$ExtensionsSettingsFromJson(json);
}
