import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/constants/app_version.dart';
import '../../../chat/composer_text_bridge.dart';
import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';
import 'files_api.dart';

/// `glaze.composer.*`, `glaze.ui.*` and `glaze.app.*`.
Map<String, PluginMethod> uiApi() => {
  'composer.get': const PluginMethod(_get, permission: _composer),
  'composer.set': const PluginMethod(_set, permission: _composer),
  'composer.append': const PluginMethod(_append, permission: _composer),
  'composer.clear': const PluginMethod(_clear, permission: _composer),
  'composer.send': const PluginMethod(_send, permission: _composer),
  'ui.toast': const PluginMethod(_toast),
  'ui.openUrl': const PluginMethod(_openUrl),
  'ui.select': const PluginMethod(_select),
  'ui.ask': const PluginMethod(_ask),
  'ui.preview': const PluginMethod(_preview),
  'app.version': const PluginMethod(_version),
  'app.versionNumber': const PluginMethod(_versionNumber),
};

const _composer = PluginPermission.composer;

ComposerTextAccess _access(PluginCall c) {
  final access = c.host.composer();
  if (access == null) {
    throw const PluginApiError(
      'unavailable',
      'The message box is not available',
    );
  }
  return access;
}

Future<Object?> _get(PluginCall c) async => _access(c).read();

Future<Object?> _set(PluginCall c) async {
  _access(c).write(c.arg(0)?.toString() ?? '');
  return null;
}

Future<Object?> _append(PluginCall c) async {
  final access = _access(c);
  access.write(access.read() + (c.arg(0)?.toString() ?? ''));
  return null;
}

Future<Object?> _clear(PluginCall c) async {
  _access(c).write('');
  return null;
}

Future<Object?> _send(PluginCall c) async {
  final access = _access(c);
  final text = access.read();
  final accepted = await access.send();
  return accepted
      ? {'ok': true, 'text': text}
      : {'ok': false, 'reason': 'rejected', 'text': text};
}

Future<Object?> _toast(PluginCall c) async {
  final text = c.arg(0)?.toString() ?? '';
  if (text.trim().isNotEmpty) c.host.ui.toast(text);
  return null;
}

Future<Object?> _openUrl(PluginCall c) async {
  final url = c.requireString(0, 'url');
  final uri = Uri.tryParse(url);
  if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) {
    throw const PluginApiError(
      'invalid_arguments',
      'Only http(s) links can be opened',
    );
  }
  await c.host.ui.openUrl(url);
  return null;
}

List<PluginOption> _options(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final o in raw)
      if (o is String)
        (value: o, label: o, description: null)
      else if (o is Map && o['value'] != null)
        (
          value: o['value'].toString(),
          label: (o['label'] ?? o['value']).toString(),
          description: o['description']?.toString(),
        ),
  ];
}

Future<Object?> _select(PluginCall c) async {
  final options = _options(c.arg(0));
  if (options.isEmpty) {
    throw const PluginApiError('invalid_arguments', 'select needs options');
  }
  return c.host.ui.select(
    options,
    title: c.arg(1)?.toString(),
    defaultValue: c.arg(2)?.toString(),
  );
}

Future<Object?> _ask(PluginCall c) async {
  final params = c.mapArg(0);
  final question = params['question'];
  if (question is! String || question.trim().isEmpty) {
    throw const PluginApiError('invalid_arguments', 'ask needs a question');
  }
  final options = _options(params['options']);
  final allowOther = params['allowOther'] != false;
  if (!allowOther && options.isEmpty) {
    throw const PluginApiError(
      'invalid_arguments',
      'ask needs options when allowOther is false',
    );
  }
  return c.host.ui.ask(
    question: question,
    options: options,
    allowOther: allowOther,
    placeholder: params['placeholder']?.toString(),
    defaultValue: params['defaultValue']?.toString(),
  );
}

Future<Object?> _preview(PluginCall c) async {
  final source = c.requireString(0, 'source');
  final Uint8List bytes;
  if (source.startsWith('data:')) {
    bytes = UriData.parse(source).contentAsBytes();
  } else if (source.startsWith('http://') || source.startsWith('https://')) {
    bytes = await fetchForPlugin(c, source);
  } else if (source.startsWith('files/')) {
    bytes = await readPluginFile(c, source);
  } else {
    bytes = base64Decode(source);
  }
  await c.host.ui.previewImage(bytes);
  return null;
}

Future<Object?> _version(PluginCall c) async => appVersion;

Future<Object?> _versionNumber(PluginCall c) async {
  final parts = appVersion.split(RegExp(r'[.+-]'));
  int part(int i) => i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0;
  return part(0) * 10000 + part(1) * 100 + part(2);
}
