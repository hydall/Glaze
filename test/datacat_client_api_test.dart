import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/catalog_models.dart';
import 'package:glaze_flutter/features/catalog/services/catalog_http.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_cards.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_client.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_discovery.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_errors.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_models.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_sort.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_verification.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Answers every catalog request from [reply] and keeps what was asked.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.reply);

  final ({int status, String body}) Function(RequestOptions options, int index)
  reply;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final answer = reply(options, requests.length);
    requests.add(options);
    return ResponseBody.fromString(
      answer.body,
      answer.status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String _json(Object value) => jsonEncode(value);

/// A `/characters` page carrying one summary.
Map<String, Object?> _page({
  int total = 1,
  bool hasMore = false,
  int nextOffset = 1,
}) => {
  'characters': [
    {
      'id': 'char-1',
      'name': 'Yixuan',
      'chatName': 'Yi',
      'description': 'a body',
      'avatarUrl': 'https://cdn.example/a.png',
      'sourceKind': 'janitor',
      'nsfw': true,
      'totalTokens': 1200,
      'tags': [
        {'name': 'fantasy'},
        'noir',
      ],
      'creator': {
        'id': 'creator-id',
        'ref': 'saucepan:creator-uuid',
        'sourceKind': 'saucepan',
        'name': 'Someone',
      },
      'stats': {'chats': 7, 'messages': 42, 'messagesPerChat': 6.0},
    },
  ],
  'paging': {
    'limit': 24,
    'offset': 0,
    'total': total,
    'hasMore': hasMore,
    'nextOffset': nextOffset,
  },
};

/// `/capabilities` as the contract documents it.
const _capabilities =
    '{"success":true,"apiVersion":"v1",'
    '"features":{"listing":true,"tagBrowsing":true,"social":true},'
    '"paging":{"defaultPageSize":24,"maxPageSize":24},'
    '"securityCheck":{"enabled":true,"hosted":true}}';

/// `/capabilities` as the live deployment answers it: the documented fields
/// plus the advertised verification actions and lease lifetime.
const _liveCapabilities =
    '{"success":true,"apiVersion":"v1",'
    '"features":{"listing":true,"tagBrowsing":true,"social":true},'
    '"paging":{"defaultPageSize":24,"maxPageSize":24},'
    '"securityCheck":{"enabled":true,"hosted":true,'
    '"actions":["character-import"],"leaseTtlSeconds":1800,'
    '"maxUniqueCharacters":20}}';

String? _header(RequestOptions options, String name) =>
    options.headers[name]?.toString();

/// Serves capabilities, then whatever [reply] says for everything else.
_ScriptedAdapter _serve(
  ({int status, String body}) Function(RequestOptions options, int index) reply,
) {
  return _ScriptedAdapter((options, index) {
    if (options.uri.path.endsWith('/capabilities')) {
      return (status: 200, body: _capabilities);
    }
    return reply(options, index);
  });
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'gz_dc_device': 'install-1234567890'});
    setDatacatClientId('client-abc');
    resetDatacatCapabilities();
    resetDatacatTags();
    DatacatLeaseStore.instance.invalidate();
  });

  tearDown(() => setDatacatClientId(null));

  group('every scoped request identifies the integration', () {
    test('the client id rides along, the installation id does not', () async {
      final adapter = _serve((options, index) => (status: 200, body: _json(_page())));
      setCatalogHttpAdapter(adapter);

      await datacatFetchCharacters();

      final listing = adapter.requests.last;
      expect(_header(listing, 'X-Datacat-Client-Id'), 'client-abc');
      // Discovery is anonymous. Sending the installation id would hand DataCat
      // a stable identifier for browsing that browsing does not need.
      expect(_header(listing, 'X-Datacat-Installation-Id'), isNull);
      expect(_header(listing, 'Authorization'), isNull);
    });

    test('a build with no key says so instead of calling', () async {
      setDatacatClientId('');
      final adapter = _serve((options, index) => (status: 200, body: '{}'));
      setCatalogHttpAdapter(adapter);

      await expectLater(
        datacatFetchCharacters(),
        throwsA(
          isA<DatacatApiException>().having(
            (e) => e.code,
            'code',
            'client_id_missing',
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
    });
  });

  group('a listing asks for what the filters mean', () {
    test('browse and search are one endpoint', () async {
      final adapter = _serve((options, index) => (status: 200, body: _json(_page())));
      setCatalogHttpAdapter(adapter);

      await datacatFetchCharacters(query: 'wizard of the north');

      final uri = adapter.requests.last.uri;
      expect(uri.path, '/api/client/v1/characters');
      expect(uri.queryParameters['search'], 'wizard of the north');
      expect(uri.queryParameters['sort'], 'fresh');
    });

    test('NSFW off is the blocked adult tag, not a flag of our own', () async {
      final adapter = _serve((options, index) => (status: 200, body: _json(_page())));
      setCatalogHttpAdapter(adapter);

      await datacatFetchCharacters(filters: const CatalogFilters(nsfw: false));
      expect(
        adapter.requests.last.uri.queryParameters['blockedTagIds'],
        '2',
      );

      await datacatFetchCharacters(filters: const CatalogFilters(nsfw: true));
      expect(
        adapter.requests.last.uri.queryParameters.containsKey('blockedTagIds'),
        isFalse,
      );
    });

    test('a windowed sort goes to the fresh feed and pages its window', () async {
      final adapter = _serve(
        (options, index) => (
          status: 200,
          body: _json({
            'success': true,
            'sortBy': 'score',
            'windows': {
              'thisWeek': _page(),
              'last24h': {'characters': <Object?>[], 'paging': <String, Object?>{}},
            },
          }),
        ),
      );
      setCatalogHttpAdapter(adapter);

      final result = await datacatFetchCharacters(
        offset: 48,
        // NSFW on, so the windowed feed's own filtering keeps the fixture row:
        // what this test is about is where the request goes, not what is
        // dropped from it.
        filters: const CatalogFilters(sort: 'score', window: 'week', nsfw: true),
      );

      final uri = adapter.requests.last.uri;
      expect(uri.path, '/api/client/v1/fresh');
      expect(uri.queryParameters['sort'], 'score');
      // The caller's single cursor lands on the window that was asked for, and
      // the other window stays at its start.
      expect(uri.queryParameters['offsetWeek'], '48');
      expect(uri.queryParameters['offset24'], '0');
      expect(result.characters.single.name, 'Yixuan');
    });

    test('the fresh feed is asked for nothing it does not accept', () async {
      final adapter = _serve(
        (options, index) => (
          status: 200,
          body: _json({
            'windows': {'last24h': _page()},
          }),
        ),
      );
      setCatalogHttpAdapter(adapter);

      await datacatFetchCharacters(
        filters: const CatalogFilters(
          sort: 'fresh',
          window: '24h',
          nsfw: true,
          tagIds: [12, 44],
        ),
      );

      // This endpoint takes a sort and the two offsets and nothing else.
      // Sending tag parameters it does not document risks a 400 and filters
      // nothing even when it does not.
      final query = adapter.requests.last.uri.queryParameters;
      expect(query.keys, unorderedEquals(<String>['sort', 'limit', 'offset24', 'offsetWeek']));
    });

    test('a window the server cannot filter is filtered here', () async {
      final adapter = _serve(
        (options, index) => (
          status: 200,
          body: _json({
            'windows': {
              'last24h': {
                'characters': [
                  {'id': 'a', 'name': 'Adult', 'nsfw': true},
                  {'id': 'b', 'name': 'Tame', 'nsfw': false},
                ],
                'paging': {'hasMore': true, 'nextOffset': 2},
              },
            },
          }),
        ),
      );
      setCatalogHttpAdapter(adapter);

      final result = await datacatFetchCharacters(
        filters: const CatalogFilters(sort: 'fresh', window: '24h', nsfw: false),
      );

      // The reader turned adult content off; a feed the server will not filter
      // must not smuggle it back in.
      expect(result.characters.map((c) => c.name), ['Tame']);
      // The cursor stays the server's, so the next page still starts where it
      // said rather than where the shortened list ends.
      expect(result.nextOffset, 2);
      expect(result.hasMore, isTrue);
    });

    test('paging follows the server cursor, not the page number', () async {
      final adapter = _serve(
        (options, index) => (
          status: 200,
          body: _json(_page(total: 99, hasMore: true, nextOffset: 37)),
        ),
      );
      setCatalogHttpAdapter(adapter);

      final result = await datacatFetchCharacters();

      expect(result.hasMore, isTrue);
      expect(result.nextOffset, 37);
    });
  });

  group('a summary becomes a catalog row', () {
    test('the adult chip comes from the flag, and the creator keeps its ref',
        () async {
      final adapter = _serve((options, index) => (status: 200, body: _json(_page())));
      setCatalogHttpAdapter(adapter);

      final item = (await datacatFetchCharacters()).characters.single;

      expect(item.name, 'Yixuan');
      expect(item.tokens, 1200);
      expect(item.chatCount, 7);
      expect(item.messageCount, 42);
      expect(item.nsfw, isTrue);
      // Derived from `nsfw`, not prepended from a tag the row may not carry.
      expect(item.tags, containsAll(<String>['NSFW', 'fantasy', 'noir']));
      expect(item.tags, isNot(contains('SFW')));
      // The creator screen is opened by ref; the raw id would lose the
      // `saucepan:` prefix that says which library to look in.
      expect(item.creatorRef, 'saucepan:creator-uuid');
      expect(item.creatorId, 'creator-id');
      expect(item.sourceKind, 'janitor');
    });
  });

  group('a sort a user saved before the migration still means something', () {
    test('the folded keys split back into a field and a window', () {
      const legacy = <String, (String, DatacatWindow)>{
        'recent': ('fresh', DatacatWindow.all),
        'score_week': ('score', DatacatWindow.thisWeek),
        'score_24h': ('score', DatacatWindow.last24h),
        'chat_count_week': ('chat_count', DatacatWindow.thisWeek),
        'chat_count_24h': ('chat_count', DatacatWindow.last24h),
      };
      legacy.forEach((key, expected) {
        final resolved = DatacatSort.resolve(CatalogFilters(sort: key));
        expect(resolved.field, expected.$1, reason: key);
        expect(resolved.window, expected.$2, reason: key);
      });
    });

    test('migrating rewrites the stored filters once', () {
      final migrated = DatacatSort.migrate(
        const CatalogFilters(sort: 'chat_count_24h'),
      );
      expect(migrated.sort, 'chat_count');
      expect(migrated.window, '24h');
      // Already-migrated filters are left alone.
      expect(DatacatSort.migrate(migrated).sort, 'chat_count');
    });

    test('an unknown sort falls back rather than being sent through', () {
      expect(
        DatacatSort.resolve(const CatalogFilters(sort: 'nonsense')).field,
        'fresh',
      );
    });

    test('a current field keeps its window even when a legacy key shares its name', () {
      // `fresh` is both today's sort field and yesterday's windowless label.
      // Read as the label it would pin the feed to all-time and throw away the
      // window the user chose.
      final resolved = DatacatSort.resolve(
        const CatalogFilters(sort: 'fresh', window: '24h'),
      );
      expect(resolved.field, 'fresh');
      expect(resolved.window, DatacatWindow.last24h);
      expect(
        DatacatSort.migrate(
          const CatalogFilters(sort: 'fresh', window: '24h'),
        ).window,
        '24h',
      );
    });
  });

  group('a protected transfer spends a lease', () {
    test('the lease header is what the card request carries', () async {
      final adapter = _serve(
        (options, index) => (
          status: 200,
          body: _json({
            'data': {'name': 'Yixuan', 'description': 'a body', 'first_mes': 'hi'},
          }),
        ),
      );
      setCatalogHttpAdapter(adapter);

      final card = await datacatFetchCard(
        'char-1',
        withAvatar: false,
        obtainLease: () async => 'lease-1',
      );

      expect(card.charData.name, 'Yixuan');
      expect(
        _header(adapter.requests.last, 'X-Datacat-Verification-Lease'),
        'lease-1',
      );
    });

    test('one lease covers the next character without verifying again',
        () async {
      var challenges = 0;
      final adapter = _serve(
        (options, index) => (
          status: 200,
          body: _json({
            'data': {'name': 'Yixuan'},
          }),
        ),
      );
      setCatalogHttpAdapter(adapter);

      Future<String?> obtain() async {
        challenges++;
        DatacatLeaseStore.instance.store(
          'lease-1',
          DateTime.now().add(const Duration(minutes: 5)),
        );
        return 'lease-1';
      }

      await datacatFetchCard('char-1', withAvatar: false, obtainLease: obtain);
      await datacatFetchCard('char-2', withAvatar: false, obtainLease: obtain);

      expect(challenges, 1);
    });

    test('the budget is counted in characters, and runs out', () {
      final store = DatacatLeaseStore.instance;
      store.store('lease-1', DateTime.now().add(const Duration(minutes: 5)));

      for (var i = 0; i < datacatLeaseCharacterBudget; i++) {
        expect(store.leaseFor('char-$i'), 'lease-1');
        store.noteUsed('char-$i');
      }

      // A character already transferred under this lease costs nothing more.
      expect(store.leaseFor('char-0'), 'lease-1');
      // A new one does, and there is nothing left.
      expect(store.leaseFor('char-new'), isNull);
    });

    test('an expired lease is not offered', () {
      final store = DatacatLeaseStore.instance;
      store.store('lease-1', DateTime.now().add(const Duration(seconds: 1)));
      expect(store.leaseFor('char-1'), isNull);
    });

    test('the server decides how many characters a lease covers', () {
      final store = DatacatLeaseStore.instance;
      store.store(
        'lease-1',
        DateTime.now().add(const Duration(minutes: 5)),
        maxUniqueCharacters: 2,
      );

      store.noteUsed('char-1');
      store.noteUsed('char-2');
      expect(store.leaseFor('char-3'), isNull);
      expect(store.remainingBudget, 0);
    });

    test('a refusal to verify is reported as needing verification', () async {
      final adapter = _serve((options, index) => (status: 200, body: '{}'));
      setCatalogHttpAdapter(adapter);

      await expectLater(
        datacatFetchCard(
          'char-1',
          withAvatar: false,
          obtainLease: () async => null,
        ),
        throwsA(
          isA<DatacatApiException>().having(
            (e) => e.verificationRequired,
            'verificationRequired',
            isTrue,
          ),
        ),
      );
    });
  });

  group('a Character Card V2 body reads as a card', () {
    test('the envelope is unwrapped and the greetings fold together', () {
      final card = datacatCardToCharacterData({
        'spec': 'chara_card_v2',
        'data': {
          'name': 'Yixuan',
          'description': 'the definition',
          'personality': 'warm',
          'scenario': 'a tavern',
          'first_mes': 'hello',
          'alternate_greetings': ['second', 'third'],
          'creator_notes': 'the blurb',
          'tags': ['noir'],
          'creator': 'Someone',
        },
      });

      expect(card.name, 'Yixuan');
      // No source-dependent guessing left: the definition is the definition
      // and the blurb stays out of it.
      expect(card.description, 'the definition');
      expect(card.creatorNotes, 'the blurb');
      expect(card.firstMes, 'hello');
      expect(card.alternateGreetings, ['second', 'third']);
      expect(card.tags, ['noir']);
    });

    test('a body wrapped under `card` reads the same', () {
      final card = datacatCardToCharacterData({
        'card': {
          'data': {'name': 'Yixuan', 'first_mes': 'hi'},
        },
      });
      expect(card.name, 'Yixuan');
      expect(card.firstMes, 'hi');
    });
  });

  group('a failure says what it was', () {
    test('a structured error keeps its code and message', () async {
      final adapter = _serve(
        (options, index) => (
          status: 403,
          body: _json({
            'success': false,
            // The machine code travels in `error`; `message` is the sentence.
            'error': 'verification_required',
            'message': 'Human verification required',
            'accountState': 'unlinked',
            'verificationRequired': true,
            'verification': {'action': 'character_transfer'},
          }),
        ),
      );
      setCatalogHttpAdapter(adapter);

      await expectLater(
        datacatFetchCharacters(),
        throwsA(
          isA<DatacatApiException>()
              .having((e) => e.status, 'status', 403)
              .having((e) => e.code, 'code', 'verification_required')
              .having((e) => e.message, 'message', 'Human verification required')
              .having(
                (e) => e.verificationAction,
                'action',
                'character_transfer',
              )
              .having((e) => e.accountState, 'accountState', 'unlinked'),
        ),
      );
    });

    test('a body that is not the documented shape still reports its status',
        () async {
      final adapter = _serve(
        (options, index) => (status: 502, body: '<html>bad gateway</html>'),
      );
      setCatalogHttpAdapter(adapter);

      await expectLater(
        datacatFetchCharacters(),
        throwsA(
          isA<DatacatApiException>().having((e) => e.status, 'status', 502),
        ),
      );
    });
  });

  group('the live deployment is not the vendored contract', () {
    test('the challenge is started with the action capabilities advertises',
        () async {
      // The contract says `character_transfer`; the server rejects that and
      // names its own. Reading the list is what survives the next rename.
      final adapter = _ScriptedAdapter((options, index) {
        if (options.uri.path.endsWith('/capabilities')) {
          return (
            status: 200,
            body: _liveCapabilities.replaceFirst(
              '"character-import"',
              '"renamed-again"',
            ),
          );
        }
        return (
          status: 201,
          body: _json({
            'verificationId': 'v-1',
            'deviceCode': 'secret',
            'verificationUriComplete': 'https://datacat.run/client-verify?id=v-1',
            'expiresIn': 300,
            'interval': 3,
          }),
        );
      });
      setCatalogHttpAdapter(adapter);

      await startDatacatVerification();

      final started = adapter.requests.last;
      expect(started.uri.path, endsWith('/verifications'));
      expect(jsonDecode(started.data as String)['action'], 'renamed-again');
    });

    test('an unsolved challenge answers 428, and the poll keeps waiting',
        () async {
      // The contract documents 409. Live uses 428 VERIFICATION_PENDING, which a
      // 409-only check reads as fatal and throws the user's solve away.
      final adapter = _ScriptedAdapter((options, index) {
        if (options.uri.path.endsWith('/capabilities')) {
          return (status: 200, body: _liveCapabilities);
        }
        if (index == 0) {
          return (
            status: 428,
            body: _json({
              'success': false,
              'error': 'VERIFICATION_PENDING',
              'message': 'Waiting for the DataCat security check.',
            }),
          );
        }
        return (
          status: 200,
          body: _json({
            'success': true,
            'leaseToken': 'dcv1v_lease',
            'expiresAt': DateTime.now()
                .add(const Duration(minutes: 30))
                .toUtc()
                .toIso8601String(),
            'maxUniqueCharacters': 20,
          }),
        );
      });
      setCatalogHttpAdapter(adapter);

      final lease = await awaitDatacatLease(
        const DatacatDeviceFlow(
          id: 'v-1',
          deviceCode: 'secret',
          uri: 'https://datacat.run/client-verify?id=v-1',
          interval: Duration(milliseconds: 5),
        ),
      );

      expect(lease, 'dcv1v_lease');
      expect(DatacatLeaseStore.instance.leaseFor('char-1'), 'dcv1v_lease');
    });

    test('a lease that states a duration rather than an instant still lives',
        () async {
      // The success body was never observed against live, so both spellings
      // have to work — reading neither would leave the lease a 5-minute stub.
      final adapter = _ScriptedAdapter((options, index) {
        if (options.uri.path.endsWith('/capabilities')) {
          return (status: 200, body: _liveCapabilities);
        }
        return (
          status: 200,
          body: _json({'leaseToken': 'dcv1v_lease', 'expiresIn': 1800}),
        );
      });
      setCatalogHttpAdapter(adapter);

      await awaitDatacatLease(
        const DatacatDeviceFlow(
          id: 'v-1',
          deviceCode: 'secret',
          uri: 'https://datacat.run/client-verify?id=v-1',
          interval: Duration(milliseconds: 5),
        ),
      );

      expect(DatacatLeaseStore.instance.leaseFor('char-1'), 'dcv1v_lease');
    });

    test('a revoked client id is not answered by verifying again', () async {
      // Live reports an unapproved client id as a 403 — the same status a
      // retired lease uses. Only one of the two is worth a challenge.
      DatacatLeaseStore.instance.store(
        'dcv1v_stale',
        DateTime.now().add(const Duration(minutes: 30)),
      );
      final adapter = _serve(
        (options, index) => (
          status: 403,
          body: _json({
            'success': false,
            'error': 'CLIENT_API_CLIENT_NOT_APPROVED',
            'message': 'This client is not approved or has been revoked.',
          }),
        ),
      );
      setCatalogHttpAdapter(adapter);

      var asked = false;
      await expectLater(
        datacatFetchCard(
          'char-1',
          obtainLease: () async {
            asked = true;
            return 'dcv1v_fresh';
          },
        ),
        throwsA(
          isA<DatacatApiException>()
              .having((e) => e.isClientNotApproved, 'clientNotApproved', true),
        ),
      );
      expect(asked, isFalse);
    });
  });
}
