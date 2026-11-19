// Unbound Muzik — Android app (Flutter).
//
// Free and ad-free forever, for one person. No account, no tracking,
// no paywall — ever. This is the "flawless room" body of Unbound:
// a real Android app with a foreground audio service, so music keeps
// playing with the screen off, from the lock screen, headphones and
// the car. It carries the grey lane openly (Decision 7): search,
// streams and related videos come from YouTube's internal endpoints
// through the public youtube_explode_dart library, with no API key
// and no quota. That path can break when YouTube changes its hidden
// systems, and a play here is not counted the same way as a play
// through the official player. The web app stays in the official
// lane; this app is where the direct path lives.

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'models/track.dart';
import 'screens/screens.dart';
import 'services/audio_handler.dart';
import 'services/downloads_service.dart';
import 'services/storage_service.dart';
import 'services/youtube_service.dart';
import 'theme/unbound_theme.dart';
import 'widgets/now_playing_sheet.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Edge-to-edge, declared explicitly so the behaviour is intentional
  // and identical on pre-Android-15 devices (Flutter 3.27+ already
  // opts target-35 apps in by default). The app draws behind the
  // status and navigation bars; the bars stay visible as transparent
  // overlays, and the app's own #050505 background shows through.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  final storage = await StorageService.create();
  final youtube = YoutubeService();
  final downloads = DownloadsService(youtube);

  // Tell Android this app plays music: it gets audio focus properly
  // and ducking/pause behaviour on calls and notifications.
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());

  // The foreground audio service. Pausing must NOT kill the service
  // (androidStopForegroundOnPause: false, like Musify). Note:
  // androidNotificationOngoing must stay false with that setting — the
  // foreground service forces the notification ongoing anyway.
  final handler = await AudioService.init(
    builder: () => UnboundAudioHandler(
      youtube: youtube,
      storage: storage,
      downloads: downloads,
    ),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.unbound.music.playback',
      androidNotificationChannelName: 'Unbound Muzik playback',
      androidStopForegroundOnPause: false,
      androidNotificationClickStartsActivity: true,
      // Bound decoded notification-art bitmap memory: 512×512 is the
      // sweet spot (sharp on any current phone, ~1 MB as ARGB_8888). A
      // 1280×720 maxres source would otherwise decode to ~3.7 MB and be
      // downscaled by the system anyway.
      artDownscaleWidth: 512,
      artDownscaleHeight: 512,
    ),
  );

  final state = AppState(
    storage: storage,
    youtube: youtube,
    downloads: downloads,
    handler: handler,
  );

  runApp(UnboundApp(state: state));
}

class UnboundApp extends StatelessWidget {
  const UnboundApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Unbound Muzik',
      theme: UnboundTheme.dark(),
      debugShowCheckedModeBanner: false,
      home: HomeShell(state: state),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state});

  final AppState state;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  TabKey _tab = TabKey.home;
  final _sheetController = DraggableScrollableController();
  // The mini-player header is a fixed height so the sheet's minimum
  // size is exact: drag handle + PlayerBar + padding.
  static const double _miniPlayerHeight = 84;
  bool _sheetExpanded = false;

  @override
  void initState() {
    super.initState();
    _sheetController.addListener(_onSheetSizeChanged);
  }

  @override
  void dispose() {
    _sheetController.removeListener(_onSheetSizeChanged);
    _sheetController.dispose();
    super.dispose();
  }

  void _onSheetSizeChanged() {
    // Fade the bottom nav bar out once the sheet passes ~0.7.
    // Only rebuild when the expanded/collapsed state flips, not on
    // every pixel of the drag.
    if (!_sheetController.isAttached) return;
    final expanded = _sheetController.size > 0.7;
    if (expanded != _sheetExpanded) {
      setState(() => _sheetExpanded = expanded);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final screens = <Widget>[
          HomeScreen(state: widget.state),
          SearchScreen(state: widget.state),
          LibraryScreen(state: widget.state),
          QueueScreen(state: widget.state),
          RadioScreen(state: widget.state),
        ];
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: UnboundTheme.systemUiOverlayStyle,
          child: Scaffold(
            body: LayoutBuilder(
              builder: (context, constraints) {
                // The mini fraction must be computed at runtime as
                // mini-player height / body height — never hard-coded —
                // because the sheet's sizes are fractions of its parent.
                final miniFraction =
                    _miniPlayerHeight / constraints.maxHeight;
                return Stack(
                  children: [
                    // One inset owner per edge: the body owns the top
                    // (status bar / punch-hole camera). The bottom inset
                    // is owned by the stock BottomNavigationBar, which
                    // adds it itself — a bottom SafeArea here would
                    // double-pad.
                    SafeArea(
                      top: true,
                      bottom: false,
                      child: IndexedStack(
                        index: _tab.index,
                        children: screens,
                      ),
                    ),
                  DraggableScrollableSheet(
                    controller: _sheetController,
                    initialChildSize: miniFraction,
                    minChildSize: miniFraction,
                    maxChildSize: 0.95,
                    snap: true,
                    snapSizes: [miniFraction, 0.55, 0.95],
                    snapAnimationDuration:
                        const Duration(milliseconds: 300),
                    builder: (context, scrollController) {
                      return NowPlayingSheet(
                        scrollController: scrollController,
                        state: widget.state,
                        miniPlayerHeight: _miniPlayerHeight,
                        onExpand: () {
                          if (_sheetController.isAttached) {
                            _sheetController.animateTo(
                              0.95,
                              duration: const Duration(milliseconds: 350),
                              curve: Curves.easeOut,
                            );
                          }
                        },
                        onCollapse: () {
                          if (_sheetController.isAttached) {
                            _sheetController.animateTo(
                              miniFraction,
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeInOut,
                            );
                          }
                        },
                      );
                    },
                  ),
                ],
              );
            },
          ),
          bottomNavigationBar: AnimatedOpacity(
            opacity: _sheetExpanded ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: _sheetExpanded,
              child: BottomNavigationBar(
                currentIndex: _tab.index,
                onTap: (index) {
                  setState(() => _tab = TabKey.values[index]);
                },
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.home),
                    label: 'Home',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.search),
                    label: 'Search',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.library_music),
                    label: 'Library',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.queue_music),
                    label: 'Queue',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.radio),
                    label: 'Radio',
                  ),
                ],
              ),
            ),
          ),
          ),
        );
      },
    );
  }
}
