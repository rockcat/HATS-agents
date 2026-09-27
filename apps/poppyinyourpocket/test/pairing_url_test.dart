import 'package:flutter_test/flutter_test.dart';
import 'package:poppy/services/pairing_service.dart';

/// Exactly what PairingService.redeem derives, so a regression here is caught
/// rather than shipped: a base URL that is subtly wrong looks right in a log
/// and fails every request built on it.
String serverUrlFrom(String pairingLink) => originOf(Uri.parse(pairingLink));

void main() {
  group('deriving the runner URL from a pairing link', () {
    test('keeps host and port, drops the path', () {
      expect(serverUrlFrom('http://10.0.2.2:3001/api/auth/pair/abc123'), 'http://10.0.2.2:3001');
    });

    test('works for a LAN address', () {
      expect(serverUrlFrom('http://10.0.10.137:3001/api/auth/pair/abc123'), 'http://10.0.10.137:3001');
    });

    test('works over https without a port', () {
      expect(serverUrlFrom('https://poppy.example.com/api/auth/pair/abc'), 'https://poppy.example.com');
    });

    test('leaves no trailing slash for the client to double up', () {
      expect(serverUrlFrom('http://host:3001/api/auth/pair/abc'), isNot(endsWith('/')));
    });

    test('leaves no stray query marker', () {
      expect(serverUrlFrom('http://host:3001/api/auth/pair/abc?x=1'), isNot(contains('?')));
    });

    test('produces something the client can append a path to', () {
      const base = 'http://10.0.2.2:3001';
      expect(serverUrlFrom('http://10.0.2.2:3001/api/auth/pair/abc'), base);
      expect(Uri.parse('$base/api/embodiment/v1/health').toString(),
          'http://10.0.2.2:3001/api/embodiment/v1/health');
    });
  });
}
