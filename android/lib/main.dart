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
import 'widgets/teleport_transition.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Edge-to-edge, declared explicitly so the behaviour is intentional
  // and identical on pre-Android-15 devices (Flutter 3.27+ already
  // opts target-35 apps in by default). The app draws behind the
  // status and navigation bars; the bars stay visible as transparent
  // overlays, and the app's own #010E28 background shows through.
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

class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin {
  TabKey _tab = TabKey.home;
  final _sheetController = DraggableScrollableController();
  // The mini-player header is a fixed height so the sheet's minimum
  // size is exact: drag handle + PlayerBar + padding.
  static const double _miniPlayerHeight = 84;
  bool _sheetExpanded = false;

  // Teleport for tab switches (Daniel, 2026-11-24, v2): four
  // effects (twist / portal / flip / swoop), picked at random and
  // never the same twice in a row, on every screen change. The tab
  // content teleports out, the tab swaps at the midpoint, then the
  // new tab teleports in from the other direction. The IndexedStack
  // stays in place so no tab loses its scroll position or state;
  // only the container teleports. The sheet (mini-player) is not
  // part of the effect — it is the persistent player.
  //
  // Why the sheet collapses on a switch (navigation calm, from the
  // Musify/Spotify comparison): a half-open sheet covers the bottom
  // half of the new tab, so every switch showed a different amount
  // of content. Collapsing to the mini-player means every switch
  // lands on the full tab, the same way, every time.
  late final AnimationController _teleportController;
  late final Animation<double> _teleportCurved;
  TabKey? _pendingTab;
  TeleportEffect _teleportEffect = TeleportEffect.twist;
  // The sheet's minimum size as a fraction of the body height,
  // computed in the LayoutBuilder below (mini-player height /
  // body height). Cached here so the sheet can be collapsed from
  // anywhere (tab switch, back button, re-tap).
  double _miniFraction = 0.1;

  @override
  void initState() {
    super.initState();
    _sheetController.addListener(_onSheetSizeChanged);
    _teleportController = AnimationController(
      vsync: this,
      duration: teleportDuration,
    );
    _teleportCurved = CurvedAnimation(
      parent: _teleportController,
      curve: Curves.easeInOut,
    );
    _teleportController.addListener(_onTeleportTick);
    // Menu actions (Go to Queue, Go to artist) ask AppState for a
    // tab switch; the shell is the only place that can do it.
    widget.state.addListener(_onStateNavigationRequest);
  }

  @override
  void dispose() {
    _teleportController.removeListener(_onTeleportTick);
    _teleportController.dispose();
    _sheetController.removeListener(_onSheetSizeChanged);
    _sheetController.dispose();
    widget.state.removeListener(_onStateNavigationRequest);
    super.dispose();
  }

  void _onStateNavigationRequest() {
    final request = widget.state.tabRequest;
    if (request == null) return;
    widget.state.clearTabRequest();
    _switchToTab(request);
  }

  void _onTeleportTick() {
    // Swap the tab at the visual midpoint of the effect, once per
    // switch. If a second tap arrived mid-twist, _pendingTab holds
    // the newest tab and the swap picks it up — rapid taps never
    // lose their destination, and if the twist is already past its
    // midpoint the swap happens on the next tick.
    final pending = _pendingTab;
    if (pending != null &&
        pending != _tab &&
        _teleportCurved.value >= 0.5) {
      _pendingTab = null;
      setState(() => _tab = pending);
    }
  }

  void _collapseSheet() {
    if (_sheetController.isAttached) {
      _sheetController.animateTo(
        _miniFraction,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _switchToTab(TabKey next) {
    if (next == _tab && !_teleportController.isAnimating) {
      // Re-tapping the current tab is the "home base" reset:
      // collapse the sheet to the mini-player. (Musify resets the
      // tab on re-tap; Unbound's tabs have no deep stacks, so the
      // sheet is the thing that needs resetting.)
      _collapseSheet();
      return;
    }
    if (_teleportController.isAnimating) {
      // A switch is already teleporting: the newest tab wins. The
      // midpoint (or the next tick, if past it) swaps to it, so the
      // tap is never lost and there is no snap from restarting.
      _pendingTab = next;
      _collapseSheet();
      return;
    }
    _pendingTab = next;
    _teleportEffect = TeleportEffectPicker.next();
    _collapseSheet();
    _teleportController.forward(from: 0);
  }

  void _onTabTap(int index) => _switchToTab(TabKey.values[index]);

  /// Android back, deterministic (Musify's rule): an expanded sheet
  /// collapses first, then any tab goes Home, then Home exits the
  /// app. Back never walks a tab history, because there is none.
  void _handleBack() {
    if (_sheetController.isAttached &&
        _sheetController.size > _miniFraction + 0.05) {
      _collapseSheet();
      return;
    }
    if (_tab != TabKey.home) {
      _switchToTab(TabKey.home);
      return;
    }
    SystemNavigator.pop();
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
          child: PopScope(
            // Back is handled by _handleBack (sheet → Home → exit),
            // never by the default pop.
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) _handleBack();
            },
            child: Scaffold(
            body: LayoutBuilder(
              builder: (context, constraints) {
                // The mini fraction must be computed at runtime as
                // mini-player height / body height — never hard-coded —
                // because the sheet's sizes are fractions of its parent.
                // It is cached so the sheet can be collapsed from
                // anywhere (tab switch, back button, re-tap).
                final miniFraction =
                    _miniPlayerHeight / constraints.maxHeight;
                _miniFraction = miniFraction;
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
                      child: AnimatedBuilder(
                        animation: _teleportCurved,
                        builder: (context, child) {
                          return TeleportEffectView(
                            effect: _teleportEffect,
                            t: _teleportCurved.value,
                            child: child!,
                          );
                        },
                        child: IndexedStack(
                          index: _tab.index,
                          children: screens,
                        ),
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
                onTap: _onTabTap,
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
          ),
        );
      },
    );
  }
}
