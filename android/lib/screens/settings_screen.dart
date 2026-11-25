// Unbound Muzik — Settings screen.
//
// Built 2026-11-21 from the wow-version-spec proposal (filed 2026-11-14):
// a gear icon on Home opens this screen. It holds the two toggles that
// used to clutter Home and the Radio tab — "External recommendations"
// and "Keep playing after the queue ends" — so Home is Now Playing +
// recommendations only. Nothing here is a daily task: set it once and
// it stays.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme/unbound_theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _sectionTitle('Playback'),
              CheckboxListTile(
                value: state.radioAutoPlay,
                activeColor: UnboundColors.aqua,
                title: const Text('Keep playing after the queue ends'),
                subtitle: const Text(
                  'Pull in one more related song instead of stopping. '
                  'Off means the queue ends cleanly, the way the web app does.',
                  style: TextStyle(color: UnboundColors.textDim),
                ),
                onChanged: (v) {
                  if (v != null) state.toggleRadioAutoPlay(v);
                },
              ),
              _sectionTitle('Recommendations'),
              CheckboxListTile(
                value: state.externalRecs,
                activeColor: UnboundColors.aqua,
                title: const Text('External recommendations'),
                subtitle: const Text(
                  'Expand picks from YouTube related videos. Off means '
                  'your own mix only: liked, recent, and playlists. '
                  'No network.',
                  style: TextStyle(color: UnboundColors.textDim),
                ),
                onChanged: (v) {
                  if (v != null) state.toggleExternalRecs(v);
                },
              ),
              _sectionTitle('App'),
              const ListTile(
                title: Text('Version'),
                trailing: Text(
                  '0.1.0',
                  style: TextStyle(color: UnboundColors.textDim),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Text(
                  'Unbound is free forever. No ads from the app, no tracking, no account.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: UnboundColors.textFaint,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

Widget _sectionTitle(String title) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(0, 20, 0, 4),
    child: Text(
      title,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
    ),
  );
}
