import 'package:freezed_annotation/freezed_annotation.dart';

part 'connection_profiles.freezed.dart';
part 'connection_profiles.g.dart';

/// Per-preset connection profile mapping for `glaze.generateText({ preset })`.
///
/// Extensions can request one of three connection profiles when calling
/// `generateText`:
///   * `big`    — typically a large-context, high-quality model (e.g. a
///                flagship 70B+ class or a strong reasoning model).
///   * `medium` — the default mid-tier model.
///   * `small`  — a fast, cheap model suitable for short classifier or
///                rewriter tasks.
///
/// Each profile maps to an `ApiConfig.id` from the user's API config
/// list. When a profile is unset, the bridge falls back to the active
/// API config so existing single-config setups keep working unchanged.
@freezed
abstract class ConnectionProfiles with _$ConnectionProfiles {
  const factory ConnectionProfiles({
    /// `apiConfigId` to use when the JS caller asks for `big`.
    /// Empty string means "fall back to the active API config".
    @Default('') String big,

    /// `apiConfigId` to use when the JS caller asks for `medium`.
    @Default('') String medium,

    /// `apiConfigId` to use when the JS caller asks for `small`.
    @Default('') String small,
  }) = _ConnectionProfiles;

  factory ConnectionProfiles.fromJson(Map<String, dynamic> json) =>
      _$ConnectionProfilesFromJson(json);
}

/// Profile name → key into [ConnectionProfiles]. Used by the bridge to
/// look up the right `apiConfigId` from a JS request.
enum ConnectionProfile { big, medium, small }

extension ConnectionProfileX on ConnectionProfile {
  String get id => name;

  /// Returns the requested profile name (case-insensitive) or `null`
  /// if the string is not a known profile.
  static ConnectionProfile? parse(Object? raw) {
    if (raw is! String) return null;
    final lower = raw.trim().toLowerCase();
    switch (lower) {
      case 'big':
        return ConnectionProfile.big;
      case 'medium':
        return ConnectionProfile.medium;
      case 'small':
        return ConnectionProfile.small;
      default:
        return null;
    }
  }
}
