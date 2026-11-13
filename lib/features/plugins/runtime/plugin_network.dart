import 'dart:io';

/// Names that only resolve inside the user's own network.
bool isLocalHostName(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' ||
      RegExp(r'\.(localhost|local|lan|home\.arpa|internal)$').hasMatch(h);
}

/// Loopback addresses: `127.0.0.0/8` and `::1`. The same device, not a
/// network, so the "local network" switch does not apply to them.
bool isLoopbackAddress(InternetAddress address) {
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) return b[0] == 127;
  if (b.length != 16) return false;
  final mapped =
      b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
  if (mapped) return b[12] == 127;
  return b.sublist(0, 15).every((x) => x == 0) && b[15] == 1; // ::1
}

/// `localhost`, any `*.localhost` (RFC 6761), and a loopback IP literal.
bool isLoopbackHostName(String host) {
  final h = host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  final literal = InternetAddress.tryParse(h);
  return literal != null && isLoopbackAddress(literal);
}

/// Loopback, private, shared (CGNAT), link-local, unspecified and multicast
/// addresses: everything that is not a public internet host. Mirrors the
/// plugin frame policy, where loopback is handled apart from the rest.
bool isLocalNetworkAddress(InternetAddress address) {
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return _isLocalIPv4(b);
  }
  if (b.length != 16) return true;
  final mapped =
      b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
  if (mapped) return _isLocalIPv4(b.sublist(12));
  if (b.every((x) => x == 0)) return true; // ::
  if (b.sublist(0, 15).every((x) => x == 0) && b[15] == 1) return true; // ::1
  return (b[0] & 0xfe) == 0xfc || // fc00::/7
      (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) || // fe80::/10
      b[0] == 0xff; // multicast
}

bool _isLocalIPv4(List<int> b) {
  final a = b[0], c = b[1];
  return a == 0 ||
      a == 10 ||
      a == 127 ||
      (a == 100 && c >= 64 && c < 128) ||
      (a == 169 && c == 254) ||
      (a == 172 && c >= 16 && c < 32) ||
      (a == 192 && c == 168) ||
      a >= 224;
}

/// Whether [host] is, or resolves to, a host on the user's own network. A
/// name that does not resolve counts as not local: the request fails anyway.
Future<bool> isLocalNetworkHost(String host) async {
  final bare = host.replaceAll(RegExp(r'^\[|\]$'), '');
  // This device is not the user's network; only general internet access and
  // the host list apply to it.
  if (isLoopbackHostName(bare)) return false;
  if (isLocalHostName(bare)) return true;
  final literal = InternetAddress.tryParse(bare);
  if (literal != null) return isLocalNetworkAddress(literal);
  try {
    final addresses = await InternetAddress.lookup(
      bare,
    ).timeout(const Duration(seconds: 10));
    return addresses.any(isLocalNetworkAddress);
  } catch (_) {
    return false;
  }
}
