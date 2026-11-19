package com.unbound.music

import com.ryanheise.audioservice.AudioServiceActivity

// Extending AudioServiceActivity (per the audio_service docs) so the
// foreground audio service shares this activity's Flutter engine.
// That is what lets playback keep going with the screen off and lets
// lock-screen / headphone / car controls reach the player.
class MainActivity : AudioServiceActivity()
