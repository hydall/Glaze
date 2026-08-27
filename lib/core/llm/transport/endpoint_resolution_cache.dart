/// Remembers which candidate URL a stored endpoint actually resolved to.
///
/// [EndpointNormalizer.candidates] can offer several plausible URLs for one
/// endpoint; the transport walks them on 404/405. Without a memory every
/// request would pay that walk again, so the winning URL is kept for the
/// lifetime of the process and tried first next time.
///
/// Deliberately in-memory only: nothing here is worth persisting, and a
/// provider that changes its URL shape gets a clean slate on the next launch.
class EndpointResolutionCache {
  EndpointResolutionCache._();

  static final Map<String, String> _resolved = <String, String>{};

  static String _key(String rawEndpoint, String suffix) =>
      '${rawEndpoint.trim()}|$suffix';

  /// [candidates] with the previously successful URL moved to the front.
  static List<String> order(
    String rawEndpoint,
    String suffix,
    List<String> candidates,
  ) {
    final known = _resolved[_key(rawEndpoint, suffix)];
    if (known == null || candidates.length < 2) return candidates;
    final index = candidates.indexOf(known);
    if (index <= 0) return candidates;
    return [known, ...candidates.where((c) => c != known)];
  }

  /// Records that [url] answered for [rawEndpoint]. Only worth storing when
  /// there was more than one candidate to choose from.
  static void record(String rawEndpoint, String suffix, String url) {
    if (url.isEmpty) return;
    _resolved[_key(rawEndpoint, suffix)] = url;
  }

  /// The base URL (route suffix removed) that [rawEndpoint] resolved to, or
  /// null when nothing was recorded. The settings screen uses it to write the
  /// working URL back into the endpoint field after a successful test, so the
  /// fallback is paid once instead of on every launch.
  static String? resolvedBase(String rawEndpoint) {
    final prefix = '${rawEndpoint.trim()}|';
    for (final entry in _resolved.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final suffix = entry.key.substring(prefix.length);
      final url = entry.value;
      if (url.endsWith(suffix)) {
        return url.substring(0, url.length - suffix.length);
      }
    }
    return null;
  }

  static void clear() => _resolved.clear();
}
