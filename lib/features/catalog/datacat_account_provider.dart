import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services/datacat/datacat_account.dart';
import 'services/datacat/datacat_models.dart';

/// The DataCat account linked to this installation, as the UI sees it.
///
/// Linking exists for one reason: kudos and comments are attributed to a
/// logged-in account. Everything else DataCat is used for works without it, so
/// nothing here blocks startup and an unlinked state is a normal, permanent
/// one — not an error to recover from.
class DatacatAccount {
  /// DataCat's own three-way answer: `unlinked`, `linked_anonymous` or
  /// `logged_in`.
  final String accountState;

  final String? displayName;
  final List<String> scopes;

  /// True while the link is being established or read.
  final bool busy;

  const DatacatAccount({
    this.accountState = 'unlinked',
    this.displayName,
    this.scopes = const [],
    this.busy = false,
  });

  /// Whether this installation is attached to DataCat at all.
  bool get linked => accountState.isNotEmpty && accountState != 'unlinked';

  /// Whether a real account stands behind the link. An installation can be
  /// linked anonymously, which reads fine but cannot post.
  bool get loggedIn => accountState == 'logged_in';

  /// Whether kudos and comments can actually be sent. Three things have to
  /// hold: linked, to a logged-in account, with the write scope approved — and
  /// a button that always fails is worse than no button.
  bool get canWrite => loggedIn && scopes.contains('community:write');

  DatacatAccount copyWith({
    String? accountState,
    String? displayName,
    List<String>? scopes,
    bool? busy,
  }) => DatacatAccount(
    accountState: accountState ?? this.accountState,
    displayName: displayName ?? this.displayName,
    scopes: scopes ?? this.scopes,
    busy: busy ?? this.busy,
  );
}

class DatacatAccountNotifier extends Notifier<DatacatAccount> {
  @override
  DatacatAccount build() {
    _loadStored();
    return const DatacatAccount();
  }

  /// Shows what is stored immediately, without a round-trip. The server is
  /// only asked when the user opens the account screen — a launch must not
  /// spend a request on a feature most sessions never touch.
  ///
  /// A stored token means the link survived, so it is shown as logged in until
  /// a real status read says otherwise; the alternative is a screen that says
  /// "not linked" for a second on every launch.
  Future<void> _loadStored() async {
    final token = await datacatUserToken();
    if (token == null) return;
    state = DatacatAccount(
      accountState: 'logged_in',
      displayName: await datacatLinkedName(),
      scopes: await datacatGrantedScopes(),
    );
  }

  /// Re-reads the link from the server, so a token revoked on the website
  /// stops being shown as linked here.
  Future<void> refresh() async {
    state = state.copyWith(busy: true);
    try {
      _apply(await datacatAccountStatus());
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// Applies the outcome of a completed device flow.
  void applyStatus(DatacatAccountStatus status) => _apply(status);

  void _apply(DatacatAccountStatus status) {
    state = DatacatAccount(
      accountState: status.accountState,
      displayName: status.displayName,
      // The status endpoint does not report scopes; only the token exchange
      // does, so a refresh must not erase what linking established.
      scopes: status.scopes.isEmpty ? state.scopes : status.scopes,
    );
  }

  Future<void> unlink() async {
    state = state.copyWith(busy: true);
    try {
      await datacatUnlink();
      state = const DatacatAccount();
    } catch (_) {
      state = state.copyWith(busy: false);
    }
  }
}

final datacatAccountProvider =
    NotifierProvider<DatacatAccountNotifier, DatacatAccount>(
      DatacatAccountNotifier.new,
    );
