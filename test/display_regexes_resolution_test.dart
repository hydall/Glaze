import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/preset_repo.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/state/active_regex_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/global_regex_provider.dart';

/// The global scripts behind a load that has not finished yet — which is every
/// cold start, where they come out of SharedPreferences while the chat is
/// already opening. Reading the provider's `.value` in that window is what
/// dropped them from the list the chat's first paint asked for.
class _SlowGlobalRegexNotifier extends GlobalRegexNotifier {
  @override
  Future<List<PresetRegex>> build() async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    return const [
      PresetRegex(
        id: 'global-display',
        name: 'Global card',
        regex: '/CARD/g',
        ephemerality: [1],
      ),
      PresetRegex(
        id: 'global-off',
        name: 'Disabled',
        regex: '/OFF/g',
        ephemerality: [1],
        disabled: true,
      ),
    ];
  }
}

const _presetDisplay = PresetRegex(
  id: 'preset-display',
  name: 'Preset card',
  regex: '/TRK/g',
  ephemerality: [1],
);

const _presetPromptOnly = PresetRegex(
  id: 'preset-prompt-only',
  name: 'Prompt only',
  regex: '/PROMPT/g',
  ephemerality: [2],
);

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await PresetRepo(db).put(
      const Preset(
        id: 'p1',
        name: 'Preset',
        regexes: [_presetDisplay, _presetPromptOnly],
      ),
    );
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        globalRegexProvider.overrideWith(_SlowGlobalRegexNotifier.new),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    return db.close();
  });

  test('the resolved list waits for the global scripts', () async {
    final active = await container.read(activeRegexesProvider.future);

    expect(
      active.map((r) => r.id),
      containsAll(<String>['preset-display', 'global-display']),
      reason: 'a global script must not be dropped because it loaded late',
    );
    expect(active.map((r) => r.id), isNot(contains('global-off')));
  });

  test('the display list is what the first paint can rely on', () async {
    final display = await container.read(displayRegexesProvider.future);

    expect(display.map((r) => r.id), ['preset-display', 'global-display']);
    expect(
      display.map((r) => r.id),
      isNot(contains('preset-prompt-only')),
      reason: 'a prompt-only script has no business in the display pass',
    );
  });
}
