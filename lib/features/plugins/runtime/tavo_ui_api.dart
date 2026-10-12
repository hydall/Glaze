import '../../../core/constants/app_version.dart';
import '../../chat/composer_text_bridge.dart';
import 'tavo_call.dart';
import 'tavo_host.dart';

/// `tavo.input.*`, `tavo.utils.*`, `tavo.app.*`, `tavo.generate`.
Map<String, TavoMethod> tavoUiMethods() => {
  'input.get': const TavoMethod(_inputGet, permission: 'input'),
  'input.set': const TavoMethod(_inputSet, permission: 'input'),
  'input.append': const TavoMethod(_inputAppend, permission: 'input'),
  'input.clear': const TavoMethod(_inputClear, permission: 'input'),
  'input.send': const TavoMethod(_inputSend, permission: 'input'),
  'utils.toast': const TavoMethod(_toast),
  'utils.openUrl': const TavoMethod(_openUrl),
  'utils.select': const TavoMethod(_select),
  'utils.ask': const TavoMethod(_ask),
  'app.version': const TavoMethod(_version),
  'app.versionNumber': const TavoMethod(_versionNumber),
  'generate': const TavoMethod(_generate, permission: 'generate'),
};

ComposerTextAccess _composer(TavoCall c) {
  final access = c.host.composer();
  if (access == null) {
    throw const TavoError(
      'runtime_unavailable',
      'The chat input is not available',
    );
  }
  return access;
}

Future<Object?> _inputGet(TavoCall c) async => _composer(c).read();

Future<Object?> _inputSet(TavoCall c) async {
  _composer(c).write(c.arg(0)?.toString() ?? '');
  return null;
}

Future<Object?> _inputAppend(TavoCall c) async {
  final composer = _composer(c);
  composer.write(composer.read() + (c.arg(0)?.toString() ?? ''));
  return null;
}

Future<Object?> _inputClear(TavoCall c) async {
  _composer(c).write('');
  return null;
}

Future<Object?> _inputSend(TavoCall c) async {
  final composer = _composer(c);
  final text = composer.read();
  final accepted = await composer.send();
  return accepted
      ? {'ok': true, 'text': text}
      : {'ok': false, 'reason': 'rejected', 'text': text};
}

Future<Object?> _toast(TavoCall c) async {
  final text = c.arg(0)?.toString() ?? '';
  if (text.trim().isNotEmpty) c.host.toast(text);
  return null;
}

Future<Object?> _openUrl(TavoCall c) async {
  final url = c.requireString(0, 'url');
  final uri = Uri.tryParse(url);
  if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) {
    throw const TavoError(
      'invalid_arguments',
      'Only http(s) URLs can be opened',
    );
  }
  await c.host.openUrl(url);
  return null;
}

List<TavoOption> _options(Object? raw) {
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

Future<Object?> _select(TavoCall c) async {
  final options = _options(c.arg(0));
  if (options.isEmpty) {
    throw const TavoError('invalid_arguments', 'select needs options');
  }
  return c.host.select(
    options,
    title: c.arg(1)?.toString(),
    defaultValue: c.arg(2)?.toString(),
  );
}

Future<Object?> _ask(TavoCall c) async {
  final params = c.mapArg(0);
  final question = params['question'];
  if (question is! String || question.trim().isEmpty) {
    throw const TavoError('invalid_arguments', 'ask needs a question');
  }
  final options = _options(params['options']);
  final allowOther = params['allowOther'] != false;
  if (!allowOther && options.isEmpty) {
    throw const TavoError(
      'invalid_arguments',
      'ask needs options when allowOther is false',
    );
  }
  return c.host.ask(
    question: question,
    options: options,
    allowOther: allowOther,
    placeholder: params['placeholder']?.toString(),
    defaultValue: params['defaultValue']?.toString(),
  );
}

Future<Object?> _version(TavoCall c) async => appVersion;

Future<Object?> _versionNumber(TavoCall c) async {
  final parts = appVersion.split(RegExp(r'[.+-]'));
  int part(int i) => i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0;
  return part(0) * 10000 + part(1) * 100 + part(2);
}

Future<Object?> _generate(TavoCall c) async {
  final prompt = c.requireString(0, 'prompt');
  return c.host.generate(prompt, c.mapArg(1));
}
