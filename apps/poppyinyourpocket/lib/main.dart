/// Poppy In Your Pocket.
///
/// One agent, with a face and a voice, reached through the HATS Embodiment
/// API. See PLAN.md for how the pieces fit and what is still missing.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/poppy_state.dart';
import 'screens/pairing_screen.dart';
import 'screens/poppy_screen.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => PoppyState()..restore(),
      child: const PoppyApp(),
    ),
  );
}

class PoppyApp extends StatelessWidget {
  const PoppyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Poppy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C5CFF),
          brightness: Brightness.dark,
        ),
      ),
      home: Consumer<PoppyState>(
        builder: (_, state, __) => state.isPaired ? const PoppyScreen() : const PairingScreen(),
      ),
    );
  }
}
