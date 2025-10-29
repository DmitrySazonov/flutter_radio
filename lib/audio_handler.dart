import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

/// Обработчик фонового воспроизведения и медиакоманд.
class RadioAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final _player = AudioPlayer();
  int _currentIndex = 0;
  List<MediaItem> _items = const [];

  RadioAudioHandler() {
    // Пробрасываем состояние плеера в PlaybackState
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

    // Обновляем заголовок из ICY-метаданных, если сервер их шлёт.
    _player.icyMetadataStream.listen((icy) {
      if (icy == null) return;
      final info = icy.info?.title ?? icy.headers?.name;
      final current = mediaItem.valueOrNull;
      if (current != null && info != null && info.isNotEmpty) {
        mediaItem.add(current.copyWith(title: info));
      }
    });
  }

  Future<void> init(List<MediaItem> items, {int startIndex = 0}) async {
    _items = items;
    queue.add(items);
    _currentIndex = (startIndex >= 0 && startIndex < items.length) ? startIndex : 0;
    mediaItem.add(items[_currentIndex]);

    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    await _player.setAudioSource(
      AudioSource.uri(Uri.parse(items[_currentIndex].id)),
    );
  }

  // Базовые команды
  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    return super.stop();
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
