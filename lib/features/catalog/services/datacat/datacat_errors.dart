import 'dart:convert';

import 'package:dio/dio.dart';

/// A failure DataCat's Client API described in its own words.
///
/// The site endpoints the old provider used answered failures with whatever
/// their framework produced, so the only thing worth reading was the status.
/// The Client API answers with a structured body — a machine code, a human
/// message, and, when a protected transfer needs one, instructions for getting
/// a verification lease — and the UI acts on all three: the code decides
/// whether a retry can help, the message is what the user reads, and the
/// verification block is what the lease sheet is opened from.
class DatacatApiException implements Exception {
  /// HTTP status, or 0 when the request never reached a server that answered.
  final int status;

  /// DataCat's machine-readable code, carried in the response's `error` field
  /// (the human sentence is `message`).
  final String? code;

  /// DataCat's human-readable message. Shown as-is when there is nothing
  /// better to say.
  final String message;

  /// True when the request failed only because no valid transfer lease was
  /// attached. The card/avatar callers answer this by running the verification
  /// flow and asking again.
  final bool verificationRequired;

  /// The `action` the verification challenge must be started with (currently
  /// `character-import`), when the server named one.
  final String? verificationAction;

  /// Where this installation stands with DataCat, when the failure mentioned
  /// it: `unlinked`, `linked_anonymous` or `logged_in`. A community write
  /// rejected for `linked_anonymous` needs a sign-in, not a retry.
  final String? accountState;

  /// Seconds to wait before asking again, from `Retry-After` on a 429.
  final int? retryAfterSeconds;

  const DatacatApiException({
    required this.status,
    required this.message,
    this.code,
    this.verificationRequired = false,
    this.verificationAction,
    this.accountState,
    this.retryAfterSeconds,
  });

  /// Whether the client is not allowed to do this at all — a missing or
  /// unapproved scope. Retrying changes nothing.
  bool get isForbidden => status == 403;

  /// Whether the linked user token was missing, expired, or no longer bound to
  /// a logged-in account. The account has to be linked again.
  bool get isUnauthorized => status == 401;

  /// Whether the thing asked for is gone: an expired link or challenge (410),
  /// or a character/creator that is not there (404).
  bool get isGone => status == 404 || status == 410;

  /// Whether the flow is not in the state this call needs, so the answer is to
  /// wait and ask again — a token exchange for a link the user has not approved
  /// yet, or for a challenge they have not solved.
  ///
  /// The contract describes this as a 409. The live deployment answers an
  /// unsolved challenge's token exchange with **428** `VERIFICATION_PENDING`
  /// instead, which a 409-only check reads as fatal: the poll gives up on a
  /// challenge the user is in the middle of solving. Both are accepted.
  bool get isPending => status == 409 || status == 428;

  /// Whether this integration's client id is not approved, or was revoked.
  ///
  /// Reported as a 403, the same status a refused transfer uses, so a caller
  /// that answers 403 by verifying again would put a challenge in front of the
  /// user that cannot possibly help.
  bool get isClientNotApproved => code == 'CLIENT_API_CLIENT_NOT_APPROVED';

  bool get isRateLimited => status == 429;

  @override
  String toString() => message;
}

/// Reads [error] as a Client API failure.
///
/// Anything that is not a [DioException] carrying a response — a timeout, a
/// DNS failure, a TLS error — becomes a status-0 exception with the transport's
/// own message, so callers never have to tell the two apart.
DatacatApiException datacatError(Object error) {
  if (error is DatacatApiException) return error;
  if (error is! DioException) {
    return DatacatApiException(status: 0, message: error.toString());
  }
  final response = error.response;
  if (response == null) {
    return DatacatApiException(
      status: 0,
      message: error.message ?? error.toString(),
    );
  }

  final status = response.statusCode ?? 0;
  final body = _decodeBody(response.data);
  final verification = body?['verification'];
  final verificationMap = verification is Map
      ? verification.cast<String, dynamic>()
      : const <String, dynamic>{};

  return DatacatApiException(
    status: status,
    code: body?['error'] as String?,
    message: _message(body, status),
    // `securityCheckRequired` is the same condition under the name the newer
    // deployments use; either one means "get a lease and ask again".
    verificationRequired:
        body?['verificationRequired'] == true ||
        body?['securityCheckRequired'] == true,
    verificationAction: verificationMap['action'] as String?,
    accountState: body?['accountState'] as String?,
    retryAfterSeconds: _retryAfter(response.headers),
  );
}

Map<String, dynamic>? _decodeBody(Object? data) {
  if (data is Map) return data.cast<String, dynamic>();
  if (data is! String || data.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(data);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// The sentence to show a reader. Only `message` carries one — `error` is a
/// machine code, and putting `RATE_LIMITED` on screen helps nobody.
String _message(Map<String, dynamic>? body, int status) {
  final message = body?['message'];
  if (message is String && message.trim().isNotEmpty) return message.trim();
  return 'DataCat: HTTP $status';
}

int? _retryAfter(Headers headers) {
  final raw = headers.value('retry-after');
  if (raw == null) return null;
  return int.tryParse(raw.trim());
}
