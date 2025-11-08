import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

/// Background audio handler for playback and media commands.
class RadioAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final _player = AudioPlayer();
  int _currentIndex = 0;
  List<MediaItem> _items = const [];
  bool _sessionConfigured = false;

  RadioAudioHandler() {
    // Forward player state into PlaybackState.
    _player.playbackEventStream.listen((event) {
      final playing = _player.playing;
      playbackState.add(
        PlaybackState(
          controls: [
            MediaControl.skipToPrevious,
            if (playing) MediaControl.pause else MediaControl.play,
            MediaControl.stop,
            MediaControl.skipToNext,
          ],
          systemActions: const {MediaAction.seek},
          androidCompactActionIndices: const [0, 1, 3],
          processingState: _mapProcessingState(_player.processingState),
          playing: playing,
          updatePosition: _player.position,
          bufferedPosition: _player.bufferedPosition,
          speed: _player.speed,
        ),
      );
    });

    // Update title from ICY metadata when the server provides it.
    _player.icyMetadataStream.listen((icy) {
      if (icy == null) return;
      final info = icy.info?.title ?? icy.headers?.name;
      final current = mediaItem.valueOrNull;
      if (current != null && info != null && info.isNotEmpty) {
        mediaItem.add(current.copyWith(title: info));
      }
    });
  }

  /// Initial queue setup. Sets the audio source for the starting item.
  Future<void> init(List<MediaItem> items, {int startIndex = 0}) async {
    _items = items;
    queue.add(items);
    if (_items.isEmpty) return;

    _currentIndex =
    (startIndex >= 0 && startIndex < items.length) ? startIndex : 0;
    mediaItem.add(items[_currentIndex]);

    if (!_sessionConfigured) {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _sessionConfigured = true;
    }

    await _player.setAudioSource(
      AudioSource.uri(Uri.parse(items[_currentIndex].id)),
    );
  }

  /// Update queue without interrupting playback when the current URL stays the same.
  ///
  /// - [preserveByUrl]: if provided, tries to keep playing this URL.
  ///   If omitted, the current mediaItem's id is used.
  /// - If the current URL no longer exists (e.g., deleted), switches to the
  ///   resolved [_currentIndex] and resumes playback if it was playing.
  Future<void> refreshQueue(
      List<MediaItem> items, {
        String? preserveByUrl,
      }) async {
    final wasPlaying = _player.playing;
    final currentId = preserveByUrl ?? mediaItem.valueOrNull?.id;

    _items = items;
    queue.add(_items);

    if (_items.isEmpty) {
      // Nothing to play.
      await _player.stop();
      return;
    }

    // Try to restore index by URL/id.
    int targetIndex = _currentIndex.clamp(0, _items.length - 1);
    if (currentId != null) {
      final idx = _items.indexWhere((m) => m.id == currentId);
      if (idx != -1) targetIndex = idx;
    }

    final targetId = _items[targetIndex].id;

    // If URL didn't change, avoid resetting AudioSource => no gap.
    if (currentId != null && currentId == targetId) {
      _currentIndex = targetIndex;
      mediaItem.add(_items[_currentIndex]); // keep UI metadata in sync
      return;
    }

    // URL changed (e.g., current station was removed): switch explicitly.
    _currentIndex = targetIndex;
    mediaItem.add(_items[_currentIndex]);
    await _player.setAudioSource(AudioSource.uri(Uri.parse(targetId)));
    if (wasPlaying) {
      await _player.play();
    }
  }

  // Basic commands
  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    return super.stop();
    // super.stop() not strictly required, but keeps BaseAudioHandler semantics.
  }

  @override
  Future<void> skipToNext() async {
    if (_items.isEmpty) return;
    _currentIndex = (_currentIndex + 1) % _items.length;
    await _switchTo(_currentIndex);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_items.isEmpty) return;
    _currentIndex = (_currentIndex - 1 + _items.length) % _items.length;
    await _switchTo(_currentIndex);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (_items.isEmpty) return;
    _currentIndex = index.clamp(0, _items.length - 1);
    await _switchTo(_currentIndex);
  }

  Future<void> setVolume(double v) async =>
      _player.setVolume(v.clamp(0.0, 1.0));

  Future<void> _switchTo(int index) async {
    final item = _items[index];
    mediaItem.add(item);
    await _player.setAudioSource(AudioSource.uri(Uri.parse(item.id)));
    await _player.play();
  }

  AudioProcessingState _mapProcessingState(ProcessingState s) {
    switch (s) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }
}
