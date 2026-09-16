/// Profile name a JS caller may ask `glaze.generateText` for.
///
/// The original extension routes each block through one of three connections;
/// Glaze runs a preset on a single connection, so every profile resolves to
/// the same one. The names are kept because imported blocks carry them and the
/// bridge accepts them.
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
