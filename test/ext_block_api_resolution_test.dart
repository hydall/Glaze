import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/features/extensions/services/info_block_service.dart';

/// The block, preset and LLM-tab connections are tried in that order, and an
/// empty id at either level is the editor's "Use selected LLM connection".
void main() {
  const active = ApiConfig(id: 'active', name: 'Active');
  const preset = ApiConfig(id: 'preset', name: 'Preset');
  const block = ApiConfig(id: 'block', name: 'Block');
  const all = [active, preset, block];

  test('the block\'s own connection wins', () {
    final resolved = resolveBlockApiConfig(
      blockApiConfigId: 'block',
      presetApiConfigId: 'preset',
      allConfigs: all,
      activeFallback: active,
    );
    expect(resolved?.id, 'block');
  });

  test('an empty block id follows the preset', () {
    final resolved = resolveBlockApiConfig(
      blockApiConfigId: '',
      presetApiConfigId: 'preset',
      allConfigs: all,
      activeFallback: active,
    );
    expect(resolved?.id, 'preset');
  });

  test('both empty follows the selected LLM connection', () {
    final resolved = resolveBlockApiConfig(
      blockApiConfigId: '',
      presetApiConfigId: '',
      allConfigs: all,
      activeFallback: active,
    );
    expect(resolved?.id, 'active');
  });

  test('a deleted block id falls through to the selection', () {
    final resolved = resolveBlockApiConfig(
      blockApiConfigId: 'gone',
      presetApiConfigId: 'also-gone',
      allConfigs: all,
      activeFallback: active,
    );
    expect(resolved?.id, 'active');
  });

  test('no selection at all is the only failure', () {
    final resolved = resolveBlockApiConfig(
      blockApiConfigId: '',
      presetApiConfigId: '',
      allConfigs: all,
      activeFallback: null,
    );
    expect(resolved, isNull);
  });
}
