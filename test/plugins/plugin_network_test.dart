import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/plugins/runtime/plugin_network.dart';

void main() {
  group('loopback is not the local network', () {
    for (final host in [
      'localhost',
      'api.localhost',
      '127.0.0.1',
      '127.1.2.3',
      '::1',
      '[::1]',
    ]) {
      test(host, () async {
        expect(isLoopbackHostName(host), true);
        expect(await isLocalNetworkHost(host), false);
      });
    }

    for (final host in [
      '192.168.0.1',
      '10.0.0.5',
      '172.16.4.2',
      '169.254.1.1',
      'nas.local',
      'router.lan',
    ]) {
      test(host, () async {
        expect(isLoopbackHostName(host), false);
        expect(await isLocalNetworkHost(host), true);
      });
    }

    test('a public name is neither', () async {
      expect(isLoopbackHostName('example.com'), false);
      expect(await isLocalNetworkHost('example.com'), false);
    });

    test('loopback addresses, IPv4 and IPv6', () {
      expect(isLoopbackAddress(InternetAddress('127.0.0.1')), true);
      expect(isLoopbackAddress(InternetAddress('127.9.9.9')), true);
      expect(isLoopbackAddress(InternetAddress('::1')), true);
      expect(isLoopbackAddress(InternetAddress('::ffff:127.0.0.1')), true);
      expect(isLoopbackAddress(InternetAddress('192.168.1.1')), false);
      expect(isLoopbackAddress(InternetAddress('8.8.8.8')), false);
    });
  });
}
