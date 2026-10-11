/// First run: point this phone at a runner by scanning the dashboard's QR code.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../providers/poppy_state.dart';
import '../services/pairing_service.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

/// Shown when the camera cannot start — which on an emulator usually means
/// no webcam was mapped to it, not that anything is wrong.
class _CameraUnavailable extends StatelessWidget {
  final String error;
  final VoidCallback onBack;
  const _CameraUnavailable({required this.error, required this.onBack});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.no_photography, size: 48),
              const SizedBox(height: 14),
              const Text('No camera available.', textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                'On an emulator, start it with a webcam mapped:\n'
                'emulator -avd <name> -camera-back webcam0\n\n'
                'Or go back and paste the pairing link instead.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 18),
              FilledButton(onPressed: onBack, child: const Text('Paste it instead')),
              const SizedBox(height: 10),
              Text(error, textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
      );
}

class _PairingScreenState extends State<PairingScreen> {
  final _pairing = PairingService();
  final _manual = TextEditingController();
  bool _scanning = false;
  bool _busy = false;
  String? _error;

  /// Which attempt is current.
  ///
  /// An in-flight request cannot be called back, so cancelling bumps this
  /// and the late answer is dropped on arrival. Without it, abandoning a
  /// doomed attempt and starting a good one lets the first one land on top
  /// of the second.
  int _attempt = 0;

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  /// Give up on the attempt in flight and hand the form back.
  void _abandon() {
    _attempt++;
    setState(() { _busy = false; _scanning = false; _error = null; });
  }

  Future<void> _redeem(String url) async {
    if (_busy) return;
    final attempt = ++_attempt;
    setState(() { _busy = true; _error = null; });
    try {
      final paired = await _pairing.redeem(url);
      if (!mounted || attempt != _attempt) return;
      await context.read<PoppyState>().completePairing(paired);
    } on PairingException catch (err) {
      if (mounted && attempt == _attempt) {
        setState(() { _error = err.message; _scanning = false; });
      }
    } finally {
      if (mounted && attempt == _attempt) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Unpairing is one tap from the main screen, so a mis-tap lands here with
    // nothing behind it. If that is how we arrived, offer the way back.
    final canGoBack = context.watch<PoppyState>().canCancelPairing;

    if (_scanning) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Scan the code'),
          leading: IconButton(
            tooltip: 'Stop scanning',
            icon: const Icon(Icons.close),
            onPressed: _abandon,
          ),
        ),
        body: MobileScanner(
          onDetect: (capture) {
            final value = capture.barcodes.firstOrNull?.rawValue;
            if (value != null && !_busy) _redeem(value);
          },
          // An emulator with no camera configured shows a black rectangle
          // otherwise, which reads as "broken" rather than "not set up".
          errorBuilder: (context, error, _) => _CameraUnavailable(
            error: error.errorDetails?.message ?? error.errorCode.name,
            onBack: _abandon,
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.face_retouching_natural, size: 72),
                const SizedBox(height: 16),
                Text('Poppy In Your Pocket',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  'Open the HATS dashboard, generate a pairing code, and scan it. '
                  'Poppy runs on your own machine — this only tells the phone where to find her.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: _busy ? null : () => setState(() => _scanning = true),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan pairing code'),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _manual,
                  enabled: !_busy,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'or paste the pairing link',
                    hintText: 'http://10.0.2.2:3001/api/auth/pair/…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: _redeem,
                ),
                const SizedBox(height: 10),
                if (_busy)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 16, width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 12),
                      TextButton(onPressed: _abandon, child: const Text('Cancel')),
                    ],
                  )
                else
                  TextButton(
                    onPressed: () => _redeem(_manual.text),
                    child: const Text('Pair'),
                  ),
                if (canGoBack && !_busy) ...[
                  const SizedBox(height: 4),
                  TextButton.icon(
                    onPressed: () => context.read<PoppyState>().cancelPairing(),
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: const Text('Back to Poppy'),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
