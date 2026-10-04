import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/deep_link_service.dart';
import 'package:glaze_flutter/core/services/oauth_state.dart';
import 'package:glaze_flutter/features/cloud_sync/services/oauth_local_server.dart';

/// A redirect back into the app, the shape Dropbox sends on Android.
Uri _dropboxCallback({required String code, String? state}) => Uri.parse(
  'com.hydall.glaze://oauth/dropbox?code=$code${state == null ? '' : '&state=$state'}',
);

const _short = Duration(milliseconds: 50);

void main() {
  final service = DeepLinkService.instance;

  setUp(service.resetForTest);
  tearDown(service.resetForTest);

  group('an OAuth callback belongs to one attempt', () {
    test('the attempt that sent the state receives the callback', () async {
      service.beginOAuth('dropbox', 'S1');
      final callback = service.awaitOAuthCallback('dropbox', timeout: _short);

      service.handleDeepLink(_dropboxCallback(code: 'c1', state: 'S1'));

      expect((await callback).queryParameters['code'], 'c1');
    });

    // The reported bug, in the order the reporter hit it: connect once with no
    // Dropbox account, fail, create the account, authorize — and every later
    // tap failed with `OAuth state mismatch` until the app was restarted,
    // because the first attempt's redirect had been kept and was handed to
    // each retry in turn.
    test('a callback held from an abandoned attempt is not given to the '
        'retry', () async {
      service.beginOAuth('dropbox', 'FIRST');
      service.endOAuth('dropbox', 'FIRST');
      service.handleDeepLink(_dropboxCallback(code: 'stale', state: 'FIRST'));

      service.beginOAuth('dropbox', 'SECOND');
      final callback = service.awaitOAuthCallback('dropbox', timeout: _short);
      service.handleDeepLink(_dropboxCallback(code: 'fresh', state: 'SECOND'));

      final uri = await callback;
      expect(uri.queryParameters['state'], 'SECOND');
      expect(uri.queryParameters['code'], 'fresh');
    });

    test('a stale callback arriving mid-attempt is dropped, and the real one '
        'still lands', () async {
      service.beginOAuth('dropbox', 'LIVE');
      final callback = service.awaitOAuthCallback('dropbox', timeout: _short);

      service.handleDeepLink(_dropboxCallback(code: 'stale', state: 'OLD'));
      service.handleDeepLink(_dropboxCallback(code: 'real', state: 'LIVE'));

      expect((await callback).queryParameters['code'], 'real');
    });

    test('the poison does not outlive one attempt', () async {
      // Two abandoned attempts in a row, then a good one: the third tap must
      // work, not inherit either of the first two.
      for (final state in ['A', 'B']) {
        service.beginOAuth('dropbox', state);
        service.endOAuth('dropbox', state);
        service.handleDeepLink(_dropboxCallback(code: 'old', state: state));
      }

      service.beginOAuth('dropbox', 'C');
      final callback = service.awaitOAuthCallback('dropbox', timeout: _short);
      service.handleDeepLink(_dropboxCallback(code: 'good', state: 'C'));

      expect((await callback).queryParameters['code'], 'good');
    });
  });

  group('attempt lifecycle', () {
    test('a callback that arrives before the await still resolves it', () async {
      // The window the old code left open, and the reason it kept callbacks at
      // all: the attempt is registered, the redirect lands, and only then does
      // the caller get around to waiting for it.
      service.beginOAuth('dropbox', 'S');
      service.handleDeepLink(_dropboxCallback(code: 'quick', state: 'S'));

      final uri = await service.awaitOAuthCallback('dropbox', timeout: _short);
      expect(uri.queryParameters['code'], 'quick');
    });

    test('a callback that arrives before the attempt is held for it', () async {
      // Cold start: the redirect is what launched the app, so nothing is
      // registered when it lands. It is still this attempt's answer.
      service.handleDeepLink(_dropboxCallback(code: 'early', state: 'S'));

      service.beginOAuth('dropbox', 'S');
      final uri = await service.awaitOAuthCallback('dropbox', timeout: _short);
      expect(uri.queryParameters['code'], 'early');
    });

    test(
      'a duplicate redirect does not become the next attempt\'s answer',
      () async {
        service.beginOAuth('dropbox', 'S');
        service.handleDeepLink(_dropboxCallback(code: 'first', state: 'S'));
        service.handleDeepLink(_dropboxCallback(code: 'again', state: 'S'));
        expect(
          (await service.awaitOAuthCallback(
            'dropbox',
            timeout: _short,
          )).queryParameters['code'],
          'first',
        );
        service.endOAuth('dropbox', 'S');

        service.beginOAuth('dropbox', 'NEXT');
        await expectLater(
          service.awaitOAuthCallback('dropbox', timeout: _short),
          throwsA(isA<TimeoutException>()),
        );
      },
    );

    test('a second tap supersedes the first attempt', () async {
      service.beginOAuth('dropbox', 'ONE');
      final first = service.awaitOAuthCallback('dropbox', timeout: _short);

      service.beginOAuth('dropbox', 'TWO');
      final second = service.awaitOAuthCallback('dropbox', timeout: _short);
      service.handleDeepLink(_dropboxCallback(code: 'c', state: 'TWO'));

      await expectLater(first, throwsA(isA<StateError>()));
      expect((await second).queryParameters['state'], 'TWO');
    });

    test(
      'a superseded attempt cleaning up does not retire its replacement',
      () async {
        // `endOAuth` runs in the loser's `finally`, which is reached *after* the
        // winner has registered. Keyed by provider alone it would cancel the
        // attempt the user is waiting on.
        service.beginOAuth('dropbox', 'OLD');
        final old = service.awaitOAuthCallback('dropbox', timeout: _short);
        service.beginOAuth('dropbox', 'NEW');
        final live = service.awaitOAuthCallback('dropbox', timeout: _short);

        await expectLater(old, throwsA(isA<StateError>()));
        service.endOAuth('dropbox', 'OLD');

        service.handleDeepLink(_dropboxCallback(code: 'c', state: 'NEW'));
        expect((await live).queryParameters['state'], 'NEW');
      },
    );

    test(
      'a callback with no state is delivered so the caller can report it',
      () async {
        // A denial redirect carries `error=access_denied` and, from some
        // providers, nothing else. Holding it back would trade one bad message
        // for a five-minute wait.
        service.beginOAuth('dropbox', 'S');
        final callback = service.awaitOAuthCallback('dropbox', timeout: _short);

        service.handleDeepLink(
          Uri.parse('com.hydall.glaze://oauth/dropbox?error=access_denied'),
        );

        expect((await callback).queryParameters['error'], 'access_denied');
      },
    );

    test('awaiting with no attempt in flight is an error', () async {
      await expectLater(
        service.awaitOAuthCallback('dropbox', timeout: _short),
        throwsA(isA<StateError>()),
      );
    });

    test('a timed-out attempt is forgotten', () async {
      service.beginOAuth('dropbox', 'S');
      await expectLater(
        service.awaitOAuthCallback('dropbox', timeout: _short),
        throwsA(isA<TimeoutException>()),
      );

      // Not merely "the future failed": the entry is gone, so the next await
      // reports that nothing is in flight rather than reusing the dead one.
      await expectLater(
        service.awaitOAuthCallback('dropbox', timeout: _short),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('routing', () {
    test('the legacy db- scheme reaches Dropbox', () async {
      service.beginOAuth('dropbox', 'S');
      final callback = service.awaitOAuthCallback('dropbox', timeout: _short);

      service.handleDeepLink(Uri.parse('db-appkey://auth?code=c&state=S'));

      expect((await callback).queryParameters['code'], 'c');
    });

    test('the iOS reversed-client-id redirect reaches Drive', () async {
      // `com.googleusercontent.apps.123:/oauth2redirect` — one slash, so the
      // host is empty and only the scheme identifies it.
      service.beginOAuth('gdrive', 'S');
      final callback = service.awaitOAuthCallback('gdrive', timeout: _short);

      service.handleDeepLink(
        Uri.parse(
          'com.googleusercontent.apps.123:/oauth2redirect?code=c&state=S',
        ),
      );

      expect((await callback).queryParameters['code'], 'c');
    });

    test('providers do not answer for each other', () async {
      service.beginOAuth('dropbox', 'S');
      final callback = service.awaitOAuthCallback('dropbox', timeout: _short);

      service.handleDeepLink(
        Uri.parse('com.hydall.glaze://oauth/gdrive?code=c&state=S'),
      );

      await expectLater(callback, throwsA(isA<TimeoutException>()));
    });
  });

  group('the desktop loopback redirect', () {
    test('a matching state yields the code', () {
      expect(
        oauthCodeFromRedirect({
          'code': 'abc',
          'state': 'S',
        }, expectedState: 'S'),
        'abc',
      );
    });

    test('a code with the wrong state is refused', () {
      // Anything that reached the loopback port while it was open used to be
      // accepted, which would bind the reader's Glaze to the account that
      // issued the code.
      expect(
        () => oauthCodeFromRedirect({
          'code': 'attacker',
          'state': 'ELSEWHERE',
        }, expectedState: 'S'),
        throwsA(isA<StateError>()),
      );
    });

    test('a code with no state at all is refused', () {
      expect(
        () => oauthCodeFromRedirect({'code': 'abc'}, expectedState: 'S'),
        throwsA(isA<StateError>()),
      );
    });

    test('a request that sent no state still works', () {
      // Nothing to compare against is not the same as a failed comparison.
      expect(oauthCodeFromRedirect({'code': 'abc'}), 'abc');
    });

    test('a denial is reported as the provider described it', () {
      expect(
        () => oauthCodeFromRedirect({
          'error': 'access_denied',
          'error_description': 'user said no',
        }, expectedState: 'S'),
        throwsA(
          isA<Exception>().having(
            (e) => '$e',
            'message',
            allOf(contains('access_denied'), contains('user said no')),
          ),
        ),
      );
    });

    test('an empty redirect is reported as having no code', () {
      expect(
        () => oauthCodeFromRedirect(const {}, expectedState: 'S'),
        throwsA(
          isA<Exception>().having(
            (e) => '$e',
            'message',
            contains('No authorization code'),
          ),
        ),
      );
    });
  });

  group('oauthStateMismatchMessage', () {
    test('a state that came back unchanged is not a mismatch', () {
      expect(oauthStateMismatchMessage('abc', 'abc'), isNull);
    });

    test('nothing to compare against is not a mismatch', () {
      expect(oauthStateMismatchMessage(null, 'abc'), isNull);
      expect(oauthStateMismatchMessage('', 'abc'), isNull);
    });

    test('the message names both values', () {
      final message = oauthStateMismatchMessage('want', 'got');
      expect(message, contains('expected=want'));
      expect(message, contains('got=got'));
    });

    test('a missing answer is a mismatch, not a pass', () {
      expect(oauthStateMismatchMessage('want', null), isNotNull);
    });
  });
}
