import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_session.dart';

/// A JWT with the given `exp` (seconds since epoch). Only the payload matters —
/// nothing here verifies a signature.
String _jwt({int? exp, String header = 'eyJhbGciOiJIUzI1NiJ9'}) {
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'sub': 'u1', 'exp': ?exp})))
      .replaceAll('=', '');
  return '$header.$payload.c2ln';
}

void main() {
  group('isJanitorAuthCookie', () {
    test('matches the Supabase session cookie and every chunk of it', () {
      expect(isJanitorAuthCookie('sb-abcdef-auth-token'), isTrue);
      expect(isJanitorAuthCookie('sb-abcdef-auth-token.0'), isTrue);
      expect(isJanitorAuthCookie('sb-abcdef-auth-token.1'), isTrue);
    });

    test('leaves the cookies the wipe is meant to reset alone', () {
      expect(isJanitorAuthCookie('cf_clearance'), isFalse);
      expect(isJanitorAuthCookie('__cf_bm'), isFalse);
      expect(isJanitorAuthCookie('sb-abcdef-other'), isFalse);
    });
  });

  group('janitorAuthCookieExpiry', () {
    final now = DateTime.utc(2026, 8, 25).millisecondsSinceEpoch;

    test('a missing expiry becomes a persistent one', () {
      // Android returns no attributes at all on older WebViews; re-setting null
      // would make the login a session cookie and lose it on the next launch.
      final expiry = janitorAuthCookieExpiry(null, nowMs: now);
      expect(expiry - now, const Duration(days: 400).inMilliseconds);
    });

    test('a mangled short expiry is replaced, not trusted', () {
      // What Android reports for a 400-day Max-Age: `now + maxAge` treated as
      // milliseconds, i.e. about nine hours.
      final mangled =
          now + const Duration(hours: 9, minutes: 36).inMilliseconds;
      expect(
        janitorAuthCookieExpiry(mangled, nowMs: now),
        now + const Duration(days: 400).inMilliseconds,
      );
    });

    test('an expiry already in the past is replaced', () {
      final stale = now - const Duration(days: 1).inMilliseconds;
      expect(
        janitorAuthCookieExpiry(stale, nowMs: now),
        now + const Duration(days: 400).inMilliseconds,
      );
    });

    test('a real long-lived expiry is kept as read', () {
      final real = now + const Duration(days: 30).inMilliseconds;
      expect(janitorAuthCookieExpiry(real, nowMs: now), real);
    });
  });

  group('janitorTokenExpiry', () {
    test('reads the exp claim', () {
      final expiry = janitorTokenExpiry(_jwt(exp: 1787000000));
      expect(
        expiry,
        DateTime.fromMillisecondsSinceEpoch(1787000000 * 1000, isUtc: true),
      );
    });

    test('returns null for a token that carries none', () {
      expect(janitorTokenExpiry(_jwt()), isNull);
    });

    test('returns null for something that is not a JWT', () {
      expect(janitorTokenExpiry('not-a-token'), isNull);
      expect(janitorTokenExpiry('a.b'), isNull);
      expect(janitorTokenExpiry('a.!!!.c'), isNull);
    });
  });

  group('isJanitorTokenExpired', () {
    final now = DateTime.utc(2026, 8, 25, 12);
    int at(Duration offset) => now.add(offset).millisecondsSinceEpoch ~/ 1000;

    test('a token from the previous session is spent', () {
      // The case behind "log in again after every launch": the JWT lives an
      // hour, the refresh token beside it lives for weeks.
      expect(
        isJanitorTokenExpired(
          _jwt(exp: at(const Duration(hours: -3))),
          now: now,
        ),
        isTrue,
      );
    });

    test('a token about to lapse is treated as spent', () {
      expect(
        isJanitorTokenExpired(
          _jwt(exp: at(const Duration(seconds: 30))),
          now: now,
        ),
        isTrue,
      );
    });

    test('a fresh token is usable', () {
      expect(
        isJanitorTokenExpired(
          _jwt(exp: at(const Duration(minutes: 45))),
          now: now,
        ),
        isFalse,
      );
    });

    test('an unreadable expiry is not guessed at', () {
      // Better to let the request answer than to force a reload on a hunch.
      expect(isJanitorTokenExpired(_jwt(), now: now), isFalse);
      expect(isJanitorTokenExpired('not-a-token', now: now), isFalse);
    });
  });

  group('janitorReadIsPublic', () {
    test('the browse surface a reader needs no account for', () {
      expect(
        janitorReadIsPublic(
          'https://janitorai.com/hampter/characters?page=2&mode=all&sort=latest',
        ),
        isTrue,
      );
      expect(
        janitorReadIsPublic('https://janitorai.com/hampter/characters/abc123'),
        isTrue,
      );
      expect(
        janitorReadIsPublic(
          'https://janitorai.com/hampter/characters/tags/suggest?prefix=ro',
        ),
        isTrue,
      );
      expect(
        janitorReadIsPublic('https://janitorai.com/hampter/tags'),
        isTrue,
      );
      expect(
        janitorReadIsPublic('https://janitorai.com/hampter/reviews/abc123?page=1'),
        isTrue,
      );
    });

    test('an account-bound read is never retried without the account', () {
      // Each of these answers an anonymous reader with somebody else's data or
      // with nothing — and the block list is then written back.
      expect(
        janitorReadIsPublic(
          'https://janitorai.com/hampter/profiles/mine/blocked-content',
        ),
        isFalse,
      );
      expect(
        janitorReadIsPublic('https://janitorai.com/hampter/profiles/mine'),
        isFalse,
      );
      expect(
        janitorReadIsPublic('https://janitorai.com/hampter/chats/c1'),
        isFalse,
      );
      expect(
        janitorReadIsPublic('https://janitorai.com/hampter/personas'),
        isFalse,
      );
      expect(
        janitorReadIsPublic('https://janitorai.com/hampter/api-settings'),
        isFalse,
      );
      expect(
        janitorReadIsPublic('https://janitorai.com/hampter/script/s1'),
        isFalse,
      );
    });

    test('only a read is ever repeated — a write is not', () {
      expect(
        janitorReadIsPublic(
          'https://janitorai.com/hampter/characters',
          method: 'PATCH',
        ),
        isFalse,
      );
      expect(
        janitorReadIsPublic(
          'https://janitorai.com/hampter/characters',
          method: 'POST',
        ),
        isFalse,
      );
    });

    test('anything that is not a hampter path is refused outright', () {
      expect(janitorReadIsPublic('https://janitorai.com/'), isFalse);
      expect(janitorReadIsPublic('https://janitorai.com/hampter'), isFalse);
      expect(
        janitorReadIsPublic('https://ella.janitorai.com/bot-avatars/x.webp'),
        isFalse,
      );
    });
  });
}
