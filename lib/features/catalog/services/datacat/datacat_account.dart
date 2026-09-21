import 'package:shared_preferences/shared_preferences.dart';

import 'datacat_client.dart';
import 'datacat_errors.dart';
import 'datacat_models.dart';

/// Linking a DataCat account to this installation, via the device flow.
///
/// Only community writes need this — browsing, tags, creators and card
/// transfers all work without an account. So nothing here is on a startup path:
/// the link is made when the user asks for it, and its absence is a reason to
/// hide the kudos button, not to fail a request.

const _keyUserToken = 'gz_dc_user_token';
const _keyUserName = 'gz_dc_user_name';
const _keyScopes = 'gz_dc_scopes';

/// The stored `dcv1_…` token, or null when no account is linked.
///
/// Kept in preferences beside the installation id it is bound to: the token is
/// only usable from this installation, so it is worth exactly nothing anywhere
/// else — which is also why it does not go through the card-transfer lease's
/// memory-only treatment.
Future<String?> datacatUserToken() async {
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString(_keyUserToken);
  return (token == null || token.isEmpty) ? null : token;
}

Future<String?> datacatLinkedName() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_keyUserName);
}

Future<List<String>> datacatGrantedScopes() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getStringList(_keyScopes) ?? const [];
}

Future<void> _storeLink({
  required String token,
  String? name,
  List<String> scopes = const [],
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_keyUserToken, token);
  await prefs.setStringList(_keyScopes, scopes);
  if (name != null && name.isNotEmpty) {
    await prefs.setString(_keyUserName, name);
  } else {
    await prefs.remove(_keyUserName);
  }
}

Future<void> _clearLink() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_keyUserToken);
  await prefs.remove(_keyUserName);
  await prefs.remove(_keyScopes);
}

/// Starts the device flow. The user approves it on the hosted page the returned
/// flow points at; nothing is linked until [awaitDatacatLink] succeeds.
Future<DatacatDeviceFlow> startDatacatLink() async {
  final data = await datacatPost(
    '/account-links',
    // `installationId` is a required body field, and `clientName` is what the
    // user sees on the approval page.
    body: await datacatDeviceBody(),
  );
  final flow = DatacatDeviceFlow.fromJson(data);
  if (flow.id.isEmpty || flow.uri.isEmpty) {
    throw const DatacatApiException(
      status: 0,
      message: 'DataCat did not return a link request',
    );
  }
  return flow;
}

/// Waits for the user to approve [flow], then stores the token it yields.
///
/// Same shape as the verification exchange: a `409` is the server saying "not
/// approved yet", which is the normal state for most of this loop, so it waits
/// rather than failing. A `410` is the link expiring, which no amount of
/// waiting fixes.
Future<DatacatAccountStatus> awaitDatacatLink(
  DatacatDeviceFlow flow, {
  bool Function()? isCancelled,
}) async {
  final deadline = DateTime.now().add(flow.expiresIn);

  while (DateTime.now().isBefore(deadline)) {
    if (isCancelled?.call() ?? false) {
      throw const DatacatApiException(status: 0, message: 'Linking cancelled');
    }
    await Future<void>.delayed(flow.interval);

    try {
      final data = await datacatPost(
        '/account-links/${flow.id}/token',
        body: await datacatDeviceBody({'deviceCode': flow.deviceCode}),
      );
      final token = datacatString(data['accessToken']);
      if (token.isEmpty) continue;

      final account = datacatMap(data['account']);
      final displayName = datacatString(account['displayName']).isNotEmpty
          ? datacatString(account['displayName'])
          : datacatString(account['username']);
      final scopes = (data['scopes'] as List?)
          ?.map(datacatString)
          .where((s) => s.isNotEmpty)
          .toList();
      await _storeLink(
        token: token,
        name: displayName,
        scopes: scopes ?? const [],
      );
      // The exchange already says everything the status endpoint would, and it
      // is the only place the granted scopes are reported.
      return DatacatAccountStatus(
        accountState: datacatString(data['accountState']),
        boundToAccountToken: true,
        displayName: displayName.isEmpty ? null : displayName,
        scopes: scopes ?? const [],
      );
    } on DatacatApiException catch (e) {
      if (e.isConflict) continue;
      rethrow;
    }
  }

  throw const DatacatApiException(
    status: 410,
    message: 'The link request expired',
  );
}

/// Where this installation stands: linked or not, and under which rate tier.
///
/// Reads the server rather than the stored token, so a token revoked from the
/// website shows up as unlinked here instead of as a mystery 401 on the next
/// kudos. The granted scopes are not part of this answer — only the token
/// exchange reports them — so the stored set is carried through. A failed read
/// reports what is stored rather than claiming nothing is linked: a network
/// blip is not a logout.
Future<DatacatAccountStatus> datacatAccountStatus() async {
  final token = await datacatUserToken();
  final scopes = await datacatGrantedScopes();
  try {
    final data = await datacatGet(
      '/account/status',
      auth: DatacatAuth(userToken: token, withInstallationId: true),
    );
    final status = DatacatAccountStatus.fromJson(data, scopes: scopes);
    if (token != null && !status.linked) await _clearLink();
    return status;
  } on DatacatApiException catch (e) {
    if (e.isUnauthorized) {
      await _clearLink();
      return const DatacatAccountStatus();
    }
    return DatacatAccountStatus(
      // Unreachable, not unlinked: keep showing what is stored.
      accountState: token == null ? 'unlinked' : 'logged_in',
      displayName: await datacatLinkedName(),
      scopes: scopes,
    );
  }
}

/// Revokes the linked token server-side and forgets it locally.
///
/// The local half runs whatever the server says: a token the server has already
/// dropped is still a token this installation must stop sending.
Future<void> datacatUnlink() async {
  final token = await datacatUserToken();
  if (token != null) {
    try {
      await datacatDelete(
        '/account',
        auth: DatacatAuth(userToken: token, withInstallationId: true),
      );
    } catch (_) {}
  }
  await _clearLink();
}
