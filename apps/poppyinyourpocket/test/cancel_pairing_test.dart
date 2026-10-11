/// Getting back out of the pairing screen.
///
/// Unpairing is one tap from the main screen and the pairing screen has
/// nothing behind it, so without a way back a mis-tap meant walking to the
/// machine for a fresh QR code.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:poppy/models/embodied_agent.dart';
import 'package:poppy/providers/poppy_state.dart';
import 'package:poppy/services/embodiment_client.dart';
import 'package:poppy/services/pairing_service.dart';
import 'package:poppy/services/speaker.dart';

class _QuietClient extends EmbodimentClient {
  _QuietClient() : super(baseUrl: 'http://test', apiKey: 'k', httpClient: http.Client());
  @override
  Future<List<EmbodiedAgent>> agents() async => [];
}

/// Pairing that never touches the keychain.
class _MemoryPairing extends PairingService {
  Pairing? stored;
  @override
  Future<Pairing?> load() async => stored;
  @override
  Future<void> save(Pairing p) async => stored = p;
  @override
  Future<void> saveAgentId(String id) async {}
  @override
  Future<String> deviceId() async => 'test-device';
  @override
  Future<void> forget() async => stored = null;
}

/// A runner that accepts the connection and then says nothing, the way a
/// wrong address on the same subnet does.
class _SilentHost extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

const _paul = Pairing(serverUrl: 'http://10.0.10.137:3001', apiKey: 'k', username: 'paul');

void main() {
  late _MemoryPairing store;
  late PoppyState state;

  setUp(() {
    store = _MemoryPairing();
    state = PoppyState(
      pairing: store,
      clientFactory: (_) => _QuietClient(),
      speakerFactory: (_, __) => const SilentSpeaker(),
    );
  });

  group('cancelling out of the pairing screen', () {
    test('offers no way back on a genuine first run', () {
      // There is nothing behind the pairing screen the first time, and a
      // cancel that goes nowhere is worse than none.
      expect(state.canCancelPairing, isFalse);
    });

    test('offers a way back after an accidental unpair', () async {
      await state.completePairing(_paul);
      await state.forget();

      expect(state.isPaired, isFalse);
      expect(state.canCancelPairing, isTrue);
    });

    test('cancelling puts the pairing back, keychain included', () async {
      await state.completePairing(_paul);
      await state.forget();
      expect(store.stored, isNull);

      await state.cancelPairing();

      expect(state.isPaired, isTrue);
      expect(state.pairing?.serverUrl, _paul.serverUrl);
      expect(state.pairing?.apiKey, _paul.apiKey);
      // Restored to storage too, or it would vanish again on the next launch.
      expect(store.stored?.apiKey, _paul.apiKey);
    });

    test('only once — a cancelled pairing is not a second copy of the key', () async {
      await state.completePairing(_paul);
      await state.forget();
      await state.cancelPairing();

      expect(state.canCancelPairing, isFalse);
    });

    test('pairing with somewhere new closes the way back', () async {
      // Otherwise "cancel" would silently return to the runner you just left.
      await state.completePairing(_paul);
      await state.forget();
      await state.completePairing(
        const Pairing(serverUrl: 'http://10.0.10.150:3001', apiKey: 'k2', username: 'paul'),
      );

      expect(state.canCancelPairing, isFalse);
    });

    test('cancelling with nothing to go back to does nothing', () async {
      await state.cancelPairing();
      expect(state.isPaired, isFalse);
    });
  });

  group('an attempt that will never answer', () {
    test('gives up rather than hanging the screen behind it', () async {
      final service = PairingService(httpClient: _SilentHost());

      await expectLater(
        service.redeem('http://10.0.10.99:3001/api/auth/pair/abc',
            timeout: const Duration(milliseconds: 50)),
        throwsA(isA<PairingException>()),
      );
    });

    test('names the address, and says where to find the right one', () async {
      final service = PairingService(httpClient: _SilentHost());

      try {
        await service.redeem('http://10.0.10.99:3001/api/auth/pair/abc',
            timeout: const Duration(milliseconds: 50));
        fail('should have given up');
      } on PairingException catch (err) {
        expect(err.message, contains('10.0.10.99:3001'));
        expect(err.message, contains('dashboard'));
      }
    });
  });
}
