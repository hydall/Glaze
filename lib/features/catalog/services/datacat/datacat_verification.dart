import 'dart:async';

import 'datacat_client.dart';
import 'datacat_errors.dart';
import 'datacat_models.dart';

/// The action a transfer lease is issued for. Currently the only one.
const datacatTransferAction = 'character_transfer';

/// How many distinct characters one lease covers when the server does not say.
/// The live figure arrives as `maxUniqueCharacters` on the lease itself.
const datacatLeaseCharacterBudget = 20;

/// Holds the short-lived transfer lease between downloads.
///
/// A lease is what DataCat issues after a human-verification challenge, and it
/// is deliberately cheap to reuse: one covers a number of distinct characters
/// until it expires, so a batch import asks the user to verify once rather than
/// once per card. The budget is counted in distinct characters, not requests —
/// fetching the same character's card and then its image spends one slot, and a
/// retry spends none.
///
/// In memory only. A lease outlives neither the process nor its own expiry, so
/// persisting one would only ever hand back something already dead.
class DatacatLeaseStore {
  DatacatLeaseStore._();
  static final DatacatLeaseStore instance = DatacatLeaseStore._();

  String? _token;
  DateTime? _expiresAt;
  int _budget = datacatLeaseCharacterBudget;
  final _characters = <String>{};

  /// A lease that can still be spent on [characterId], or null when one has to
  /// be obtained.
  ///
  /// Expiry is checked against a margin rather than the exact instant: a lease
  /// with two seconds left is one the server will have retired by the time the
  /// request lands, and spending the user's verification on a guaranteed
  /// rejection is worse than asking a moment early.
  String? leaseFor(String characterId) {
    final token = _token;
    final expiry = _expiresAt;
    if (token == null || expiry == null) return null;
    if (DateTime.now().isAfter(expiry.subtract(const Duration(seconds: 10)))) {
      return null;
    }
    if (!_characters.contains(characterId) && _characters.length >= _budget) {
      return null;
    }
    return token;
  }

  void store(String token, DateTime expiresAt, {int? maxUniqueCharacters}) {
    _token = token;
    _expiresAt = expiresAt;
    _budget = maxUniqueCharacters ?? datacatLeaseCharacterBudget;
    _characters.clear();
  }

  /// Records that [characterId] was transferred under the current lease.
  void noteUsed(String characterId) => _characters.add(characterId);

  /// Drops the lease, so the next transfer verifies again. Called when the
  /// server rejects one we believed was live.
  void invalidate() {
    _token = null;
    _expiresAt = null;
    _budget = datacatLeaseCharacterBudget;
    _characters.clear();
  }

  /// How many of the current lease's character slots are left.
  int get remainingBudget =>
      _token == null ? 0 : _budget - _characters.length;
}

/// Starts a hosted human-verification challenge.
///
/// The app never solves the challenge itself: the server hands back a URL that
/// already carries the device code, and the flow is finished by loading that
/// page. Doing the Turnstile exchange directly would mean shipping the site key
/// handling and the widget, and the contract says integrations should open the
/// hosted URL instead.
Future<DatacatDeviceFlow> startDatacatVerification({
  String action = datacatTransferAction,
}) async {
  final data = await datacatPost(
    '/verifications',
    body: await datacatDeviceBody({'action': action}),
  );
  final flow = DatacatDeviceFlow.fromJson(data);
  if (flow.id.isEmpty || flow.uri.isEmpty) {
    throw const DatacatApiException(
      status: 0,
      message: 'DataCat did not return a verification challenge',
    );
  }
  return flow;
}

/// Whether the challenge behind [flow] has been solved yet.
///
/// Public and unauthenticated, and only ever advisory: the token exchange is
/// what actually decides, so this exists to describe a pending challenge, not
/// to gate one.
Future<bool> datacatVerificationSolved(DatacatDeviceFlow flow) async {
  final data = await datacatGet('/verifications/${flow.id}');
  final status = datacatString(
    datacatMap(data['verification'])['status'] ?? data['status'],
  ).toLowerCase();
  return status == 'verified' || status == 'exchanged';
}

/// Exchanges a solved challenge for a lease, and stores it.
///
/// Polls at the interval the server asked for until the challenge is solved or
/// [flow] expires. The exchange is what decides: a `409` means the challenge is
/// not in the required state yet, so it is a reason to wait rather than an
/// error to report, while a `410` means it is gone and waiting cannot help.
Future<String> awaitDatacatLease(
  DatacatDeviceFlow flow, {
  DatacatLeaseStore? store,
  bool Function()? isCancelled,
}) async {
  final deadline = DateTime.now().add(flow.expiresIn);
  final leases = store ?? DatacatLeaseStore.instance;

  while (DateTime.now().isBefore(deadline)) {
    if (isCancelled?.call() ?? false) {
      throw const DatacatApiException(
        status: 0,
        message: 'Verification cancelled',
      );
    }
    await Future<void>.delayed(flow.interval);

    try {
      final data = await datacatPost(
        '/verifications/${flow.id}/token',
        body: await datacatDeviceBody({'deviceCode': flow.deviceCode}),
      );
      final token = datacatString(data['leaseToken']);
      if (token.isEmpty) continue;
      leases.store(
        token,
        // The lease states an absolute expiry, not a duration. A clock that
        // cannot parse it is not a reason to treat the lease as immortal, so
        // it falls back to the shortest sensible life.
        DateTime.tryParse(datacatString(data['expiresAt']))?.toLocal() ??
            DateTime.now().add(const Duration(minutes: 5)),
        maxUniqueCharacters: datacatInt(data['maxUniqueCharacters']),
      );
      return token;
    } on DatacatApiException catch (e) {
      // Not solved yet — keep waiting. Anything else is final.
      if (e.isConflict) continue;
      rethrow;
    }
  }

  throw const DatacatApiException(
    status: 410,
    message: 'The verification challenge expired',
  );
}
