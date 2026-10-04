import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/constants/app_version.dart';
import '../catalog_http.dart';
import 'datacat_errors.dart';

/// Base of DataCat's official, versioned Client API.
const datacatApiBase = 'https://datacat.run/api/client/v1';

/// The integration's public Client ID, sent as `X-Datacat-Client-Id`.
///
/// Public and copyable by design — it identifies the integration, it does not
/// authorise it, so shipping it in the app is what DataCat intends. The secret
/// half (a `dca1_…` developer token) is deliberately absent: it proves a
/// request came from the approved integration without a user, so anyone who
/// extracted it from the app would be able to spend this integration's quota
/// under its identity. No read path, no card transfer and no account linking
/// needs one, and if a server-side proxy is ever introduced the token belongs
/// there.
///
/// Empty until DataCat issues a key. A `--dart-define=DATACAT_CLIENT_ID=…`
/// fills it in for a build without touching the source.
const _compiledClientId = String.fromEnvironment(
  'DATACAT_CLIENT_ID',
  defaultValue: '',
);

String? _clientIdOverride;

/// The client id this build sends. Compiled in, unless a test replaced it.
String get datacatClientId => _clientIdOverride ?? _compiledClientId;

/// Stands in for the compiled client id, so the request shaping can be tested
/// in a build that has no key. Mirrors `setCatalogHttpAdapter`: the value is a
/// compile-time constant on purpose, and this is the one seam that admits it.
@visibleForTesting
void setDatacatClientId(String? id) => _clientIdOverride = id;

/// Whether the app can talk to the Client API at all. False ships a DataCat
/// catalog that explains itself instead of failing per request.
bool get datacatConfigured => datacatClientId.isNotEmpty;

/// Stable per-installation identifier, 16–160 chars.
///
/// The same value the old anonymous session flow used as its device token: one
/// installation, one id. Non-secret — it binds a linked user token to this
/// installation, it does not authenticate anything on its own.
const _keyInstallationId = 'gz_dc_device';

String _uuid() {
  final r = Random();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replaceAllMapped(RegExp('[xy]'), (
    m,
  ) {
    final v = r.nextInt(16);
    return (m.group(0) == 'x' ? v : (v & 0x3 | 0x8)).toRadixString(16);
  });
}

/// Name DataCat shows the user on the hosted link and verification pages, so
/// they can see which app is asking before they approve it.
const datacatClientName = 'Glaze';

/// The body every device-flow POST has to carry.
///
/// `installationId` is a required *body* field on all four of them — starting a
/// link or a verification, and exchanging either for a token — not merely a
/// header. Sending only the header is a 400, which is what made every one of
/// these flows fail before the contract was read properly.
Future<Map<String, dynamic>> datacatDeviceBody([
  Map<String, dynamic> extra = const {},
]) async => {
  'installationId': await datacatInstallationId(),
  'clientName': datacatClientName,
  'clientVersion': appVersion,
  ...extra,
};

Future<String> datacatInstallationId() async {
  final prefs = await SharedPreferences.getInstance();
  var id = prefs.getString(_keyInstallationId);
  if (id == null) {
    id = _uuid();
    await prefs.setString(_keyInstallationId, id);
  }
  // The contract requires 16–160 chars of `[A-Za-z0-9._:-]`. A UUID satisfies
  // both, but an id inherited from the old anonymous device token might not,
  // and a rejected installation id fails every device flow with a 400.
  return _validInstallationId(id) ? id : _replaceInstallationId(prefs);
}

bool _validInstallationId(String id) =>
    id.length >= 16 &&
    id.length <= 160 &&
    RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(id);

Future<String> _replaceInstallationId(SharedPreferences prefs) async {
  final id = _uuid();
  await prefs.setString(_keyInstallationId, id);
  return id;
}

/// What a request carries besides the client id.
///
/// The three credentials are independent: a discovery call needs none of them,
/// a protected transfer needs [lease], and a community write needs
/// [userToken] together with the installation id.
class DatacatAuth {
  /// A linked user's `dcv1_…` bearer token, for calls made as that account.
  final String? userToken;

  /// A short-lived transfer lease from the human-verification flow.
  final String? lease;

  /// Whether to send the installation id. Required alongside [userToken].
  final bool withInstallationId;

  const DatacatAuth({
    this.userToken,
    this.lease,
    this.withInstallationId = false,
  });

  static const none = DatacatAuth();
}

Future<Map<String, String>> datacatHeaders(DatacatAuth auth) async {
  final headers = <String, String>{
    'Accept': 'application/json',
    if (datacatClientId.isNotEmpty) 'X-Datacat-Client-Id': datacatClientId,
  };
  if (auth.userToken != null) {
    headers['Authorization'] = 'Bearer ${auth.userToken}';
  }
  if (auth.lease != null) {
    headers['X-Datacat-Verification-Lease'] = auth.lease!;
  }
  if (auth.withInstallationId || auth.userToken != null) {
    headers['X-Datacat-Installation-Id'] = await datacatInstallationId();
  }
  return headers;
}

/// Builds `$datacatApiBase$path?query`, dropping null and empty values.
///
/// Every list parameter the API takes is comma-separated rather than repeated,
/// so a `List` value is joined rather than encoded once per element.
String datacatUrl(String path, [Map<String, Object?> query = const {}]) {
  final parts = <String>[];
  query.forEach((key, value) {
    if (value == null) return;
    final text = value is Iterable ? value.join(',') : value.toString();
    if (text.isEmpty) return;
    parts.add('$key=${Uri.encodeQueryComponent(text)}');
  });
  return parts.isEmpty
      ? '$datacatApiBase$path'
      : '$datacatApiBase$path?${parts.join('&')}';
}

/// Refuses a request the integration has no client id for.
///
/// Without one the server answers every scoped call the same way, so the
/// catalog would show a bare `HTTP 401` that reads as a fault rather than as a
/// build that was never given a key. Raised before the request so the grid can
/// say what is actually missing.
void _requireClientId() {
  if (datacatConfigured) return;
  throw DatacatApiException(
    status: 0,
    code: 'client_id_missing',
    message: 'catalog_datacat_no_client_id'.tr(),
  );
}

/// A GET against the Client API, with every failure reported as a
/// [DatacatApiException].
Future<Map<String, dynamic>> datacatGet(
  String path, {
  Map<String, Object?> query = const {},
  DatacatAuth auth = DatacatAuth.none,
}) async {
  _requireClientId();
  try {
    return await catalogGet(datacatUrl(path, query), await datacatHeaders(auth));
  } catch (e) {
    throw datacatError(e);
  }
}

Future<Map<String, dynamic>> datacatPost(
  String path, {
  Map<String, dynamic> body = const {},
  Map<String, Object?> query = const {},
  DatacatAuth auth = DatacatAuth.none,
}) async {
  _requireClientId();
  try {
    return await catalogPost(
      datacatUrl(path, query),
      body,
      await datacatHeaders(auth),
    );
  } catch (e) {
    throw datacatError(e);
  }
}

/// A DELETE against the Client API. Answers 204 with no body, so the result is
/// whatever JSON came back (usually nothing) rather than something to read.
Future<void> datacatDelete(
  String path, {
  Map<String, Object?> query = const {},
  DatacatAuth auth = DatacatAuth.none,
}) async {
  _requireClientId();
  try {
    await catalogDelete(datacatUrl(path, query), await datacatHeaders(auth));
  } catch (e) {
    throw datacatError(e);
  }
}

/// Image bytes from an endpoint that streams a picture instead of JSON.
Future<List<int>> datacatGetBytes(
  String path, {
  Map<String, Object?> query = const {},
  DatacatAuth auth = DatacatAuth.none,
}) async {
  _requireClientId();
  try {
    return await catalogGetBytes(
      datacatUrl(path, query),
      await datacatHeaders(auth),
    );
  } catch (e) {
    throw datacatError(e);
  }
}
