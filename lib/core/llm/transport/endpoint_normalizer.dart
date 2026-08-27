import 'known_api_hosts.dart';
import 'llm_protocol.dart';

/// A user-entered endpoint parsed into the pieces needed to build a request
/// URL: `origin` (scheme + host + port), `path` (the API base path) and the
/// query string, which is preserved because some deployments (Azure OpenAI)
/// carry a mandatory `api-version` parameter.
class NormalizedEndpoint {
  /// `https://api.openai.com` — empty when the input could not be parsed.
  final String origin;

  /// `/v1` — leading slash, never a trailing one. Empty when the API lives at
  /// the root of the host.
  final String path;

  /// `api-version=2024-02-01` — without the leading `?`. Usually empty.
  final String query;

  /// True when the input already ended in a known operation path
  /// (`/chat/completions`, `/messages`, …). Such an input is treated as
  /// "the user knows the exact URL", so no version segment is invented.
  final bool hasExplicitRoute;

  const NormalizedEndpoint({
    required this.origin,
    required this.path,
    required this.query,
    required this.hasExplicitRoute,
  });

  static const NormalizedEndpoint invalid = NormalizedEndpoint(
    origin: '',
    path: '',
    query: '',
    hasExplicitRoute: false,
  );

  bool get isValid => origin.isNotEmpty;

  /// `https://api.openai.com/v1` — the base every route is appended to.
  String get base => isValid ? '$origin$path' : '';

  /// Appends an operation path (`/chat/completions`) to [base], re-attaching
  /// the query string when there is one.
  String join(String suffix) {
    if (!isValid) return '';
    final normalizedSuffix = suffix.isEmpty || suffix.startsWith('/')
        ? suffix
        : '/$suffix';
    final url = '$base$normalizedSuffix';
    return query.isEmpty ? url : '$url?$query';
  }

  /// The same endpoint with every version segment removed — used to build
  /// fallback candidates for providers that serve at the host root.
  NormalizedEndpoint withoutVersionSegments() {
    if (!isValid || path.isEmpty) return this;
    final kept = path
        .split('/')
        .where((s) => s.isNotEmpty && !EndpointNormalizer.looksLikeVersion(s))
        .toList();
    return NormalizedEndpoint(
      origin: origin,
      path: kept.isEmpty ? '' : '/${kept.join('/')}',
      query: query,
      hasExplicitRoute: hasExplicitRoute,
    );
  }
}

/// Turns whatever the user typed into the endpoint field into a URL that
/// actually resolves.
///
/// The field is free text and gets everything: `api.openai.com`,
/// `https://api.openai.com/v1/chat/completions`, `htp:/api.openai.com`,
/// `api.openai.com/v1/chat/compeltions`, a URL wrapped in quotes, a URL with
/// a trailing comma. Normalization is a pure, testable pipeline:
///
/// 1. strip invisible characters, whitespace, wrapping quotes/brackets and
///    trailing punctuation;
/// 2. repair the scheme (`htp://` → `http://`, `https//` → `https://`) or add
///    one (`https://`, or `http://` for localhost / private addresses);
/// 3. drop a trailing operation path — `/chat/completions`, `/responses`,
///    `/messages`, `/embeddings`, `/models`, `…:generateContent` — including
///    misspellings, so the base can be rebuilt cleanly;
/// 4. repair a mistyped version segment (`vl` → `v1`);
/// 5. rewrite the base path for hosts in [KnownApiHosts] (this is what fixes
///    `openrouter.ai` → `/api/v1` and `api.perplexity.ai/v1` → root);
/// 6. otherwise append the protocol's default version segment when the path
///    has none and the user did not paste a complete operation URL.
///
/// What normalization cannot know — an unlisted provider with an unusual base
/// path — is covered at request time by [candidates]: the transport walks the
/// alternatives on 404/405 instead of surfacing the error.
class EndpointNormalizer {
  EndpointNormalizer._();

  static const String defaultVersion = 'v1';

  static final RegExp _invisible = RegExp(
    r'[\u0000-\u0008\u000B-\u001F\u007F\u00A0\u200B-\u200F\u2028\u2029\uFEFF]',
  );
  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _leadingWrappers = RegExp(r'''^[<"'`\[(]+''');
  static final RegExp _trailingWrappers = RegExp(r'''[>"'`\])]+$''');
  static final RegExp _trailingPunctuation = RegExp(r'[.,;:!]+$');
  static final RegExp _leadingSlashes = RegExp(r'^/+');
  static final RegExp _schemeWithSeparator = RegExp(
    r'^([A-Za-z][A-Za-z0-9+.\-]*)[:;]+(/*)',
  );
  static final RegExp _schemeWithoutColon = RegExp(
    r'^([A-Za-z][A-Za-z0-9+.\-]*)(//+)',
  );
  static final RegExp _versionSegment = RegExp(
    r'^v\d+([a-z]+\d*)?$',
    caseSensitive: false,
  );
  static final RegExp _mistypedVersion = RegExp(
    r'^v[.\-_]?([0-9lLiI])(beta|alpha|preview)?$',
    caseSensitive: false,
  );
  static final RegExp _privateIp = RegExp(
    r'^(127\.|10\.|192\.168\.|169\.254\.|0\.0\.0\.0$|172\.(1[6-9]|2\d|3[01])\.)',
  );
  static final RegExp _nonLetters = RegExp(r'[^a-z]');

  /// Operation segments that mark the end of a complete API URL.
  static const List<String> _routeWords = [
    'completions',
    'responses',
    'messages',
    'embeddings',
    'models',
    'generatecontent',
    'streamgeneratecontent',
    'chatcompletions',
    'generations',
  ];

  /// Singular / shorthand spellings that are too short for fuzzy matching.
  static const List<String> _routeAliases = [
    'completion',
    'response',
    'message',
    'embedding',
    'model',
    'edits',
    'generation',
  ];

  /// Parses [raw] into an endpoint ready to build URLs from.
  ///
  /// [version] is the version segment appended when the path has none
  /// (`v1` for OpenAI-compatible and Anthropic). [insertVersion] disables that
  /// step; [forceVersion] applies it even when the user pasted a complete
  /// operation URL. [gemini] selects the Gemini native host table.
  static NormalizedEndpoint parse(
    String raw, {
    String version = defaultVersion,
    bool insertVersion = true,
    bool forceVersion = false,
    bool gemini = false,
  }) {
    final cleaned = _clean(raw);
    if (cleaned.isEmpty) return NormalizedEndpoint.invalid;

    final (withScheme, explicitScheme) = _withScheme(cleaned);
    final Uri uri;
    try {
      uri = Uri.parse(withScheme);
    } on FormatException {
      return NormalizedEndpoint.invalid;
    }
    if (uri.host.isEmpty) return NormalizedEndpoint.invalid;
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return NormalizedEndpoint.invalid;
    }
    // `some random text` collapses into a bare word that Uri happily accepts
    // as a host. Reject it — unless the user typed a scheme, which makes even
    // an odd single-label host (a hosts-file alias) deliberate.
    if (!explicitScheme && !_isPlausibleHost(uri)) {
      return NormalizedEndpoint.invalid;
    }

    final host = uri.host.toLowerCase();
    final bracketedHost = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    final userInfo = uri.userInfo.isEmpty ? '' : '${uri.userInfo}@';
    final origin =
        '${uri.scheme}://$userInfo$bracketedHost'
        '${uri.hasPort ? ':${uri.port}' : ''}';
    final query = uri.query;

    final stripped = _stripRoute(
      uri.path.split('/').where((s) => s.isNotEmpty).toList(),
    );
    var segments = stripped.segments
        .map(_repairVersionSegment)
        .toList(growable: true);

    var versionResolved = false;
    final knownPath = KnownApiHosts.basePathFor(host, gemini: gemini);
    if (knownPath != null && _isReplaceablePath(segments, knownPath)) {
      segments = knownPath.isEmpty
          ? <String>[]
          : knownPath.split('/').toList(growable: true);
      versionResolved = true;
    }

    // Azure deployments carry their own path shape and a mandatory
    // `api-version` query — never invent a version segment for them.
    final azure =
        host.endsWith('.openai.azure.com') ||
        segments.any((s) => s.toLowerCase() == 'deployments');

    final needsVersion =
        insertVersion &&
        !versionResolved &&
        !azure &&
        query.isEmpty &&
        version.isNotEmpty &&
        (forceVersion || !stripped.hasExplicitRoute) &&
        !segments.any(looksLikeVersion);
    if (needsVersion) {
      segments.addAll(version.split('/').where((s) => s.isNotEmpty));
    }

    return NormalizedEndpoint(
      origin: origin,
      path: segments.isEmpty ? '' : '/${segments.join('/')}',
      query: query,
      hasExplicitRoute: stripped.hasExplicitRoute,
    );
  }

  // ── URL builders ──────────────────────────────────────────────────────────

  /// `{base}/chat/completions` — OpenAI Chat Completions.
  static String chatCompletionsUrl(String raw) =>
      parse(raw).join('/chat/completions');

  /// `{base}/responses` — OpenAI Responses API.
  static String responsesUrl(String raw) => parse(raw).join('/responses');

  /// `{base}/messages` — Anthropic Messages API.
  static String messagesUrl(String raw) => parse(raw).join('/messages');

  /// `{base}/embeddings` — OpenAI-compatible embeddings.
  static String embeddingsUrl(String raw) => parse(raw).join('/embeddings');

  /// `{base}/models` — model listing for OpenAI-compatible and Anthropic.
  static String modelsUrl(String raw) => parse(raw).join('/models');

  /// `{base}/images/{action}` — OpenAI image generation (`generations`,
  /// `edits`).
  static String imagesUrl(String raw, String action) =>
      parse(raw).join('/images/$action');

  /// The cleaned base URL without any operation path.
  static String baseUrl(String raw, {String version = defaultVersion}) =>
      parse(raw, version: version).base;

  /// Gemini's base: the version segment is added by the transport
  /// (`/v1beta/models/…`), so it must not be part of the base.
  static String geminiBase(String raw) => parse(
    raw,
    gemini: true,
    insertVersion: false,
  ).withoutVersionSegments().base;

  /// Canonical URL stored in `ApiConfig.endpoint` for an LLM connection.
  ///
  /// Request transports consume this value as-is. Route completion belongs at
  /// the persistence boundary so the endpoint shown to the user is the endpoint
  /// that will actually receive generation requests.
  static String persistedLlmEndpoint({
    required String raw,
    required String protocol,
    required String model,
    required bool stream,
    bool useResponsesApi = false,
  }) {
    final trimmed = raw.trim();
    if (protocol == LlmProtocol.openrouter) {
      return 'https://openrouter.ai/api/v1/chat/completions';
    }
    if (trimmed.isEmpty) return '';

    final resolved = switch (protocol) {
      LlmProtocol.openaiResponses => responsesUrl(trimmed),
      LlmProtocol.anthropic => messagesUrl(trimmed),
      LlmProtocol.gemini => _geminiGenerationUrl(
        trimmed,
        model: model,
        stream: stream,
      ),
      LlmProtocol.customChatCompletion when useResponsesApi => responsesUrl(
        trimmed,
      ),
      _ => chatCompletionsUrl(trimmed),
    };
    return resolved.isEmpty ? trimmed : resolved;
  }

  /// Canonical URL stored in `ApiConfig.embeddingEndpoint`.
  static String persistedEmbeddingEndpoint(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final resolved = embeddingsUrl(trimmed);
    return resolved.isEmpty ? trimmed : resolved;
  }

  static String _geminiGenerationUrl(
    String raw, {
    required String model,
    required bool stream,
  }) {
    final base = geminiBase(raw);
    if (base.isEmpty) return '';
    final modelName = model.trim();
    if (modelName.isEmpty) return '$base/v1beta/models';
    final action = stream ? 'streamGenerateContent' : 'generateContent';
    return '$base/v1beta/models/$modelName:$action';
  }

  /// Ordered URLs to try for [suffix]: the normalized one first, then the
  /// plausible alternatives (version forced on / stripped off). Transports
  /// walk this list on 404/405 so an unlisted provider with an unusual base
  /// path still connects instead of failing.
  static List<String> candidates(
    String raw,
    String suffix, {
    String version = defaultVersion,
  }) {
    final urls = <String>[];
    void add(NormalizedEndpoint endpoint) {
      final url = endpoint.join(suffix);
      if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
    }

    final primary = parse(raw, version: version);
    add(primary);
    add(parse(raw, version: version, forceVersion: true));
    add(parse(raw, version: version, insertVersion: false));
    add(primary.withoutVersionSegments());
    return urls;
  }

  static List<String> chatCompletionsCandidates(String raw) =>
      candidates(raw, '/chat/completions');

  static List<String> responsesCandidates(String raw) =>
      candidates(raw, '/responses');

  static List<String> messagesCandidates(String raw) =>
      candidates(raw, '/messages');

  static List<String> embeddingsCandidates(String raw) =>
      candidates(raw, '/embeddings');

  static List<String> modelsCandidates(String raw) =>
      candidates(raw, '/models');

  /// True for `v1`, `v1beta`, `v2`… — used to decide whether a version
  /// segment still has to be appended.
  static bool looksLikeVersion(String segment) =>
      _versionSegment.hasMatch(segment);

  // ── internals ─────────────────────────────────────────────────────────────

  static String _clean(String raw) {
    var s = raw.replaceAll(_invisible, '').replaceAll(_whitespace, '');
    s = s.replaceFirst(_leadingWrappers, '');
    // Pasted values mix wrappers, punctuation and slashes in any order
    // (`"https://api.host/v1",`) — peel until nothing changes.
    String previous;
    do {
      previous = s;
      s = s.replaceFirst(_trailingWrappers, '');
      s = s.replaceFirst(_trailingPunctuation, '');
      while (s.endsWith('/')) {
        s = s.substring(0, s.length - 1);
      }
    } while (s != previous);
    return s;
  }

  /// Returns the input with a usable scheme, and whether the user supplied
  /// one themselves (a typo still counts — they meant a URL).
  static (String, bool) _withScheme(String input) {
    final s = input.replaceAll('\\', '/');

    final withSeparator = _schemeWithSeparator.firstMatch(s);
    if (withSeparator != null) {
      final word = withSeparator.group(1)!.toLowerCase();
      final slashes = withSeparator.group(2)!;
      final rest = s.substring(withSeparator.end);
      if (word == 'http' || word == 'https') return ('$word://$rest', true);
      if (slashes.isNotEmpty) {
        final repaired = _repairHttpScheme(word);
        if (repaired != null) {
          // A mistyped scheme says nothing about http vs https, so fall back
          // to what the host deserves — unless the typo carried the `s`.
          final scheme = repaired == 'https' ? 'https' : _defaultScheme(rest);
          return ('$scheme://$rest', true);
        }
        return (s, true); // ws://, ftp://… — rejected by the caller
      }
      // No slashes after the colon: this is `host:port`, not a scheme.
    } else {
      final withoutColon = _schemeWithoutColon.firstMatch(s);
      if (withoutColon != null) {
        final rest = s.substring(withoutColon.end);
        final repaired = _repairHttpScheme(
          withoutColon.group(1)!.toLowerCase(),
        );
        if (repaired != null) {
          final scheme = repaired == 'https' ? 'https' : _defaultScheme(rest);
          return ('$scheme://$rest', true);
        }
      }
    }

    final withoutLeadingSlashes = s.replaceFirst(_leadingSlashes, '');
    return (
      '${_defaultScheme(withoutLeadingSlashes)}://$withoutLeadingSlashes',
      false,
    );
  }

  /// A host is plausible when it is dotted (`api.host`), an IPv6 literal,
  /// `localhost`, or carries an explicit port (`myserver:8080`).
  static bool _isPlausibleHost(Uri uri) {
    final host = uri.host.toLowerCase();
    return host.contains('.') ||
        host.contains(':') ||
        host == 'localhost' ||
        uri.hasPort;
  }

  /// Schemes that are real and simply not ours — never "repaired" into http.
  static const Set<String> _foreignSchemes = {
    'ftp',
    'ftps',
    'sftp',
    'ssh',
    'file',
    'ws',
    'wss',
    'data',
    'mailto',
  };

  /// Maps a misspelled scheme onto http/https; null when it is not one.
  static String? _repairHttpScheme(String word) {
    if (word == 'http' || word == 'https') return word;
    if (_foreignSchemes.contains(word)) return null;
    if (word.length < 3 || word.length > 7) return null;
    final preferred = word.contains('s') ? 'https' : 'http';
    if (_levenshtein(word, preferred) <= 2) return preferred;
    final other = preferred == 'https' ? 'http' : 'https';
    if (_levenshtein(word, other) <= 2) return other;
    return null;
  }

  static String _defaultScheme(String rest) {
    final authority = rest.split('/').first.split('?').first;
    final hostPart = authority.contains('@')
        ? authority.split('@').last
        : authority;
    final hostname =
        (hostPart.startsWith('[')
                ? hostPart.substring(1).split(']').first
                : hostPart.split(':').first)
            .toLowerCase();
    if (hostname == 'localhost' ||
        hostname == '::1' ||
        hostname.endsWith('.local') ||
        hostname.endsWith('.localhost') ||
        _privateIp.hasMatch(hostname)) {
      return 'http';
    }
    return 'https';
  }

  static _StrippedRoute _stripRoute(List<String> input) {
    final segments = List<String>.from(input);
    var hasExplicitRoute = false;
    var changed = true;

    while (changed && segments.isNotEmpty) {
      changed = false;
      final last = segments.last;

      // `models/gemini-3-pro:generateContent`
      if (last.contains(':')) {
        segments.removeLast();
        hasExplicitRoute = true;
        changed = true;
        continue;
      }

      final matched = _matchRouteWord(_canonicalWord(last));
      if (matched == null) break;

      segments.removeLast();
      hasExplicitRoute = true;
      changed = true;
      // `chat` and `images` are operation segments only together with the
      // `completions` / `generations` that was just stripped.
      final owner = switch (matched) {
        'completions' || 'completion' => 'chat',
        'generations' || 'generation' || 'edits' => 'images',
        _ => null,
      };
      if (owner != null &&
          segments.isNotEmpty &&
          _canonicalWord(segments.last) == owner) {
        segments.removeLast();
      }
    }

    return _StrippedRoute(segments, hasExplicitRoute);
  }

  static String _canonicalWord(String segment) =>
      segment.toLowerCase().replaceAll(_nonLetters, '');

  static String? _matchRouteWord(String word) {
    if (word.isEmpty) return null;
    for (final canonical in _routeWords) {
      if (word == canonical) return canonical;
    }
    for (final alias in _routeAliases) {
      if (word == alias) return alias;
    }
    // Misspellings: `compeltions`, `completons`, `embedings`.
    for (final canonical in _routeWords) {
      if (word.length < 6) continue;
      if ((word.length - canonical.length).abs() > 2) continue;
      if (_levenshtein(word, canonical) <= 2) return canonical;
    }
    return null;
  }

  static String _repairVersionSegment(String segment) {
    if (_versionSegment.hasMatch(segment)) return segment.toLowerCase();
    final match = _mistypedVersion.firstMatch(segment);
    if (match == null) return segment;
    final digit = match.group(1)!.toLowerCase();
    final normalizedDigit = (digit == 'l' || digit == 'i') ? '1' : digit;
    final suffix = match.group(2)?.toLowerCase() ?? '';
    return 'v$normalizedDigit$suffix';
  }

  static bool _isReplaceablePath(List<String> segments, String knownPath) {
    if (segments.isEmpty) return true;
    if (segments.every(looksLikeVersion)) return true;
    final known = knownPath.isEmpty ? const <String>[] : knownPath.split('/');
    if (segments.length > known.length) return false;
    for (var i = 0; i < segments.length; i++) {
      if (segments[i].toLowerCase() != known[i].toLowerCase()) return false;
    }
    return true;
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    var previous = List<int>.generate(b.length + 1, (i) => i);
    var current = List<int>.filled(b.length + 1, 0);

    for (var i = 0; i < a.length; i++) {
      current[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
        final deletion = previous[j + 1] + 1;
        final insertion = current[j] + 1;
        final substitution = previous[j] + cost;
        var min = deletion < insertion ? deletion : insertion;
        if (substitution < min) min = substitution;
        current[j + 1] = min;
      }
      final swap = previous;
      previous = current;
      current = swap;
    }
    return previous[b.length];
  }
}

class _StrippedRoute {
  final List<String> segments;
  final bool hasExplicitRoute;

  const _StrippedRoute(this.segments, this.hasExplicitRoute);
}
