import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_sheet.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_generation_settings_sheet.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';

/// Renders the reworked Memory Books screens to PNG.
///
/// Run with `flutter test --update-goldens test/memory_screens_golden_test.dart`
/// to refresh `test/goldens/*.png`.
Future<ByteData> _font(String path) async =>
    ByteData.view(Uint8List.fromList(File(path).readAsBytesSync()).buffer);

Future<void> _loadFonts() async {
  // Flutter's own icon font, so the glyphs are icons rather than the test
  // font's tofu boxes.
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      _font(
        '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/fl/flutter'}'
        '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    );
  await icons.load();
  final loader = FontLoader('Inter')
    ..addFont(
      File('assets/fonts/InterVariable.ttf').readAsBytes().then(
        (bytes) => ByteData.view(Uint8List.fromList(bytes).buffer),
      ),
    );
  await loader.load();
}

/// Golden tests rasterise real frames, so the baselines only match the machine
/// that produced them — a CI runner with different font hinting would fail on
/// pixels, not on behaviour. They are opt-in:
///
///   GLAZE_GOLDENS=1 flutter test --update-goldens \
///     test/memory_screens_golden_test.dart
final bool _runGoldens = Platform.environment['GLAZE_GOLDENS'] == '1';

const _sessionId = 'session-demo';
const _charId = 'char-demo';

MemoryEntry _entry(
  String id,
  String title,
  String range,
  List<String> keys, {
  String status = 'active',
  int messages = 12,
}) => MemoryEntry(
  id: id,
  title: title,
  content:
      'Спутники добрались до перевала затемно и решили переждать метель '
      'в заброшенной сторожке.',
  keys: keys,
  ledgerRange: range,
  messageIds: List.generate(messages, (i) => 'm$i'),
  status: status,
  createdAt: 1,
);

MemoryDraft _draft(
  String id,
  String title,
  String range, {
  String status = 'pending_approval',
  String content = 'Алла призналась, что знала о письме с самого начала.',
}) => MemoryDraft(
  id: id,
  title: title,
  content: content,
  ledgerRange: range,
  messageIds: const ['m1', 'm2'],
  status: status,
  createdAt: 1,
);

/// A chat that only has to answer "which session is open" — the memory sheet
/// reads nothing else off it at build time.
class _StubChat extends ChatNotifier {
  _StubChat(super.arg);

  @override
  Future<ChatState> build() async => const ChatState(
    session: ChatSession(
      id: _sessionId,
      characterId: _charId,
      sessionIndex: 0,
    ),
  );
}

Future<AppDatabase> _seedDb() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [appDbProvider.overrideWithValue(db)],
  );
  final repo = container.read(memoryBookRepoProvider);
  final book = await repo.ensureForSession(_sessionId);
  await repo.put(
    book.copyWith(
      entries: [
        _entry('e1', 'Переезд в Кестрел', '14–28', ['кестрел', 'дорога']),
        _entry(
          'e2',
          'Договор с гильдией',
          '29–41',
          ['гильдия', 'печать'],
          status: 'needs_rebuild',
        ),
        _entry('e3', 'Первая встреча с Аллой', '1–13', ['алла', 'таверна']),
        _entry('e4', 'Кража в порту', '42–55', ['порт', 'ключ'], messages: 13),
      ],
      pendingDrafts: [
        _draft('d1', 'Ночной разговор у костра', '56–68'),
        _draft(
          'd2',
          '',
          '69–80',
          status: 'pending_generation',
          content: '',
        ),
      ],
    ),
  );
  container.dispose();
  return db;
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required List<Override> overrides,
  Size size = const Size(412, 1000),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: EasyLocalization(
          supportedLocales: const [Locale('en'), Locale('ru')],
          path: 'assets/translations',
          fallbackLocale: const Locale('en'),
          startLocale: const Locale('ru'),
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: AppTheme.dark(
                const ThemePreset(id: 'default', name: 'Default'),
                fontFamily: 'Inter',
              ),
              home: Scaffold(body: child),
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // SheetView measures its header after layout and republishes the height as
    // MediaQuery padding, so the body needs a few frames before the first row
    // clears the header.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
  });
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    await _loadFonts();
  });

  testWidgets('memory books tab', (tester) async {
    final db = await _seedDb();
    addTearDown(db.close);
    await _pump(
      tester,
      const MemorySheet(charId: _charId, initialTab: MemoryTab.books),
      overrides: [
        appDbProvider.overrideWithValue(db),
        vectorSearchAvailableProvider.overrideWithValue(true),
        chatProvider(_charId).overrideWith(() => _StubChat(_charId)),
      ],
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/memory_books_tab.png'),
    );
  }, skip: !_runGoldens);

  testWidgets('memory settings sheet', (tester) async {
    final db = await _seedDb();
    addTearDown(db.close);
    await _pump(
      tester,
      const MemoryGenerationSettingsSheet(
        settings: MemoryBookSettings(),
        sessionId: _sessionId,
      ),
      overrides: [
        appDbProvider.overrideWithValue(db),
        vectorSearchAvailableProvider.overrideWithValue(true),
      ],
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/memory_settings_capture.png'),
    );
  }, skip: !_runGoldens);

  testWidgets('memory books drafts tab', (tester) async {
    final db = await _seedDb();
    addTearDown(db.close);
    await _pump(
      tester,
      const MemorySheet(charId: _charId, initialTab: MemoryTab.books),
      overrides: [
        appDbProvider.overrideWithValue(db),
        vectorSearchAvailableProvider.overrideWithValue(true),
        chatProvider(_charId).overrideWith(() => _StubChat(_charId)),
      ],
    );
    await tester.tap(find.textContaining('(2)'));
    // TabSlideSwitcher holds both bodies while it animates; let it land.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 800));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/memory_books_drafts.png'),
    );
  }, skip: !_runGoldens);

  testWidgets('memory settings scrolled to the collapsed sections', (
    tester,
  ) async {
    final db = await _seedDb();
    addTearDown(db.close);
    await _pump(
      tester,
      const MemoryGenerationSettingsSheet(
        settings: MemoryBookSettings(vectorSearchEnabled: true),
        sessionId: _sessionId,
      ),
      overrides: [
        appDbProvider.overrideWithValue(db),
        vectorSearchAvailableProvider.overrideWithValue(true),
      ],
    );
    await tester.dragUntilVisible(
      find.text('Поиск и совпадения'),
      find.byType(ListView).first,
      const Offset(0, -300),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/memory_settings_advanced.png'),
    );
  }, skip: !_runGoldens);

}
