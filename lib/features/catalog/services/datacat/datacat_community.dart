import '../../catalog_models.dart';
import 'datacat_account.dart';
import 'datacat_client.dart';
import 'datacat_errors.dart';
import 'datacat_models.dart';

/// Kudos and comments on a DataCat character.
///
/// Reading is anonymous — the client id is enough. Writing is not: a kudos or a
/// comment is attributed to a logged-in account, so both need the linked user
/// token *and* the installation id it was bound to. A developer token would not
/// substitute, and neither would a `linked_anonymous` installation: there is no
/// such thing as an unattributed comment here.

/// Longest comment the API accepts.
const datacatCommentMaxLength = 4000;

/// Largest comment page the API serves.
const datacatCommentPageLimit = 100;

/// Reads the community panel for [characterId].
Future<DatacatCommunity> datacatFetchCommunity(
  String characterId, {
  int offset = 0,
  int limit = 40,
}) async {
  final token = await datacatUserToken();
  final data = await datacatGet(
    '/characters/$characterId/community',
    query: {
      'offset': offset,
      'limit': limit.clamp(1, datacatCommentPageLimit),
    },
    // Optional, but sending it is what makes `canInteract` answer for this
    // viewer rather than for nobody.
    auth: DatacatAuth(userToken: token),
  );
  return DatacatCommunity.fromJson(data);
}

/// Maps one DataCat comment onto the shared catalog comment.
CatalogComment datacatComment(Map<String, dynamic> json) {
  final author = datacatMap(json['author']);
  final username = datacatString(author['username']);
  final name = datacatString(author['displayName']).isNotEmpty
      ? datacatString(author['displayName'])
      : username;
  return CatalogComment(
    id: datacatString(json['id']),
    content: datacatString(json['body']),
    authorName: name.isEmpty ? 'Anonymous' : name,
    authorUserName: username,
    avatarUrl: author['avatarUrl'] as String?,
    createdAt: DateTime.tryParse(datacatString(json['createdAt'])),
  );
}

/// Sends a kudos reply using [giftKey], as the linked account.
///
/// Both writes answer with the refreshed thread, so the caller gets the new
/// state without a second read — which also means the count the user sees is
/// the server's, not one the client incremented hopefully.
Future<DatacatCommunity> datacatSendKudos(
  String characterId, {
  required String giftKey,
}) async {
  final data = await datacatPost(
    '/characters/$characterId/community/kudos',
    body: {'giftKey': giftKey},
    auth: await _writeAuth(),
  );
  return DatacatCommunity.fromJson(data);
}

/// Posts a plain comment as the linked account.
Future<DatacatCommunity> datacatPostComment(
  String characterId, {
  required String body,
}) async {
  final text = body.trim();
  if (text.isEmpty || text.length > datacatCommentMaxLength) {
    throw const DatacatApiException(
      status: 400,
      message: 'A comment must be between 1 and 4000 characters',
    );
  }
  final data = await datacatPost(
    '/characters/$characterId/community/comments',
    body: {'body': text},
    auth: await _writeAuth(),
  );
  return DatacatCommunity.fromJson(data);
}

Future<DatacatAuth> _writeAuth() async {
  final token = await datacatUserToken();
  if (token == null) {
    throw const DatacatApiException(
      status: 401,
      code: 'account_not_linked',
      message: 'Link a DataCat account to post',
    );
  }
  return DatacatAuth(userToken: token, withInstallationId: true);
}
