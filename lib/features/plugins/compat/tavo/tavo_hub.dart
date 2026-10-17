import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../services/plugin_package_reader.dart';

/// Plugin pages of Tavo's public plugin hub: reading what a link points at,
/// downloading the package and asking which installed plugins have a newer
/// version. The hub itself is not browsed in Glaze.
const String kTavoHubSite = 'hub.tavoai.dev';
const String _api = 'https://hub.tavo.cc/api/v1';

final RegExp _slug = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// The plugin a hub link points at (its slug or package id), or null when
/// [uri] is not a hub plugin page. Accepts the site's own paths and the ones
/// it opens inside the app:
/// `/plugins/<slug>`, `/plugins/package/<id>`, `/webview/plugins/…`,
/// `/plugin-market/…`.
String? tavoHubPluginRef(Uri uri) {
  if (uri.scheme != 'https' && uri.scheme != 'http') return null;
  if (uri.host.toLowerCase() != kTavoHubSite) return null;
  var s = uri.pathSegments.where((x) => x.isNotEmpty).toList();
  if (s.isNotEmpty && s.first == 'webview') s = s.sublist(1);
  if (s.isEmpty || (s.first != 'plugins' && s.first != 'plugin-market')) {
    return null;
  }
  s = s.sublist(1);
  if (s.length == 2 && s.first == 'package') s = s.sublist(1);
  if (s.length != 1 || !_slug.hasMatch(s.single)) return null;
  return s.single;
}

/// What the hub says about one plugin.
class TavoHubPlugin {
  const TavoHubPlugin({
    required this.slug,
    required this.packageId,
    required this.name,
    required this.version,
    this.author,
    this.description,
    this.changelog,
    this.iconUrl,
    this.downloads,
    this.updatedAt,
    this.free = true,
    this.safety,
  });

  factory TavoHubPlugin.fromJson(Map<String, dynamic> json) {
    String? str(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
    final version = str(json['published_version']);
    final versions = json['versions'];
    final current = versions is List
        ? versions.whereType<Map<String, dynamic>>().where(
            (v) => v['version'] == version,
          )
        : const <Map<String, dynamic>>[];
    final review = json['review'];
    final safety = review is Map ? review['safety'] : null;
    final creator = json['creator'];
    return TavoHubPlugin(
      slug: str(json['slug']) ?? '',
      packageId: str(json['package_id']) ?? '',
      name: str(json['name']) ?? str(json['package_id']) ?? '',
      version: version ?? '',
      author:
          str(json['author']) ??
          (creator is Map ? str(creator['name']) : null) ??
          str(json['creator_name']),
      description: str(json['description']) ?? str(json['summary']),
      changelog: current.isEmpty ? null : str(current.first['changelog']),
      iconUrl: str(json['icon_url']),
      downloads: (json['download_count'] as num?)?.toInt(),
      updatedAt: DateTime.tryParse(
        str(json['published_at']) ?? str(json['updated_at']) ?? '',
      ),
      free: (json['access_type'] ?? 'free') == 'free',
      safety: safety is Map ? str(safety['verdict']) : null,
    );
  }

  final String slug;
  final String packageId;
  final String name;
  final String version;
  final String? author;
  final String? description;

  /// What changed in [version].
  final String? changelog;
  final String? iconUrl;
  final int? downloads;
  final DateTime? updatedAt;

  /// Whether the hub hands the package out without a purchase.
  final bool free;

  /// The hub's own safety review of [version]: `pass`, `warn`, `fail`.
  final String? safety;

  Uri get pageUrl => Uri.https(kTavoHubSite, '/plugins/$slug');
}

class TavoHubException implements Exception {
  const TavoHubException(this.message);
  final String message;
  @override
  String toString() => message;
}

class TavoHubClient {
  TavoHubClient([Dio? dio])
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
            ),
          );

  final Dio _dio;

  Future<Map<String, dynamic>> _json(String path, {Object? body}) async {
    final Response<dynamic> res;
    try {
      res = await _dio.request<dynamic>(
        '$_api/$path',
        data: body,
        options: Options(
          method: body == null ? 'GET' : 'POST',
          responseType: ResponseType.json,
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw TavoHubException(e.message ?? '$e');
    }
    final data = res.data;
    if (res.statusCode == 404) {
      throw const TavoHubException('The plugin is not on the hub');
    }
    if (res.statusCode != 200 || data is! Map) {
      final error = data is Map ? data['error'] : null;
      throw TavoHubException(
        error is Map && error['message'] is String
            ? error['message'] as String
            : 'The hub answered ${res.statusCode}',
      );
    }
    return Map<String, dynamic>.from(data);
  }

  /// The plugin behind a slug or package id, as [tavoHubPluginRef] returns.
  Future<TavoHubPlugin> plugin(String ref) async {
    final plugin = TavoHubPlugin.fromJson(
      await _json('plugins/${Uri.encodeComponent(ref)}'),
    );
    if (plugin.slug.isEmpty || plugin.packageId.isEmpty) {
      throw const TavoHubException('The hub sent an incomplete plugin');
    }
    return plugin;
  }

  /// The published version of each of [packageIds] the hub knows, by id.
  Future<Map<String, TavoHubPlugin>> lookup(Iterable<String> packageIds) async {
    final ids = packageIds.toSet().toList();
    if (ids.isEmpty) return const {};
    final json = await _json('plugins/lookup', body: {'package_ids': ids});
    final items = json['items'];
    return {
      if (items is List)
        for (final item in items.whereType<Map<String, dynamic>>())
          if (item['plugin'] is Map)
            item['package_id'] as String: TavoHubPlugin.fromJson(
              Map<String, dynamic>.from(item['plugin'] as Map),
            ),
    };
  }

  /// Downloads the published package of [plugin] and checks it against the
  /// checksum the hub gives for it.
  Future<Uint8List> download(TavoHubPlugin plugin) async {
    final info = await _json(
      'plugins/${Uri.encodeComponent(plugin.slug)}/download-url',
    );
    final url = Uri.tryParse('${info['url']}');
    final sha = '${info['sha256']}'.toLowerCase();
    if (url == null || !isTavoHubDownloadUrl(url)) {
      throw const TavoHubException('The hub sent an unexpected download link');
    }
    final out = BytesBuilder(copy: false);
    try {
      final res = await _dio.getUri<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (s) => s == 200,
        ),
      );
      await for (final chunk in res.data!.stream) {
        out.add(chunk);
        // Stopped as it streams: a package is never allowed past this.
        if (out.length > kMaxPluginPackageBytes) {
          throw const TavoHubException('The plugin package is too large');
        }
      }
    } on DioException catch (e) {
      throw TavoHubException(e.message ?? '$e');
    }
    final bytes = out.takeBytes();
    if (sha256.convert(bytes).toString() != sha) {
      throw const TavoHubException('The downloaded package is damaged');
    }
    return bytes;
  }
}

/// Packages come only from the hub's own hosts, over https.
bool isTavoHubDownloadUrl(Uri url) {
  final host = url.host.toLowerCase();
  return url.scheme == 'https' &&
      (host == 'tavoai.dev' ||
          host.endsWith('.tavoai.dev') ||
          host == 'tavo.cc' ||
          host.endsWith('.tavo.cc'));
}

/// Whether [a] is a later version than [b]: dotted numbers compared in
/// turn, a pre-release before its release.
bool isNewerPluginVersion(String a, String b) {
  List<int> parts(String v) => [
    for (final x in v.split(RegExp(r'[-+]')).first.split('.'))
      int.tryParse(x) ?? 0,
  ];
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < pa.length || i < pb.length; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x > y;
  }
  return !a.contains('-') && b.split('+').first.contains('-');
}
