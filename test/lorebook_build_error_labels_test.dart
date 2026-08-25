import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/catalog_error_labels.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_lorebook_rebuilder.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_webview_proxy.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';

/// Localization is not initialized here, so `.tr()` returns the key itself —
/// which is what the label assertions match against.
DioException _http(int status, Object? body) => DioException(
  requestOptions: RequestOptions(path: '/chat/completions'),
  response: Response<dynamic>(
    requestOptions: RequestOptions(path: '/chat/completions'),
    statusCode: status,
    data: body,
  ),
  type: DioExceptionType.badResponse,
);

void main() {
  group('describeCatalogError', () {
    test('renders a provider HTTP failure like the rest of the app', () {
      final labelled = describeCatalogError(
        _http(401, {
          'error': {'message': 'Invalid API key'},
        }),
        fallback: CatalogErrorSource.provider,
      );

      expect(labelled.source, CatalogErrorSource.provider);
      expect(labelled.message, 'HTTP 401: Invalid API key');
      // Never the raw Dio dump the sheet used to show.
      expect(labelled.message, isNot(contains('DioException')));
      expect(labelled.label, 'error_source_provider');
    });

    test('a Janitor.AI failure is labelled as theirs, not the provider', () {
      final labelled = describeCatalogError(
        const JanitorAuthException(),
        fallback: CatalogErrorSource.provider,
      );

      expect(labelled.source, CatalogErrorSource.janitor);
      expect(labelled.label, 'error_source_janitor');
      expect(labelled.message, 'catalog_janitor_session_expired');
    });

    test('a refusal keeps JanitorAI wording under the Janitor label', () {
      final labelled = describeCatalogError(
        const JanitorRefusedException.proxyForbidden(),
        fallback: CatalogErrorSource.provider,
      );

      expect(labelled.source, CatalogErrorSource.janitor);
      expect(labelled.message, startsWith('Proxies are forbidden'));
    });

    test('a build failure carries its own source through', () {
      final labelled = describeCatalogError(
        LorebookBuildException.fromProvider(_http(429, 'Slow down')),
        fallback: CatalogErrorSource.janitor,
      );

      expect(labelled.source, CatalogErrorSource.provider);
      expect(labelled.message, 'HTTP 429: Slow down');
    });

    test('an unlabelled failure takes the stage it happened in', () {
      final labelled = describeCatalogError(
        StateError('capture ended without a payload'),
        fallback: CatalogErrorSource.janitor,
      );

      expect(labelled.source, CatalogErrorSource.janitor);
      expect(labelled.inline, startsWith('error_source_janitor: '));
    });
  });

  group('lorebookSystemPrompt', () {
    test('falls back to the built-in prompts', () {
      const settings = AppSettings();

      expect(lorebookSystemPrompt(settings), kLorebookSystemPrompt);
      expect(
        lorebookSystemPrompt(settings, fromJs: true),
        kLorebookSystemPromptJs,
      );
      expect(lorebookSystemPrompt(null), kLorebookSystemPrompt);
    });

    test('uses the edited prompt for the matching source kind', () {
      const settings = AppSettings(
        lorebookBuildPrompt: '  Split it into entries.  ',
        lorebookBuildPromptJs: 'Recover the entries from the script.',
      );

      expect(lorebookSystemPrompt(settings), 'Split it into entries.');
      expect(
        lorebookSystemPrompt(settings, fromJs: true),
        'Recover the entries from the script.',
      );
    });

    test('a blank override means the default, not an empty prompt', () {
      const settings = AppSettings(lorebookBuildPrompt: '   ');

      expect(lorebookSystemPrompt(settings), kLorebookSystemPrompt);
    });
  });

  group('buildLorebookMessages', () {
    test('sends the given system prompt verbatim', () {
      final messages = buildLorebookMessages(
        'Entry text',
        systemPrompt: 'Custom build prompt',
      );

      expect(messages.first['role'], 'system');
      expect(messages.first['content'], 'Custom build prompt');
      expect(messages.last['content'], contains('Entry text'));
    });

    test('defaults to the built-in prompt for the source kind', () {
      expect(
        buildLorebookMessages('Entry text').first['content'],
        kLorebookSystemPrompt,
      );
      expect(
        buildLorebookMessages(
          'const loreEntries = []',
          fromJs: true,
        ).first['content'],
        kLorebookSystemPromptJs,
      );
    });
  });
}
