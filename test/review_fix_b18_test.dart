import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the B18 WebView legacy-page fixes at the asset source level. These
/// pages execute inside a WebView, so a Flutter widget test cannot run their
/// JavaScript; asserting the served assets keeps the corrected contracts
/// (playable-audio fallback and the supported tab/search boundary) from
/// silently regressing.
void main() {
  String asset(String name) => File('assets/web/$name').readAsStringSync();

  test('listen page falls back to the audio playback endpoint for a URL', () {
    final listen = asset('listen.html');
    expect(listen, contains('/api/v1/audio/play'));
    expect(listen, contains('fetchPlaybackURL(current.id, requestedToneId)'));
    expect(listen, contains('video_model_datas'));
  });

  test('index search exposes only novel and audiobook tabs', () {
    final index = asset('index.html');
    expect(index, contains('const fanqieTabs = ["小说", "听书"]'));
    expect(index, contains('const searchTabTypes = { "小说": 3, "听书": 2 }'));
    expect(index, isNot(contains('video.series_id')));
    expect(index, isNot(contains('comic.html')));
  });
}
