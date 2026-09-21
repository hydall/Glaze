import '../../catalog_models.dart';
import '../greeting_normalizer.dart';
import 'datacat_client.dart';
import 'datacat_errors.dart';
import 'datacat_models.dart';
import 'datacat_verification.dart';

/// Protected transfers: the Character Card V2 JSON and the archived image.
///
/// Both need a transfer lease, and both enforce the creator's download policy
/// server-side. What used to be a pile of source-dependent field guessing —
/// which column holds the definition for a JanitorAI row, which one holds it
/// for a Saucepan row, where the greetings hid, which of eight fields was the
/// avatar — is gone: the API answers with a standard card, so the reader below
/// is the standard reader.

/// Asked for a lease when a transfer needs one. Returns the lease, or null when
/// the user backed out of the challenge.
///
/// Injected rather than reached for, because obtaining one means putting a
/// hosted page in front of the user, and a service must not decide to do that.
typedef DatacatLeaseProvider = Future<String?> Function();

/// The Character Card V2 JSON for [characterId], as a Glaze card.
Future<DownloadedCharacter> datacatFetchCard(
  String characterId, {
  String? sourceKind,
  required DatacatLeaseProvider obtainLease,
  bool withAvatar = true,
  DatacatLeaseStore? store,
}) async {
  final leases = store ?? DatacatLeaseStore.instance;
  final card = await _leased(
    characterId,
    leases: leases,
    obtainLease: obtainLease,
    request: (lease) => datacatGet(
      '/characters/$characterId/card',
      query: {'sourceKind': sourceKind},
      auth: DatacatAuth(lease: lease),
    ),
  );

  List<int>? avatarBytes;
  if (withAvatar) {
    try {
      avatarBytes = await datacatFetchAvatar(
        characterId,
        sourceKind: sourceKind,
        obtainLease: obtainLease,
        store: leases,
      );
    } catch (_) {
      // A card without its picture is still a card. The import falls back to
      // whatever avatar URL the summary carried.
    }
  }

  return DownloadedCharacter(
    charData: datacatCardToCharacterData(card),
    avatarBytes: avatarBytes,
  );
}

/// The archived character image for [characterId].
Future<List<int>> datacatFetchAvatar(
  String characterId, {
  String? sourceKind,
  required DatacatLeaseProvider obtainLease,
  DatacatLeaseStore? store,
}) {
  return _leased(
    characterId,
    leases: store ?? DatacatLeaseStore.instance,
    obtainLease: obtainLease,
    request: (lease) => datacatGetBytes(
      '/characters/$characterId/avatar',
      query: {'sourceKind': sourceKind},
      auth: DatacatAuth(lease: lease),
    ),
  );
}

/// A mirrored image for a public direct-upload character.
///
/// Public, and spends no transfer allowance — so a preview can show the real
/// picture before the user has verified anything. Only direct-upload content
/// has one, which is why the source kind is required rather than optional here;
/// every other character falls back to the summary's avatar URL.
Future<List<int>> datacatFetchAvatarPreview(
  String characterId, {
  String sourceKind = 'direct_upload',
}) => datacatGetBytes(
  '/characters/$characterId/avatar-preview',
  query: {'sourceKind': sourceKind},
);

/// Runs [request] under a valid lease, verifying once if it needs one.
///
/// The stored lease is tried first even when the store thinks it is spent, and
/// the *server's* answer is what decides: a lease we believe is live but the
/// server has retired is indistinguishable from one we never had, and only one
/// of the two is worth a second round of verification.
Future<T> _leased<T>(
  String characterId, {
  required DatacatLeaseStore leases,
  required DatacatLeaseProvider obtainLease,
  required Future<T> Function(String? lease) request,
}) async {
  final existing = leases.leaseFor(characterId);
  if (existing != null) {
    try {
      final result = await request(existing);
      leases.noteUsed(characterId);
      return result;
    } on DatacatApiException catch (e) {
      // A refused transfer answers 428 with `verificationRequired`. The 403 is
      // for a lease the server has retired — but an unapproved or revoked
      // client id reports *that* as a 403 too, and re-verifying could not fix
      // it: it would put a challenge in front of the user for nothing.
      final leaseRefused =
          e.verificationRequired || (e.isForbidden && !e.isClientNotApproved);
      if (!leaseRefused) rethrow;
      leases.invalidate();
    }
  }

  final fresh = await obtainLease();
  if (fresh == null) {
    throw const DatacatApiException(
      status: 403,
      code: 'verification_required',
      message: 'This download needs human verification',
      verificationRequired: true,
    );
  }
  final result = await request(fresh);
  leases.noteUsed(characterId);
  return result;
}

/// Reads a Character Card V2 body into the app's card.
///
/// Accepts both the bare `{spec, data}` envelope and a response that wraps it
/// under `card` — which one arrives is not worth a caller's attention.
CharacterData datacatCardToCharacterData(Map<String, dynamic> body) {
  final envelope = body['card'] is Map
      ? datacatMap(body['card'])
      : (body['chara_card_v2_json'] is Map
            ? datacatMap(body['chara_card_v2_json'])
            : body);
  final data = envelope['data'] is Map ? datacatMap(envelope['data']) : envelope;

  final greetings = normalizeGreetings(
    primary: datacatString(data['first_mes']),
    others: greetingList(data['alternate_greetings']),
  );

  final name = datacatString(data['name']);
  return CharacterData(
    name: name.isEmpty ? 'Unknown' : name,
    description: datacatString(data['description']),
    personality: datacatString(data['personality']),
    scenario: datacatString(data['scenario']),
    firstMes: greetings.firstMes,
    mesExample: datacatString(data['mes_example']),
    creatorNotes: datacatString(data['creator_notes']),
    systemPrompt: datacatString(data['system_prompt']),
    postHistoryInstructions: datacatString(data['post_history_instructions']),
    alternateGreetings: greetings.alternates,
    tags:
        (data['tags'] as List?)
            ?.map(datacatString)
            .where((t) => t.isNotEmpty)
            .toList() ??
        const [],
    creator: datacatString(data['creator']),
    creatorId: datacatString(data['creator_id'] ?? data['creatorId']),
    characterBook: data['character_book'],
  );
}
