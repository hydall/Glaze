/// Data shapes the DataCat Client API answers with.
///
/// Shaped against the vendored contract in `docs/external/` rather than
/// guessed. Still read defensively where the contract allows it: additive
/// fields may appear within v1 and must be ignored, and a missing optional
/// value is normally null rather than absent.
library;

int? _int(Object? v) =>
    v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
double? _double(Object? v) =>
    v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
String _str(Object? v) => v?.toString() ?? '';
Map<String, dynamic> _map(Object? v) =>
    v is Map<Object?, Object?> ? v.cast<String, dynamic>() : const {};
List<Map<String, dynamic>> _maps(Object? v) => v is List
    ? v
          .whereType<Map<Object?, Object?>>()
          .map((e) => e.cast<String, dynamic>())
          .toList()
    : const [];

/// Largest `offset` any listing endpoint accepts, from the parameter schema.
const datacatMaxOffset = 200000;

/// Bounds the `/tags` and creator endpoints enforce on their page sizes.
/// The parameter schema says 250; the live deployment clamps to 240 and
/// reports that back as `paging.limit`. Asking for the real ceiling keeps the
/// request and the response describing the same page.
const datacatMaxTagLimit = 240;
const datacatMaxCreatorLimit = 50;

/// Where a page sits in a result set.
///
/// The contract is explicit that `nextOffset` is the only authoritative next
/// page, so it is preferred over arithmetic on `total` — which is optional, and
/// which some responses report as `totalCount` instead.
class DatacatPaging {
  final int limit;
  final int offset;
  final int total;
  final bool hasMore;
  final int? nextOffset;

  const DatacatPaging({
    this.limit = 0,
    this.offset = 0,
    this.total = 0,
    this.hasMore = false,
    this.nextOffset,
  });

  factory DatacatPaging.fromJson(Map<String, dynamic> json) => DatacatPaging(
    limit: _int(json['limit']) ?? 0,
    offset: _int(json['offset']) ?? 0,
    total: _int(json['total']) ?? _int(json['totalCount']) ?? 0,
    hasMore: json['hasMore'] == true,
    nextOffset: _int(json['nextOffset']),
  );
}

/// The creator as a character summary carries them — enough to label a card and
/// to open the creator's own screen, which needs [ref], not [id].
class DatacatCreatorRef {
  final String id;
  final String ref;
  final String sourceKind;
  final String name;

  const DatacatCreatorRef({
    this.id = '',
    this.ref = '',
    this.sourceKind = '',
    this.name = '',
  });

  factory DatacatCreatorRef.fromJson(Map<String, dynamic> json) =>
      DatacatCreatorRef(
        id: _str(json['id']),
        ref: _str(json['ref']),
        sourceKind: _str(json['sourceKind']),
        name: _str(json['name']),
      );
}

/// A creator's own page: `/creators/{ref}/bootstrap` returns this plus the
/// first page of their characters.
class DatacatCreatorProfile {
  final String id;
  final String ref;
  final String sourceKind;
  final String name;
  final String handle;
  final String? avatarUrl;
  final String about;
  final bool verified;
  final int characterCount;
  final int chatCount;
  final int messageCount;
  final List<String> topTags;

  const DatacatCreatorProfile({
    this.id = '',
    this.ref = '',
    this.sourceKind = '',
    this.name = '',
    this.handle = '',
    this.avatarUrl,
    this.about = '',
    this.verified = false,
    this.characterCount = 0,
    this.chatCount = 0,
    this.messageCount = 0,
    this.topTags = const [],
  });

  factory DatacatCreatorProfile.fromJson(Map<String, dynamic> json) {
    // `stats` is a free-form number map in the contract, so each figure is
    // looked up by name rather than by position.
    final stats = _map(json['stats']);
    return DatacatCreatorProfile(
      id: _str(json['id']),
      ref: _str(json['ref']),
      sourceKind: _str(json['sourceKind']),
      name: _str(json['name']),
      handle: _str(json['handle']),
      avatarUrl: json['avatarUrl'] as String?,
      about: _str(json['about']),
      verified: json['verified'] == true,
      characterCount: _int(stats['characters']) ?? 0,
      chatCount: _int(stats['chats']) ?? 0,
      messageCount: _int(stats['messages']) ?? 0,
      topTags: _maps(json['topTags'])
          .map((t) => _str(t['name'] ?? t['slug']))
          .where((t) => t.isNotEmpty)
          .toList(),
    );
  }
}

/// What the server says it currently supports.
///
/// Read once at the first DataCat request and cached, so the page size comes
/// from the deployment instead of a constant in the app. Only the parts the app
/// acts on are modelled; the rest of the response is ignored, as the contract
/// asks.
class DatacatCapabilities {
  final int defaultPageSize;
  final int maxPageSize;

  /// `features.listing` — character browsing and search.
  final bool listing;

  /// `features.tagBrowsing` — the faceted tag picker.
  final bool tagBrowsing;

  /// `features.social` — kudos and comments.
  final bool social;

  /// Whether protected transfers go through the hosted human-verification
  /// challenge on this deployment.
  final bool securityCheckEnabled;

  /// The verification actions this deployment will start a challenge for.
  ///
  /// Worth reading rather than hard-coding: the contract documents the value as
  /// `character_transfer`, the live server answers that with a 400 and names
  /// `character-import` instead, and the only thing that stayed true through
  /// the rename is that the server advertises the legal values here.
  final List<String> verificationActions;

  /// How long an issued lease lives. Only used as the fallback when a lease
  /// arrives without a readable expiry of its own.
  final Duration leaseTtl;

  const DatacatCapabilities({
    this.defaultPageSize = 24,
    this.maxPageSize = 24,
    this.listing = true,
    this.tagBrowsing = true,
    this.social = true,
    this.securityCheckEnabled = true,
    this.verificationActions = const [],
    this.leaseTtl = const Duration(minutes: 30),
  });

  factory DatacatCapabilities.fromJson(Map<String, dynamic> json) {
    final paging = _map(json['paging']);
    final features = _map(json['features']);
    final securityCheck = _map(json['securityCheck']);
    bool feature(String name) =>
        features[name] is bool ? features[name] as bool : true;
    final maxPageSize = _int(paging['maxPageSize']) ?? 24;
    // The deployment lists the actions under both names; either will do.
    final actions = securityCheck['actions'] is List
        ? securityCheck['actions'] as List
        : (_map(json['verification'])['actions'] as List? ?? const []);
    final leaseSeconds = _int(securityCheck['leaseTtlSeconds']);
    return DatacatCapabilities(
      defaultPageSize: _int(paging['defaultPageSize']) ?? maxPageSize,
      maxPageSize: maxPageSize,
      listing: feature('listing'),
      tagBrowsing: feature('tagBrowsing'),
      social: feature('social'),
      securityCheckEnabled: securityCheck['enabled'] != false,
      verificationActions: actions
          .map(_str)
          .where((a) => a.isNotEmpty)
          .toList(),
      leaseTtl: leaseSeconds == null || leaseSeconds <= 0
          ? const Duration(minutes: 30)
          : Duration(seconds: leaseSeconds),
    );
  }
}

/// One choice in the kudos picker, with however many have been given.
///
/// The contract splits these across two arrays: `options` advertises what may
/// be sent, `gifts` reports what has been. They are merged here so the UI reads
/// one list.
class DatacatKudosOption {
  final String giftKey;
  final String label;
  final String? emoji;
  final String description;
  final int count;

  const DatacatKudosOption({
    required this.giftKey,
    required this.label,
    this.emoji,
    this.description = '',
    this.count = 0,
  });

  factory DatacatKudosOption.fromJson(Map<String, dynamic> json) {
    final key = _str(json['key'] ?? json['giftKey']);
    final label = _str(json['label']);
    return DatacatKudosOption(
      giftKey: key,
      label: label.isEmpty ? key : label,
      emoji: json['emoji'] as String?,
      description: _str(json['description']),
      count: _int(json['count']) ?? 0,
    );
  }

  DatacatKudosOption withCount(int count) => DatacatKudosOption(
    giftKey: giftKey,
    label: label,
    emoji: emoji,
    description: description,
    count: count,
  );
}

/// Kudos totals and the reply options a viewer may pick from, plus one page of
/// comments and whether this viewer may interact at all.
class DatacatCommunity {
  final int kudosTotal;
  final List<DatacatKudosOption> kudosOptions;
  final List<Map<String, dynamic>> comments;
  final DatacatPaging paging;
  final bool canInteract;

  const DatacatCommunity({
    this.kudosTotal = 0,
    this.kudosOptions = const [],
    this.comments = const [],
    this.paging = const DatacatPaging(),
    this.canInteract = false,
  });

  /// Reads the `community` object out of either a read or a write response.
  factory DatacatCommunity.fromJson(Map<String, dynamic> json) {
    final community = _map(json['community']);
    final body = community.isEmpty ? json : community;
    final kudos = _map(body['kudos']);
    final comments = _map(body['comments']);

    // `options` says what can be sent, `gifts` how many of each already were.
    final counts = <String, int>{
      for (final gift in _maps(kudos['gifts']))
        _str(gift['key'] ?? gift['giftKey']): _int(gift['count']) ?? 0,
    };
    final options = _maps(kudos['options'])
        .map(DatacatKudosOption.fromJson)
        .map((o) => o.withCount(counts[o.giftKey] ?? 0))
        .toList();
    // A deployment that advertises no options but has received kudos still has
    // something to show, so the gifts stand in for them.
    final merged = options.isNotEmpty
        ? options
        : _maps(kudos['gifts']).map(DatacatKudosOption.fromJson).toList();

    return DatacatCommunity(
      kudosTotal: _int(kudos['total']) ?? 0,
      kudosOptions: merged,
      comments: _maps(comments['items']),
      paging: DatacatPaging.fromJson(_map(comments['paging'])),
      canInteract: body['canInteract'] == true,
    );
  }
}

/// Whether an installation is linked, and to what.
///
/// `accountState` is the contract's own three-way answer, and the distinction
/// matters: `linked_anonymous` is a linked installation with no user behind it,
/// which may read but may not post — community writes are rejected for anything
/// but `logged_in`.
class DatacatAccountStatus {
  final String accountState;
  final bool boundToAccountToken;
  final String rateTier;
  final String? displayName;
  final List<String> scopes;

  const DatacatAccountStatus({
    this.accountState = 'unlinked',
    this.boundToAccountToken = false,
    this.rateTier = '',
    this.displayName,
    this.scopes = const [],
  });

  /// The two states that mean this installation is bound to something.
  ///
  /// Named rather than defined as "anything but `unlinked`": a rate-limit body
  /// from the live server reports `accountState: "anonymous"`, which the
  /// open-ended test read as linked and would have kept a dead token on.
  bool get linked =>
      accountState == 'linked_anonymous' || accountState == 'logged_in';
  bool get loggedIn => accountState == 'logged_in';

  factory DatacatAccountStatus.fromJson(
    Map<String, dynamic> json, {
    List<String> scopes = const [],
  }) {
    final account = _map(json['account']);
    final name = _str(account['displayName']).isNotEmpty
        ? _str(account['displayName'])
        : _str(account['username']);
    return DatacatAccountStatus(
      accountState: _str(json['accountState']),
      boundToAccountToken: _map(json['installation'])['boundToAccountToken'] == true,
      rateTier: _str(_map(json['rateLimit'])['tier']),
      displayName: name.isEmpty ? null : name,
      scopes: scopes,
    );
  }
}

/// A started device flow — either an account link or a human-verification
/// challenge. Both hand back the same shape, so both use this.
class DatacatDeviceFlow {
  /// The link or verification id the token exchange is made against.
  final String id;

  /// The secret the token exchange sends back.
  final String deviceCode;

  /// The short code the user reads off the screen. Account linking has one;
  /// verification does not.
  final String? userCode;

  /// The hosted page to open — already carrying the code, so the user does not
  /// have to type it.
  final String uri;

  final Duration expiresIn;
  final Duration interval;

  const DatacatDeviceFlow({
    required this.id,
    required this.deviceCode,
    required this.uri,
    this.userCode,
    this.expiresIn = const Duration(minutes: 10),
    this.interval = const Duration(seconds: 3),
  });

  factory DatacatDeviceFlow.fromJson(Map<String, dynamic> json) =>
      DatacatDeviceFlow(
        id: _str(json['linkId'] ?? json['verificationId']),
        deviceCode: _str(json['deviceCode']),
        userCode: json['userCode'] as String?,
        uri: _str(
          json['authorizationUriComplete'] ??
              json['verificationUriComplete'] ??
              json['authorizationUri'] ??
              json['verificationUri'],
        ),
        expiresIn: Duration(seconds: _int(json['expiresIn']) ?? 600),
        // The contract's own examples poll every three seconds; a zero or
        // missing interval would spin.
        interval: Duration(seconds: (_int(json['interval']) ?? 3).clamp(1, 60)),
      );
}

/// Numbers a character summary carries.
class DatacatStats {
  final int chats;
  final int messages;
  final double messagesPerChat;

  const DatacatStats({
    this.chats = 0,
    this.messages = 0,
    this.messagesPerChat = 0,
  });

  factory DatacatStats.fromJson(Map<String, dynamic> json) => DatacatStats(
    chats: _int(json['chats']) ?? 0,
    messages: _int(json['messages']) ?? 0,
    messagesPerChat: _double(json['messagesPerChat']) ?? 0,
  );
}

/// Helpers shared by the readers in the sibling files.
Map<String, dynamic> datacatMap(Object? v) => _map(v);
List<Map<String, dynamic>> datacatMaps(Object? v) => _maps(v);
String datacatString(Object? v) => _str(v);
int? datacatInt(Object? v) => _int(v);
