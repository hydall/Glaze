import 'dart:convert';

import '../../models/extra_request_parameter.dart';

const _reservedRequestKeys = {
  'model',
  'messages',
  'input',
  'contents',
  'system',
  'systemInstruction',
  'stream',
  'tools',
  'tool_choice',
};

void applyExtraRequestParameters(
  Map<String, dynamic> body,
  List<ExtraRequestParameter> parameters,
) {
  for (final parameter in parameters) {
    final key = parameter.key.trim();
    if (!parameter.enabled ||
        key.isEmpty ||
        _reservedRequestKeys.contains(key)) {
      continue;
    }
    body[key] = parseExtraRequestValue(parameter.value);
  }
}

dynamic parseExtraRequestValue(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  try {
    return jsonDecode(trimmed);
  } on FormatException {
    return value;
  }
}

List<ExtraRequestParameter> mergeExtraRequestParameters(
  List<ExtraRequestParameter> base,
  List<ExtraRequestParameter> overrides,
) {
  final merged = <String, ExtraRequestParameter>{};
  for (final parameter in [...base, ...overrides]) {
    final key = parameter.key.trim();
    if (key.isNotEmpty) merged[key] = parameter;
  }
  return merged.values.toList(growable: false);
}
