// main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import 'stations.dart';
import 'storage.dart';

void main() {
  // Инициализируем биндинги как можно раньше
  WidgetsFlutterBinding.ensureInitialized();

  // Catch framework-level Flutter errors
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    dev.log(
      'Flutter framework error',
      error: details.exception,
      stackTrace: details.stack,
    );
  };

  // Catch uncaught async errors (outside zones)
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    dev.log('Uncaught async error', error: error, stackTrace: stack);
    // return false so the platform can also handle it if needed
    return false;
  };

  // Protected zone for all async work
  runZonedGuarded(() async {
    // Immersive at start
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ));

    RadioAudioHandler handler;
    try {
      handler = await AudioService.init(
        builder: () => RadioAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId:
          'com.example.flutter_radio.channel.audio',
          androidNotificationChannelName: 'Radio Playback',
          // важно: ongoing = false, чтобы не триггерить assert
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: false,
        ),
      );
    } catch (e, st) {
      dev.log('AudioService.init failed', error: e, stackTrace: st);
      handler = RadioAudioHandler();
    }

    runApp(MyApp(handler: handler));
  }, (error, stack) {
    dev.log('Uncaught zone error', error: error, stackTrace: stack);
  });
}

class MyApp extends StatelessWidget {
  final RadioAudioHandler handler;
  const MyApp({super.key, required this.handler});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Radio',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorSchemeSeed: Colors.blueGrey,
      ),
      home: HomePage(handler: handler),
    );
  }
}

// -------------------- AUDIO HANDLER ----------------------

class RadioAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player = AudioPlayer();
  List<MediaItem> _items = const [];
  int _currentIndex = 0;
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

    // Update title from ICY metadata.
    _player.icyMetadataStream.listen((icy) {
      final info = icy?.info?.title ?? icy?.headers?.name;
      final current = mediaItem.valueOrNull;
      if (current != null && info != null && info.isNotEmpty) {
        mediaItem.add(current.copyWith(title: info));
      }
    });
  }

  /// Initial queue setup. Sets the audio source for the starting item.
  Future<void> init(List<MediaItem> items, {int startIndex = 0}) async {
    _items = items;
    queue.add(_items);
    if (_items.isEmpty) return;

    _currentIndex = startIndex.clamp(0, _items.length - 1);
    mediaItem.add(_items[_currentIndex]);

    if (!_sessionConfigured) {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _sessionConfigured = true;
    }

    await _player.setAudioSource(
      AudioSource.uri(Uri.parse(_items[_currentIndex].id)),
    );
  }

  /// Update queue WITHOUT resetting the current AudioSource if URL stays the same.
  Future<void> refreshQueue(
      List<MediaItem> items, {
        String? preserveByUrl,
      }) async {
    final wasPlaying = _player.playing;
    final currentId = preserveByUrl ?? mediaItem.valueOrNull?.id;

    _items = items;
    queue.add(_items);

    if (_items.isEmpty) {
      await _player.stop();
      return;
    }

    int targetIndex = _currentIndex.clamp(0, _items.length - 1);
    if (currentId != null) {
      final idx = _items.indexWhere((m) => m.id == currentId);
      if (idx != -1) targetIndex = idx;
    }

    final targetId = _items[targetIndex].id;

    // Same URL — keep playing seamlessly.
    if (currentId != null && currentId == targetId) {
      _currentIndex = targetIndex;
      mediaItem.add(_items[_currentIndex]); // sync title/name
      return;
    }

    // URL changed (e.g., current removed) — switch explicitly.
    _currentIndex = targetIndex;
    mediaItem.add(_items[_currentIndex]);
    try {
      await _player.setAudioSource(AudioSource.uri(Uri.parse(targetId)));
      if (wasPlaying) {
        await _player.play();
      }
    } catch (e, st) {
      dev.log('refreshQueue switch failed', error: e, stackTrace: st);
    }
  }

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
    if (_items.isEmpty) return;
    if (index < 0 || index >= _items.length) return;

    final item = _items[index];
    mediaItem.add(item);
    try {
      await _player.setAudioSource(AudioSource.uri(Uri.parse(item.id)));
      await _player.play();
    } catch (e, st) {
      dev.log('switchTo failed', error: e, stackTrace: st);
    }
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

// -------------------- WEB SERVER ----------------------

class WebRemoteServer {
  HttpServer? _server;
  final RadioAudioHandler handler;
  final int port;
  final String? token;

  // State providers from UI
  final List<Station> Function() getStations;
  final int Function() getCurrentIndex;
  final String? Function() getNowTitle;
  final double Function() getVolume;
  final Future<void> Function(double) onVolumeChanged;

  // live / soft pause
  final bool Function() getStartLiveOnResume;
  final bool Function() getSoftPaused;
  final Future<void> Function() onSoftPause;
  final Future<void> Function() onSoftResume;

  // stations ops
  final Future<bool> Function(String name, String url) onAddStation;
  final Future<bool> Function(int index) onDeleteStation;
  final Future<bool> Function(int oldIndex, int newIndex) onReorderStations;

  // settings
  final Future<void> Function(bool enabled) onSetStartLive;

  WebRemoteServer({
    required this.handler,
    required this.getStations,
    required this.getCurrentIndex,
    required this.getNowTitle,
    required this.getVolume,
    required this.onVolumeChanged,
    required this.onAddStation,
    required this.onDeleteStation,
    required this.onReorderStations,
    required this.getStartLiveOnResume,
    required this.getSoftPaused,
    required this.onSoftPause,
    required this.onSoftResume,
    required this.onSetStartLive,
    this.port = 8080,
    this.token,
  });

  bool get isRunning => _server != null;

  Future<void> start({InternetAddress? address}) async {
    if (_server != null) return;
    final bindAddr = address ?? InternetAddress.anyIPv4;
    _server = await HttpServer.bind(bindAddr, port);
    _server!.listen(_handleRequest, onError: (e, st) {
      dev.log('Web server error', error: e, stackTrace: st);
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  bool _checkAuth(HttpRequest req) {
    if (token == null) return true;
    final got =
        req.uri.queryParameters['token'] ?? req.headers.value('x-api-key');
    return got == token;
  }

  void _setCors(HttpResponse res) {
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
    res.headers
        .set('Access-Control-Allow-Headers', 'Content-Type,X-API-Key');
  }

  void _writeJson(HttpResponse res, String json, [int code = 200]) {
    res.statusCode = code;
    res.headers.contentType = ContentType.json;
    res.write(json);
  }

  Future<Map<String, dynamic>?> _readJson(HttpRequest req) async {
    try {
      final body = await utf8.decoder.bind(req).join();
      if (body.isEmpty) return {};
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _handleRequest(HttpRequest req) async {
    _setCors(req.response);
    if (req.method == 'OPTIONS') {
      await req.response.close();
      return;
    }

    // static (web remote + settings)
    if (req.uri.path == '/' || req.uri.path == '/index.html') {
      final html = _htmlIndex(token: token);
      req.response.headers.contentType = ContentType.html;
      req.response.write(html);
      await req.response.close();
      return;
    }

    if (!_checkAuth(req)) {
      req.response.statusCode = HttpStatus.unauthorized;
      req.response.write('Unauthorized');
      await req.response.close();
      return;
    }

    try {
      switch (req.uri.path) {
        case '/play':
          if (getStartLiveOnResume() && getSoftPaused()) {
            await onSoftResume();
            _writeJson(req.response, '{"ok":true,"state":"playing"}');
          } else {
            await handler.play();
            _writeJson(req.response, '{"ok":true,"state":"playing"}');
          }
          break;

        case '/pause':
          if (getStartLiveOnResume()) {
            await onSoftPause();
            _writeJson(req.response, '{"ok":true,"state":"paused"}');
          } else {
            await handler.pause();
            _writeJson(req.response, '{"ok":true,"state":"paused"}');
          }
          break;

        case '/stop':
          await handler.stop();
          _writeJson(req.response, '{"ok":true,"state":"stopped"}');
          break;

        case '/next':
          await handler.skipToNext();
          _writeJson(req.response, '{"ok":true}');
          break;

        case '/prev':
          await handler.skipToPrevious();
          _writeJson(req.response, '{"ok":true}');
          break;

        case '/volume':
          {
            final vStr = req.uri.queryParameters['value'];
            final v = double.tryParse(vStr ?? '');
            if (v == null || v.isNaN) {
              _writeJson(
                  req.response,
                  '{"ok":false,"error":"value 0..1 required"}',
                  400);
              break;
            }
            final vol = v.clamp(0.0, 1.0);
            if (getSoftPaused()) {
              await onVolumeChanged(vol);
            } else {
              await handler.setVolume(vol);
              await onVolumeChanged(vol);
            }
            _writeJson(req.response, '{"ok":true,"volume":$vol}');
            break;
          }

        case '/select':
          {
            final idxStr = req.uri.queryParameters['index'];
            final idx = int.tryParse(idxStr ?? '');
            final stations = getStations();
            if (idx == null || idx < 0 || idx >= stations.length) {
              _writeJson(req.response,
                  '{"ok":false,"error":"bad index"}', 400);
              break;
            }
            await handler.skipToQueueItem(idx);
            _writeJson(req.response, '{"ok":true}');
            break;
          }

      // stations list (short)
        case '/stations':
          {
            final stations = getStations();
            final cur = getCurrentIndex();
            final buf =
            StringBuffer('{"ok":true,"current":$cur,"items":[');
            for (var i = 0; i < stations.length; i++) {
              final s = stations[i];
              buf.write('{"index":$i,"name":${_j(s.name)}}');
              if (i != stations.length - 1) buf.write(',');
            }
            buf.write(']}');
            _writeJson(req.response, buf.toString());
            break;
          }

      // stations list (full)
        case '/stations/full':
          {
            final stations = getStations();
            final cur = getCurrentIndex();
            final buf =
            StringBuffer('{"ok":true,"current":$cur,"items":[');
            for (var i = 0; i < stations.length; i++) {
              final s = stations[i];
              buf.write(
                  '{"index":$i,"name":${_j(s.name)},"url":${_j(s.url)}}');
              if (i != stations.length - 1) buf.write(',');
            }
            buf.write(']}');
            _writeJson(req.response, buf.toString());
            break;
          }

        case '/stations/add':
          {
            if (req.method != 'POST') {
              _writeJson(req.response,
                  '{"ok":false,"error":"POST required"}', 405);
              break;
            }
            final data = await _readJson(req);
            if (data == null) {
              _writeJson(req.response,
                  '{"ok":false,"error":"bad json"}', 400);
              break;
            }
            final name = (data['name'] ?? '').toString().trim();
            final url = (data['url'] ?? '').toString().trim();
            if (name.isEmpty || url.isEmpty) {
              _writeJson(
                  req.response,
                  '{"ok":false,"error":"name and url required"}',
                  400);
              break;
            }
            final ok = await onAddStation(name, url);
            _writeJson(
                req.response, ok ? '{"ok":true}' : '{"ok":false}');
            break;
          }

        case '/stations/delete':
          {
            if (req.method != 'POST') {
              final idx =
              int.tryParse(req.uri.queryParameters['index'] ?? '');
              if (idx == null) {
                _writeJson(
                    req.response,
                    '{"ok":false,"error":"POST or index param"}',
                    400);
                break;
              }
              final ok = await onDeleteStation(idx);
              _writeJson(
                req.response,
                ok ? '{"ok":true}' : '{"ok":false}',
                ok ? 200 : 400,
              );
              break;
            }
            final data = await _readJson(req);
            if (data == null || !data.containsKey('index')) {
              _writeJson(req.response,
                  '{"ok":false,"error":"index required"}', 400);
              break;
            }
            final idx = int.tryParse(data['index'].toString());
            if (idx == null) {
              _writeJson(req.response,
                  '{"ok":false,"error":"bad index"}', 400);
              break;
            }
            final ok = await onDeleteStation(idx);
            _writeJson(
              req.response,
              ok ? '{"ok":true}' : '{"ok":false}',
              ok ? 200 : 400,
            );
            break;
          }

        case '/stations/reorder':
          {
            if (req.method != 'POST') {
              _writeJson(req.response,
                  '{"ok":false,"error":"POST required"}', 405);
              break;
            }
            final data = await _readJson(req);
            if (data == null) {
              _writeJson(req.response,
                  '{"ok":false,"error":"bad json"}', 400);
              break;
            }
            final oldIdx = int.tryParse(data['old'].toString());
            final newIdx = int.tryParse(data['new'].toString());
            if (oldIdx == null || newIdx == null) {
              _writeJson(
                  req.response,
                  '{"ok":false,"error":"old/new required"}',
                  400);
              break;
            }
            final ok = await onReorderStations(oldIdx, newIdx);
            _writeJson(
              req.response,
              ok ? '{"ok":true}' : '{"ok":false}',
              ok ? 200 : 400,
            );
            break;
          }

        case '/settings':
          if (req.method == 'GET') {
            final live = getStartLiveOnResume();
            _writeJson(req.response,
                '{"ok":true,"startLiveOnResume":$live}');
          } else if (req.method == 'POST') {
            final data = await _readJson(req);
            if (data == null ||
                !data.containsKey('startLiveOnResume')) {
              _writeJson(
                  req.response,
                  '{"ok":false,"error":"startLiveOnResume required"}',
                  400);
              break;
            }
            final live = data['startLiveOnResume'] == true ||
                data['startLiveOnResume'].toString() == 'true';
            await onSetStartLive(live);
            _writeJson(req.response,
                '{"ok":true,"startLiveOnResume":$live}');
          } else {
            _writeJson(req.response,
                '{"ok":false,"error":"GET or POST"}', 405);
          }
          break;

        case '/status':
          {
            final stations2 = getStations();
            final cur2 = getCurrentIndex();
            final now = getNowTitle();
            final vol = getVolume();
            final st = handler.playbackState.value;
            final soft = getSoftPaused();
            final live = getStartLiveOnResume();
            final name = (cur2 >= 0 && cur2 < stations2.length)
                ? stations2[cur2].name
                : null;

            final playingFlag =
            soft ? false : st.playing; // mask soft pause

            _writeJson(
              req.response,
              '{"ok":true,"playing":$playingFlag,"currentIndex":$cur2,'
                  '"station":${_j(name)},"title":${_j(now)},"volume":$vol,'
                  '"softPaused":$soft,"startLiveOnResume":$live}',
            );
            break;
          }

        default:
          req.response.statusCode = HttpStatus.notFound;
          req.response.write('Not found');
      }
    } catch (e, st) {
      dev.log('Web server handler error', error: e, stackTrace: st);
      req.response.statusCode = 500;
      req.response.write('Error: $e');
    } finally {
      await req.response.close();
    }
  }

  String _j(String? s) {
    if (s == null) return 'null';
    final esc = s
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
    return '"$esc"';
  }

  String _htmlIndex({String? token}) {
    final t = token ?? '';
    return '''
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Radio Remote</title>
<style>
  :root{--bg:#000;--fg:#fff;--mut:#bbb;--card:#1f2937;--sel:#22303e;--acc:#4ade80}
  body{background:var(--bg);color:var(--fg);font-family:system-ui,Segoe UI,Roboto,Arial;margin:0}
  .wrap{max-width:640px;margin:0 auto;padding:16px}
  .row{display:flex;gap:8px;justify-content:center;flex-wrap:wrap}
  button{background:var(--card);color:var(--fg);border:0;border-radius:10px;padding:10px 14px;font-size:16px}
  button:active{transform:scale(0.98)}
  .hdr{display:flex;align-items:center;gap:8px}
  .hdr h2{margin:0;flex:1}
  .iconbtn{background:transparent;padding:6px 8px}
  .list{margin-top:12px}
  .item{padding:10px 12px;border-bottom:1px solid #111;display:flex;align-items:center;gap:8px}
  .item.curr{background:var(--sel)}
  .dot{width:10px;height:10px;border-radius:50%;background:var(--acc)}
  .title{color:#9bd;margin:10px 0;min-height:24px}
  .muted{color:var(--mut)}
  .card{background:#0f172a;border-radius:10px;padding:12px;margin-top:12px}
  input[type=text]{width:100%;background:#0b1220;color:#fff;border:1px solid #223;outline:none;border-radius:8px;padding:10px}
  .row2{display:flex;gap:8px}
  .small{padding:6px 8px;border-radius:8px;font-size:14px}
  .hidden{display:none}
  .url{color:#9aa;font-size:12px}
  .drag-handle{ cursor:grab; padding:6px 8px; border-radius:8px; }
  .drag-handle:active{ cursor:grabbing }
  .item.drag-over{ outline:2px dashed var(--acc); outline-offset:-6px }
</style>
</head>
<body>
<div class="wrap">
  <div class="hdr">
    <h2>Radio Remote</h2>
    <button class="iconbtn" title="Settings" onclick="toggleEdit()">⚙️</button>
  </div>

  <div id="view">
    <div id="station" class="title">—</div>
    <div id="now" class="title muted">—</div>
    <div class="row" style="margin:12px 0">
      <button onclick="api('/prev')">⏮️ Prev</button>
      <button id="ppBtn" onclick="togglePlayPause()">▶️ Play</button>
      <button onclick="api('/next')">⏭️ Next</button>
    </div>
    <div style="display:flex;align-items:center;gap:10px;margin:10px 0;">
      <span>🔊</span>
      <input id="vol" type="range" min="0" max="1" step="0.01" value="1" style="flex:1;height:10px;">
    </div>
    <div id="list" class="list"></div>
  </div>

  <div id="edit" class="hidden">
    <div class="card">
      <h3 style="margin:0 0 8px 0;">Settings</h3>
      <div style="display:flex;align-items:center;gap:10px;">
        <input type="checkbox" id="live" />
        <label for="live">Resume from live position (soft pause)</label>
      </div>
      <div id="liveMsg" class="muted" style="margin-top:6px;"></div>
    </div>

    <div class="card">
      <h3 style="margin:0 0 8px 0;">Add station</h3>
      <div class="row2">
        <input id="name" type="text" placeholder="Name">
        <input id="url"  type="text" placeholder="http://...">
      </div>
      <div style="margin-top:8px">
        <button class="small" onclick="addStation()">Add</button>
        <span id="msg" class="muted" style="margin-left:8px"></span>
      </div>
    </div>

    <div class="card">
      <h3 style="margin:0 0 8px 0;">Order & delete</h3>
      <div class="muted" style="font-size:13px;margin-bottom:6px;">Drag the handle to reorder, or delete with the trash button.</div>
      <div id="elist"></div>
    </div>
  </div>
</div>

<script>
const token='${t}';
function qp(url){return token? url+(url.includes('?')?'&':'?')+'token='+encodeURIComponent(token):url}
let settingVol=false;
let gPlaying=false;
let dragIndex = -1;

function setPPBtn(playing){
  const btn = document.getElementById('ppBtn');
  if(!btn) return;
  gPlaying = !!playing;
  btn.textContent = gPlaying ? '⏸️ Pause' : '▶️ Play';
  btn.setAttribute('aria-pressed', gPlaying ? 'true' : 'false');
}

function togglePlayPause(){
  const btn = document.getElementById('ppBtn');
  if(btn){ btn.disabled = true; setTimeout(()=>btn.disabled=false, 350); }
  if(gPlaying){ api('/pause'); } else { api('/play'); }
}

function toggleEdit(){
  document.getElementById('view').classList.toggle('hidden');
  document.getElementById('edit').classList.toggle('hidden');
  if (!document.getElementById('edit').classList.contains('hidden')) {
    buildEdit();
  }
}

async function api(path, method='GET', body=null){
  const opt = {method, headers:{}};
  if (body){ opt.headers['Content-Type']='application/json'; opt.body=JSON.stringify(body); }
  const u = qp(path);
  await fetch(u + (u.includes('?')?'&':'?') + '_=' + Date.now(), opt);
  refresh();
}

async function refresh(){
  try{
    const u = qp('/status');
    const s = await fetch(u + (u.includes('?')?'&':'?') + '_=' + Date.now()).then(r=>r.json());
    document.getElementById('station').textContent = s.station || '—';
    document.getElementById('now').textContent = s.title || '—';
    if (!settingVol && typeof s.volume === 'number') {
      const volEl = document.getElementById('vol');
      if (Math.abs(parseFloat(volEl.value) - s.volume) > 0.001) volEl.value = String(s.volume);
    }
    const liveEl = document.getElementById('live');
    if (liveEl) liveEl.checked = !!s.startLiveOnResume;

    setPPBtn(!!s.playing);
    await rebuildList(s.currentIndex);
  }catch(e){}
}

async function rebuildList(curr){
  const u = qp('/stations');
  const data = await fetch(u + (u.includes('?')?'&':'?') + '_=' + Date.now()).then(r=>r.json());
  const root = document.getElementById('list');
  root.innerHTML = '';
  data.items.forEach(it=>{
    const row = document.createElement('div');
    row.className = 'item' + (it.index===curr?' curr':'');
    const dot = document.createElement('div');
    dot.className = 'dot'; dot.style.visibility = (it.index===curr)?'visible':'hidden';
    const btn = document.createElement('button');
    btn.textContent = it.name;
    btn.style.flex='1';
    btn.onclick = ()=>api('/select?index='+it.index);
    row.appendChild(dot);
    row.appendChild(btn);
    root.appendChild(row);
  });
}

const volEl=document.getElementById('vol');
volEl.addEventListener('input', async (e)=>{
  settingVol=true;
  await fetch(qp('/volume?value='+e.target.value));
  settingVol=false;
});

async function buildEdit(){
  // sync stations
  const u = qp('/stations/full');
  const data = await fetch(u + (u.includes('?')?'&':'?') + '_=' + Date.now()).then(r=>r.json());
  const root = document.getElementById('elist');
  root.innerHTML='';
  const total = data.items.length;

  data.items.forEach(it=>{
    const row = document.createElement('div');
    row.className='item'+(it.index===data.current?' curr':'');
    row.dataset.index = String(it.index);

    // DROP targets
    row.addEventListener('dragover', (e)=>{
      e.preventDefault();
      if (e.dataTransfer) e.dataTransfer.dropEffect = 'move';
      row.classList.add('drag-over');
    });
    row.addEventListener('dragleave', ()=>{
      row.classList.remove('drag-over');
    });
    row.addEventListener('drop', async (e)=>{
      e.preventDefault();
      row.classList.remove('drag-over');
      const ds = row.dataset.index;
      const targetIndex = ds ? parseInt(ds, 10) : NaN;
      if (Number.isNaN(targetIndex) || dragIndex < 0) return;
      if (targetIndex === dragIndex) return;
      // moving down -> insert AFTER target
      let newIdx = (targetIndex > dragIndex) ? (targetIndex + 1) : targetIndex;
      if (newIdx < 0) newIdx = 0;
      if (newIdx > total) newIdx = total;
      await reorder(dragIndex, newIdx);
      dragIndex = -1;
    });

    // DnD handle only
    const handle = document.createElement('button');
    handle.className='small drag-handle';
    handle.title='Drag to reorder';
    handle.textContent='≡';
    handle.setAttribute('draggable','true');
    handle.addEventListener('dragstart', (e)=>{
      dragIndex = it.index;
      if (e.dataTransfer) {
        e.dataTransfer.setData('text/plain', String(it.index));
        e.dataTransfer.setDragImage(row, 20, 20);
        e.dataTransfer.effectAllowed = 'move';
      }
    });
    handle.addEventListener('dragend', ()=>{
      dragIndex = -1;
      row.classList.remove('drag-over');
    });

    const name = document.createElement('div');
    name.textContent = it.name;
    name.style.flex='1';
    const urlDiv = document.createElement('div');
    urlDiv.textContent = it.url;
    urlDiv.className='url';
    urlDiv.style.flex='2';

    const del= document.createElement('button'); del.className='small'; del.textContent='🗑';
    del.title = 'Delete';
    del.onclick= ()=> delStation(it.index);

    const colR = document.createElement('div'); colR.style.display='flex'; colR.style.gap='6px';
    colR.appendChild(del);

    row.appendChild(handle);
    row.appendChild(name);
    row.appendChild(urlDiv);
    row.appendChild(colR);
    root.appendChild(row);
  });

  // sync settings
  try{
    const s = await fetch(qp('/settings')).then(r=>r.json());
    const liveEl = document.getElementById('live');
    if (liveEl) {
      liveEl.checked = !!s.startLiveOnResume;
      liveEl.onchange = async () => {
        const en = liveEl.checked;
        const res = await fetch(qp('/settings'), {
          method:'POST',
          headers:{'Content-Type':'application/json'},
          body:JSON.stringify({startLiveOnResume: en})
        });
        document.getElementById('liveMsg').textContent = res.ok ? 'Saved' : 'Error';
        setTimeout(()=>{ document.getElementById('liveMsg').textContent=''; }, 1200);
      };
    }
  }catch(e){}
}

async function addStation(){
  const n = document.getElementById('name').value.trim();
  const u = document.getElementById('url').value.trim();
  const msg = document.getElementById('msg');
  if(!n || !u){ msg.textContent='Enter name and URL'; return; }
  const res = await fetch(qp('/stations/add'), {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({name:n,url:u})
  });
  msg.textContent = res.ok ? 'Added' : 'Error';
  document.getElementById('name').value='';
  document.getElementById('url').value='';
  await buildEdit(); await refresh();
}

async function delStation(i){
  await fetch(qp('/stations/delete'), {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({index:i})
  });
  await buildEdit(); await refresh();
}

async function reorder(oldI,newI){
  if(oldI===newI) return;
  if(newI < 0) newI = 0;
  const u = qp('/stations/reorder');
  await fetch(u, {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({old:oldI,new:newI})
  });
  await buildEdit(); await refresh();
}

setInterval(refresh, 2000);
refresh();
</script>
</body></html>
''';
  }
}

// -------------------- MOBILE UI ----------------------

class HomePage extends StatefulWidget {
  final RadioAudioHandler handler;
  const HomePage({super.key, required this.handler});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final storage = StationStorage();
  List<Station> _stations = [];
  double _volume = 1.0;
  int _currentIndex = 0;

  String? _nowTitle; // cached ICY/nowPlaying text

  final nameCtrl = TextEditingController();
  final urlCtrl = TextEditingController();
  final ScrollController _listCtrl = ScrollController();

  WebRemoteServer? _remote;
  bool _serverEnabled = false;
  bool _serverBusy = false;
  String? _lanUrl;

  // live & soft pause
  bool _startLiveOnResume = false;
  bool _softPaused = false;
  double _preMuteVolume = 1.0;

  StreamSubscription<MediaItem?>? _miSub;

  final List<GlobalKey> _itemKeys = [];
  void _syncItemKeys() {
    if (_itemKeys.length != _stations.length) {
      _itemKeys
        ..clear()
        ..addAll(List.generate(_stations.length, (_) => GlobalKey()));
    }
  }

  Future<void> _ensureSelectedVisible() async {
    if (_currentIndex == 0) {
      if (_listCtrl.hasClients) {
        await _listCtrl.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    if (_currentIndex == _stations.length - 1) {
      if (_listCtrl.hasClients) {
        await _listCtrl.animateTo(
          _listCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    await Future.delayed(const Duration(milliseconds: 40));
    if (_currentIndex >= 0 && _currentIndex < _itemKeys.length) {
      final ctx = _itemKeys[_currentIndex].currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 250),
          alignment: 0.5,
          curve: Curves.easeInOut,
        );
      }
    }
  }

  // Pretty drag proxy for SliverReorderableList
  Widget _dragProxyDecorator(
      BuildContext context,
      Widget child,
      int index,
      Animation<double> anim,
      ) {
    final curved =
    CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
    return ScaleTransition(
      scale: Tween<double>(begin: 1.0, end: 1.02).animate(curved),
      child: Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).cardColor,
        child: child,
      ),
    );
  }

  Widget _stationTile({required Station s, required int index}) {
    return ListTile(
      key: ValueKey(s.url),
      dense: true,
      title: Text(s.name),
      subtitle: Text(s.url, style: const TextStyle(fontSize: 12)),
      leading: ReorderableDragStartListener(
        index: index,
        child: const Icon(Icons.drag_indicator),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Delete',
        onPressed: () => _removeStation(index),
      ),
      onTap: () {
        Navigator.of(context).pop();
        _currentIndex = index;
        storage.saveLastIndex(index);
        widget.handler.skipToQueueItem(index);
        _ensureSelectedVisible();
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _stations = await storage.loadStations();
      if (_stations.isEmpty) {
        _stations = List.of(kDefaultStations);
        await storage.saveStations(_stations);
      }
      final last = await storage.loadLastIndex();
      if (last != null && last >= 0 && last < _stations.length) {
        _currentIndex = last;
      }
      final vol = await storage.loadVolume();
      if (vol != null) _volume = vol;

      final live = await storage.loadStartLiveOnResume();
      _startLiveOnResume = live ?? false;

      // Web remote persisted state
      final webOn = await storage.loadWebRemoteEnabled();
      final shouldStartWeb = webOn == true;

      final items =
      _stations.map((s) => MediaItem(id: s.url, title: s.name)).toList();
      await widget.handler.init(items, startIndex: _currentIndex);
      await widget.handler.setVolume(_volume);

      _miSub?.cancel();
      _miSub = widget.handler.mediaItem.listen((item) {
        if (item == null) return;
        // Update only UI state, no disk/scroll here
        final idx = _stations.indexWhere((s) => s.url == item.id);
        if (idx != -1) {
          setState(() {
            _currentIndex = idx;
            _nowTitle = item.title;
          });
        } else {
          setState(() => _nowTitle = item.title);
        }
      });

      if (mounted) setState(() {});
      _syncItemKeys();

      // Autostart web remote if it was enabled earlier
      if (shouldStartWeb) {
        await _toggleServer(true);
      }
    } catch (e, st) {
      dev.log('Init failed', error: e, stackTrace: st);
    }
  }

  // ---------- Station operations (gapless) ----------

  Future<bool> _addStationByValues(String name, String url) async {
    try {
      final currentUrl = (_currentIndex >= 0 && _currentIndex < _stations.length)
          ? _stations[_currentIndex].url
          : widget.handler.mediaItem.valueOrNull?.id;

      setState(() =>
      _stations = List.of(_stations)..add(Station(name: name, url: url)));
      await storage.saveStations(_stations);

      final items =
      _stations.map((s) => MediaItem(id: s.url, title: s.name)).toList();
      await widget.handler.refreshQueue(items, preserveByUrl: currentUrl);
      _syncItemKeys();
      return true;
    } catch (e, st) {
      dev.log('addStation failed', error: e, stackTrace: st);
      return false;
    }
  }

  Future<bool> _deleteStationByIndex(int i) async {
    if (i < 0 || i >= _stations.length) return false;
    try {
      final currentUrl = (_currentIndex >= 0 && _currentIndex < _stations.length)
          ? _stations[_currentIndex].url
          : widget.handler.mediaItem.valueOrNull?.id;

      setState(() => _stations = List.of(_stations)..removeAt(i));
      await storage.saveStations(_stations);

      final items =
      _stations.map((s) => MediaItem(id: s.url, title: s.name)).toList();
      _currentIndex =
      _stations.isEmpty ? 0 : _currentIndex.clamp(0, _stations.length - 1);

      await widget.handler.refreshQueue(items, preserveByUrl: currentUrl);
      await storage.saveLastIndex(_currentIndex);
      _syncItemKeys();
      return true;
    } catch (e, st) {
      dev.log('deleteStation failed', error: e, stackTrace: st);
      return false;
    }
  }

  Future<bool> _reorderStationsPublic(int oldIndex, int newIndex) async {
    try {
      if (newIndex > oldIndex) newIndex -= 1;
      if (oldIndex == newIndex) return true;

      final currentUrl = (_currentIndex >= 0 && _currentIndex < _stations.length)
          ? _stations[_currentIndex].url
          : widget.handler.mediaItem.valueOrNull?.id;

      setState(() {
        final item = _stations.removeAt(oldIndex);
        _stations.insert(newIndex, item);
      });

      await storage.saveStations(_stations);
      final items =
      _stations.map((s) => MediaItem(id: s.url, title: s.name)).toList();

      final restoredIndex = currentUrl == null
          ? newIndex
          : _stations.indexWhere((s) => s.url == currentUrl);
      _currentIndex = restoredIndex < 0 ? 0 : restoredIndex;

      await widget.handler.refreshQueue(items, preserveByUrl: currentUrl);
      await storage.saveLastIndex(_currentIndex);
      _syncItemKeys();
      return true;
    } catch (e, st) {
      dev.log('reorder failed', error: e, stackTrace: st);
      return false;
    }
  }

  // ---------- Buttons ----------

  void _addStation() async {
    final name = nameCtrl.text.trim();
    final url = urlCtrl.text.trim();
    if (name.isEmpty || url.isEmpty) return;
    if (await _addStationByValues(name, url)) {
      nameCtrl.clear();
      urlCtrl.clear();
      await _ensureSelectedVisible();
    }
  }

  void _removeStation(int i) async {
    await _deleteStationByIndex(i);
    await _ensureSelectedVisible();
  }

  Future<void> _reorderStations(int oldIndex, int newIndex) async {
    await _reorderStationsPublic(oldIndex, newIndex);
    await _ensureSelectedVisible();
  }

  // ---------- Web server ----------

  Future<void> _toggleServer(bool enable) async {
    if (_serverBusy) return;
    final prevEnabled = _serverEnabled;

    setState(() {
      _serverBusy = true;
      _serverEnabled = enable; // optimistic
      if (!enable) _lanUrl = null;
    });

    try {
      if (enable) {
        _remote = WebRemoteServer(
          handler: widget.handler,
          getStations: () => _stations,
          getCurrentIndex: () => _currentIndex,
          getNowTitle: () => _nowTitle,
          getVolume: () => _volume,
          onVolumeChanged: (v) async {
            setState(() => _volume = v);
            await storage.saveVolume(v);
            if (_softPaused) _preMuteVolume = v;
          },
          onAddStation: (n, u) => _addStationByValues(n, u),
          onDeleteStation: (i) => _deleteStationByIndex(i),
          onReorderStations: (o, n) => _reorderStationsPublic(o, n),
          getStartLiveOnResume: () => _startLiveOnResume,
          getSoftPaused: () => _softPaused,
          onSoftPause: () async {
            if (!_softPaused) _preMuteVolume = _volume;
            await widget.handler.setVolume(0.0);
            setState(() {
              _softPaused = true;
            });
          },
          onSoftResume: () async {
            await widget.handler.setVolume(_preMuteVolume);
            setState(() {
              _softPaused = false;
            });
          },
          onSetStartLive: (enabled) async {
            setState(() => _startLiveOnResume = enabled);
            await storage.saveStartLiveOnResume(enabled);
          },
          port: 8080,
          token: null,
        );
        await _remote!.start();

        // LAN lookup in separate isolate (non-blocking)
        _lanUrl = await _findLanUrl(port: _remote!.port);

        await storage.saveWebRemoteEnabled(true);
      } else {
        await _remote?.stop();
        _remote = null;
        _lanUrl = null;

        await storage.saveWebRemoteEnabled(false);
      }
    } catch (e, st) {
      dev.log('toggle server failed', error: e, stackTrace: st);
      setState(() {
        _serverEnabled = prevEnabled;
        if (prevEnabled && _remote == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to start the web remote')),
          );
        }
      });
    } finally {
      if (mounted) setState(() => _serverBusy = false);
    }
  }

  Future<String?> _findLanUrl({required int port}) {
    // Run on a background isolate to avoid blocking the UI isolate
    return Isolate.run<String?>(() async {
      try {
        final ifs =
        await NetworkInterface.list(type: InternetAddressType.IPv4);
        for (final ni in ifs) {
          for (final addr in ni.addresses) {
            final ip = addr.address;
            final is172 = RegExp(r'^172\.(1[6-9]|2[0-9]|3[0-1])').hasMatch(ip);
            if (!addr.isLoopback &&
                (ip.startsWith('192.168.') ||
                    ip.startsWith('10.') ||
                    is172)) {
              return 'http://$ip:$port';
            }
          }
        }
      } catch (_) {}
      return null;
    });
  }

  @override
  void dispose() {
    _miSub?.cancel();
    nameCtrl.dispose();
    urlCtrl.dispose();
    _listCtrl.dispose();
    _remote?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('Internet Radio'),
        actions: [
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                backgroundColor: Colors.black,
                builder: (ctx) {
                  final viewInsets = MediaQuery.of(ctx).viewInsets.bottom;
                  return FractionallySizedBox(
                    heightFactor: 0.9,
                    child: AnimatedPadding(
                      padding: EdgeInsets.only(bottom: viewInsets),
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOut,
                      child: CustomScrollView(
                        slivers: [
                          // --- Grab handle + title ---
                          SliverToBoxAdapter(
                            child: Column(
                              children: [
                                const SizedBox(height: 8),
                                Container(
                                  width: 44,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: Colors.white24,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      16, 12, 8, 8),
                                  child: Row(
                                    children: [
                                      const Text(
                                        'Stations editor',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const Spacer(),
                                      IconButton(
                                        tooltip: 'Close',
                                        icon: const Icon(Icons.close),
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // --- ADD STATION (TOP) ---
                          SliverToBoxAdapter(
                            child: Padding(
                              padding:
                              const EdgeInsets.fromLTRB(12, 0, 12, 8),
                              child: Card(
                                color:
                                Colors.blueGrey.withOpacity(0.15),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      12, 12, 12, 12),
                                  child: Column(
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: TextField(
                                              controller: nameCtrl,
                                              textInputAction:
                                              TextInputAction.next,
                                              decoration:
                                              const InputDecoration(
                                                labelText: 'Name',
                                                border:
                                                OutlineInputBorder(),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            flex: 2,
                                            child: TextField(
                                              controller: urlCtrl,
                                              textInputAction:
                                              TextInputAction.done,
                                              decoration:
                                              const InputDecoration(
                                                labelText: 'Stream URL',
                                                border:
                                                OutlineInputBorder(),
                                              ),
                                              onSubmitted: (_) =>
                                                  _addStation(),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      SizedBox(
                                        width: double.infinity,
                                        child: FilledButton(
                                          onPressed: _addStation,
                                          child:
                                          const Text('Add station'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // --- REORDER / DELETE LIST ---
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8),
                            sliver: SliverReorderableList(
                              itemBuilder: (context, i) =>
                                  _stationTile(
                                      s: _stations[i], index: i),
                              itemCount: _stations.length,
                              onReorder:
                                  (oldIndex, newIndex) async {
                                await _reorderStations(
                                    oldIndex, newIndex);
                              },
                              proxyDecorator:
                                  (child, index, animation) =>
                                  _dragProxyDecorator(
                                      ctx, child, index, animation),
                            ),
                          ),

                          // --- SETTINGS (COLLAPSIBLE, BOTTOM) ---
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  12, 8, 12, 12),
                              child: Card(
                                color:
                                Colors.blueGrey.withOpacity(0.15),
                                child: Theme(
                                  data: Theme.of(ctx).copyWith(
                                      dividerColor: Colors.white10),
                                  child: ExpansionTile(
                                    initiallyExpanded: false,
                                    title: const Text('Settings'),
                                    subtitle: const Text(
                                        'Web remote & live mode'),
                                    childrenPadding:
                                    const EdgeInsets.fromLTRB(
                                        12, 0, 12, 12),
                                    children: [
                                      // Web remote toggle
                                      SwitchListTile(
                                        title: const Text(
                                            'Web remote over Wi-Fi'),
                                        subtitle: Text(
                                          _serverBusy
                                              ? 'starting…'
                                              : (_serverEnabled
                                              ? (_lanUrl == null
                                              ? 'enabled, discovering address…'
                                              : _lanUrl!)
                                              : 'disabled'),
                                        ),
                                        value: _serverEnabled,
                                        onChanged: _serverBusy
                                            ? null
                                            : (v) =>
                                            _toggleServer(v),
                                      ),
                                      if (_serverBusy)
                                        const Padding(
                                          padding: EdgeInsets.only(
                                              bottom: 8),
                                          child:
                                          LinearProgressIndicator(
                                            minHeight: 2,
                                          ),
                                        ),

                                      // Live / soft pause toggle
                                      SwitchListTile(
                                        title: const Text(
                                            'Resume from live position'),
                                        subtitle: Text(
                                          _startLiveOnResume
                                              ? 'Pause mutes audio but keeps the stream'
                                              : 'Pause stops the stream',
                                        ),
                                        value: _startLiveOnResume,
                                        onChanged: (v) async {
                                          setState(() =>
                                          _startLiveOnResume =
                                              v);
                                          await storage
                                              .saveStartLiveOnResume(
                                              v);
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),

                          const SliverToBoxAdapter(
                            child: SizedBox(height: 16),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: StreamBuilder<PlaybackState>(
          stream: widget.handler.playbackState,
          builder: (context, snapshot) {
            final playingRaw = snapshot.data?.playing ?? false;
            final playing = _softPaused ? false : playingRaw;

            return Column(
              children: [
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      tooltip: 'Previous',
                      onPressed: () async {
                        if (_stations.isEmpty) return;
                        final len = _stations.length;
                        final wasFirst = (_currentIndex == 0);
                        setState(() => _currentIndex =
                            (_currentIndex - 1 + len) % len);
                        await storage.saveLastIndex(_currentIndex);
                        await widget.handler
                            .skipToQueueItem(_currentIndex);
                        if (wasFirst && _listCtrl.hasClients) {
                          await _listCtrl.animateTo(
                            _listCtrl.position.maxScrollExtent,
                            duration: const Duration(
                                milliseconds: 250),
                            curve: Curves.easeOut,
                          );
                        } else {
                          await _ensureSelectedVisible();
                        }
                      },
                    ),
                    IconButton(
                      icon: Icon(
                        playing
                            ? Icons.pause
                            : Icons.play_arrow,
                        size: 36,
                      ),
                      tooltip: playing ? 'Pause' : 'Play',
                      onPressed: () async {
                        if (playing || _softPaused) {
                          if (_startLiveOnResume) {
                            if (!_softPaused) {
                              _preMuteVolume = _volume;
                            }
                            await widget.handler
                                .setVolume(0.0); // mute
                            setState(() {
                              _softPaused = true;
                            });
                          } else {
                            await widget.handler.pause();
                          }
                        } else {
                          if (_startLiveOnResume && _softPaused) {
                            await widget.handler
                                .setVolume(_preMuteVolume); // unmute
                            setState(() {
                              _softPaused = false;
                            });
                          } else {
                            if (_stations.isEmpty) return;
                            await widget.handler.play();
                          }
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      tooltip: 'Next',
                      onPressed: () async {
                        if (_stations.isEmpty) return;
                        final len = _stations.length;
                        final wasLast =
                        (_currentIndex == len - 1);
                        setState(() => _currentIndex =
                            (_currentIndex + 1) % len);
                        await storage.saveLastIndex(_currentIndex);
                        await widget.handler
                            .skipToQueueItem(_currentIndex);
                        if (wasLast && _listCtrl.hasClients) {
                          await _listCtrl.animateTo(
                            0,
                            duration: const Duration(
                                milliseconds: 250),
                            curve: Curves.easeOut,
                          );
                        } else {
                          await _ensureSelectedVisible();
                        }
                      },
                    ),
                  ],
                ),

                // Now playing (ICY metadata)
                StreamBuilder<MediaItem?>(
                  stream: widget.handler.mediaItem,
                  builder: (context, snap) {
                    final title = snap.data?.title ?? _nowTitle;
                    if (title == null || title.isEmpty) {
                      return const SizedBox(height: 6);
                    }
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style:
                        Theme.of(context).textTheme.titleMedium,
                      ),
                    );
                  },
                ),

                // Volume
                Padding(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      const Icon(Icons.volume_down),
                      Expanded(
                        child: Slider(
                          value: _volume,
                          onChanged: (v) async {
                            setState(() => _volume = v);
                            if (_softPaused) {
                              _preMuteVolume =
                                  v; // remember desired volume
                              await storage.saveVolume(v);
                            } else {
                              await widget.handler
                                  .setVolume(v);
                              await storage.saveVolume(v);
                            }
                          },
                        ),
                      ),
                      const Icon(Icons.volume_up),
                    ],
                  ),
                ),

                // Station list (names only)
                Expanded(
                  child: ListView.builder(
                    controller: _listCtrl,
                    keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: _stations.length,
                    itemBuilder: (context, i) {
                      final s = _stations[i];
                      final isSelected = i == _currentIndex;
                      return Container(
                        key: _itemKeys.length == _stations.length
                            ? _itemKeys[i]
                            : null,
                        child: ListTile(
                          leading: isSelected
                              ? const Icon(
                              Icons.play_arrow_rounded)
                              : const SizedBox(width: 24),
                          title: Text(
                            s.name,
                            style: isSelected
                                ? const TextStyle(
                              fontWeight:
                              FontWeight.w600,
                            )
                                : null,
                          ),
                          selected: isSelected,
                          selectedTileColor: Colors.blueGrey
                              .withOpacity(0.35),
                          onTap: () async {
                            _currentIndex = i;
                            await storage.saveLastIndex(i);
                            await widget.handler
                                .skipToQueueItem(i);
                            await _ensureSelectedVisible();
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
