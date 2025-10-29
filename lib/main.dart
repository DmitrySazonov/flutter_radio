import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import 'stations.dart';
import 'storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Иммерсив при старте
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.black,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  final handler = await AudioService.init(
    builder: () => RadioAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.flutter_radio.channel.audio',
      androidNotificationChannelName: 'Radio Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
  runApp(MyApp(handler: handler));
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

class RadioAudioHandler extends BaseAudioHandler {
  final _player = AudioPlayer();
  List<MediaItem> _items = const [];
  int _currentIndex = 0;

  StreamSubscription<PlaybackEvent>? _pbSub;
  StreamSubscription<IcyMetadata?>? _icySub;

  Future<void> init(List<MediaItem> items, {int startIndex = 0}) async {
    _items = items;
    _currentIndex = startIndex.clamp(0, _items.isEmpty ? 0 : _items.length - 1);

    queue.add(_items);

    if (_items.isNotEmpty) {
      mediaItem.add(_items[_currentIndex]);
      await _player.setAudioSource(
        AudioSource.uri(Uri.parse(_items[_currentIndex].id)),
      );
    }

    await _pbSub?.cancel();
    _pbSub = _player.playbackEventStream.listen((event) {
      playbackState.add(
        playbackState.value.copyWith(
          controls: [
            MediaControl.skipToPrevious,
            _player.playing ? MediaControl.pause : MediaControl.play,
            MediaControl.stop,
            MediaControl.skipToNext,
          ],
          systemActions: const {MediaAction.seek},
          androidCompactActionIndices: const [0, 1, 3],
          processingState: _transformState(event.processingState),
          playing: _player.playing,
          updatePosition: _player.position,
          bufferedPosition: _player.bufferedPosition,
          speed: _player.speed,
        ),
      );
    });

    await _icySub?.cancel();
    _icySub = _player.icyMetadataStream.listen((icy) {
      final info = icy?.info?.title ?? icy?.headers?.name;
      final current = mediaItem.valueOrNull;
      if (current != null && info != null && info.isNotEmpty) {
        mediaItem.add(current.copyWith(title: info));
      }
    });
  }

  AudioProcessingState _transformState(ProcessingState state) {
    switch (state) {
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

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> stop() => _player.stop();

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
  Future<void> skipToQueueItem(int index) async => _switchTo(index);

  Future<void> _switchTo(int index) async {
    if (_items.isEmpty) return;
    _currentIndex = index.clamp(0, _items.length - 1);
    final item = _items[_currentIndex];
    mediaItem.add(item); // имя станции до прихода ICY
    await _player.setAudioSource(AudioSource.uri(Uri.parse(item.id)));
    await _player.play();
  }

  Future<void> setVolume(double v) async => _player.setVolume(v.clamp(0.0, 1.0));
}

// -------------------- ВЕБ-СЕРВЕР ----------------------

class WebRemoteServer {
  HttpServer? _server;
  final RadioAudioHandler handler;
  final int port;
  final String? token;

  // провайдеры состояния из UI
  final List<Station> Function() getStations;
  final int Function() getCurrentIndex;
  final String? Function() getNowTitle; // ICY/MediaItem.title
  final double Function() getVolume;    // текущая громкость (из UI)
  final Future<void> Function(double) onVolumeChanged; // UI sync

  // «live» / мягкая пауза
  final bool Function() getStartLiveOnResume;
  final bool Function() getSoftPaused;
  final Future<void> Function() onSoftPause;  // mute
  final Future<void> Function() onSoftResume; // unmute

  // операции изменения списка станций
  final Future<bool> Function(String name, String url) onAddStation;
  final Future<bool> Function(int index) onDeleteStation;
  final Future<bool> Function(int oldIndex, int newIndex) onReorderStations;

  // изменение настроек
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
    final got = req.uri.queryParameters['token'] ?? req.headers.value('x-api-key');
    return got == token;
  }

  void _setCors(HttpResponse res) {
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
    res.headers.set('Access-Control-Allow-Headers', 'Content-Type,X-API-Key');
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

    // статика (веб-пульт + настройки)
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
        // управление
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
            await onSoftPause(); // mute вместо pause
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

        case '/volume': {
          final vStr = req.uri.queryParameters['value'];
          final v = double.tryParse(vStr ?? '');
          if (v == null || v.isNaN) {
            _writeJson(req.response, '{"ok":false,"error":"value 0..1 required"}', 400);
            break;
          }
          final vol = v.clamp(0.0, 1.0);
          if (getSoftPaused()) {
            // при мягкой паузе оставляем звук на 0, но запоминаем желаемую громкость
            await onVolumeChanged(vol);
          } else {
            await handler.setVolume(vol);
            await onVolumeChanged(vol);
          }
          _writeJson(req.response, '{"ok":true,"volume":$vol}');
          break;
        }

        case '/select': {
          final idxStr = req.uri.queryParameters['index'];
          final idx = int.tryParse(idxStr ?? '');
          final stations = getStations();
          if (idx == null || idx < 0 || idx >= stations.length) {
            _writeJson(req.response, '{"ok":false,"error":"bad index"}', 400);
            break;
          }
          await handler.skipToQueueItem(idx);
          _writeJson(req.response, '{"ok":true}');
          break;
        }

        // станции
        case '/stations': {
          final stations = getStations();
          final cur = getCurrentIndex();
          final buf = StringBuffer('{"ok":true,"current":$cur,"items":[');
          for (var i = 0; i < stations.length; i++) {
            final s = stations[i];
            buf.write('{"index":$i,"name":${_j(s.name)}}');
            if (i != stations.length - 1) buf.write(',');
          }
          buf.write(']}');
          _writeJson(req.response, buf.toString());
          break;
        }

        case '/stations/full': {
          final stations = getStations();
          final cur = getCurrentIndex();
          final buf = StringBuffer('{"ok":true,"current":$cur,"items":[');
          for (var i = 0; i < stations.length; i++) {
            final s = stations[i];
            buf.write('{"index":$i,"name":${_j(s.name)},"url":${_j(s.url)}}');
            if (i != stations.length - 1) buf.write(',');
          }
          buf.write(']}');
          _writeJson(req.response, buf.toString());
          break;
        }

        case '/stations/add': {
          if (req.method != 'POST') {
            _writeJson(req.response, '{"ok":false,"error":"POST required"}', 405);
            break;
          }
          final data = await _readJson(req);
          if (data == null) { _writeJson(req.response, '{"ok":false,"error":"bad json"}', 400); break; }
          final name = (data['name'] ?? '').toString().trim();
          final url  = (data['url']  ?? '').toString().trim();
          if (name.isEmpty || url.isEmpty) {
            _writeJson(req.response, '{"ok":false,"error":"name and url required"}', 400);
            break;
          }
          final ok = await onAddStation(name, url);
          _writeJson(req.response, ok ? '{"ok":true}' : '{"ok":false}');
          break;
        }

        case '/stations/delete': {
          if (req.method != 'POST') {
            final idx = int.tryParse(req.uri.queryParameters['index'] ?? '');
            if (idx == null) { _writeJson(req.response, '{"ok":false,"error":"POST or index param"}', 400); break; }
            final ok = await onDeleteStation(idx);
            _writeJson(req.response, ok ? '{"ok":true}' : '{"ok":false}', ok ? 200 : 400);
            break;
          }
          final data = await _readJson(req);
          if (data == null || !data.containsKey('index')) {
            _writeJson(req.response, '{"ok":false,"error":"index required"}', 400); break;
          }
          final idx = int.tryParse(data['index'].toString());
          if (idx == null) { _writeJson(req.response, '{"ok":false,"error":"bad index"}', 400); break; }
          final ok = await onDeleteStation(idx);
          _writeJson(req.response, ok ? '{"ok":true}' : '{"ok":false}', ok ? 200 : 400);
          break;
        }

        case '/stations/reorder': {
          if (req.method != 'POST') {
            _writeJson(req.response, '{"ok":false,"error":"POST required"}', 405);
            break;
          }
          final data = await _readJson(req);
          if (data == null) { _writeJson(req.response, '{"ok":false,"error":"bad json"}', 400); break; }
          final oldIdx = int.tryParse(data['old'].toString());
          final newIdx = int.tryParse(data['new'].toString());
          if (oldIdx == null || newIdx == null) {
            _writeJson(req.response, '{"ok":false,"error":"old/new required"}', 400); break;
          }
          final ok = await onReorderStations(oldIdx, newIdx);
          _writeJson(req.response, ok ? '{"ok":true}' : '{"ok":false}', ok ? 200 : 400);
          break;
        }

        // настройки
        case '/settings':
          if (req.method == 'GET') {
            final live = getStartLiveOnResume();
            _writeJson(req.response, '{"ok":true,"startLiveOnResume":$live}');
          } else if (req.method == 'POST') {
            final data = await _readJson(req);
            if (data == null || !data.containsKey('startLiveOnResume')) {
              _writeJson(req.response, '{"ok":false,"error":"startLiveOnResume required"}', 400);
              break;
            }
            final live = data['startLiveOnResume'] == true || data['startLiveOnResume'].toString() == 'true';
            await onSetStartLive(live);
            _writeJson(req.response, '{"ok":true,"startLiveOnResume":$live}');
          } else {
            _writeJson(req.response, '{"ok":false,"error":"GET or POST"}', 405);
          }
          break;

        case '/status': {
          final stations2 = getStations();
          final cur2 = getCurrentIndex();
          final now = getNowTitle();
          final vol = getVolume();
          final st = handler.playbackState.value;
          final soft = getSoftPaused();
          final live = getStartLiveOnResume();
          final name = (cur2 >= 0 && cur2 < stations2.length) ? stations2[cur2].name : null;

          final playingFlag = soft ? false : st.playing; // маска

          _writeJson(
            req.response,
            '{"ok":true,"playing":$playingFlag,"currentIndex":$cur2,'
            '"station":${_j(name)},"title":${_j(now)},"volume":$vol,'
            '"softPaused":$soft,"startLiveOnResume":$live}'
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
  label.switch { display:inline-flex; align-items:center; gap:8px; cursor:pointer; }
</style>
</head>
<body>
<div class="wrap">
  <div class="hdr">
    <h2>Radio Remote</h2>
    <button class="iconbtn" title="Настройки" onclick="toggleEdit()">⚙️</button>
  </div>

  <div id="view">
    <div id="station" class="title">—</div>
    <div id="now" class="title muted">—</div>
    <div class="row" style="margin:12px 0">
      <button onclick="api('/prev')">⏮️ Prev</button>
      <button onclick="api('/play')">▶️ Play</button>
      <button onclick="api('/pause')">⏸️ Pause</button>
      <button onclick="api('/next')">⏭️ Next</button>
    </div>
    <div>Volume: <input id="vol" type="range" min="0" max="1" step="0.01" value="1"></div>
    <div id="list" class="list"></div>
  </div>

  <div id="edit" class="hidden">
    <div class="card">
      <h3 style="margin:0 0 8px 0;">Настройки</h3>
      <div style="display:flex;align-items:center;gap:10px;">
        <input type="checkbox" id="live" />
        <label for="live">Стартовать с live-места (мягкая пауза)</label>
      </div>
      <div id="liveMsg" class="muted" style="margin-top:6px;"></div>
    </div>

    <div class="card">
      <h3 style="margin:0 0 8px 0;">Добавить станцию</h3>
      <div class="row2">
        <input id="name" type="text" placeholder="Название">
        <input id="url"  type="text" placeholder="http://...">
      </div>
      <div style="margin-top:8px">
        <button class="small" onclick="addStation()">Добавить</button>
        <span id="msg" class="muted" style="margin-left:8px"></span>
      </div>
    </div>

    <div class="card">
      <h3 style="margin:0 0 8px 0;">Порядок и удаление</h3>
      <div id="elist"></div>
    </div>
  </div>
</div>

<script>
const token='${t}';
function qp(url){return token? url+(url.includes('?')?'&':'?')+'token='+encodeURIComponent(token):url}
let settingVol=false;

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
  await fetch(qp(path) + (qp(path).includes('?')?'&':'?') + '_=' + Date.now(), opt);
  refresh();
}

async function refresh(){
  try{
    const s = await fetch(qp('/status') + (qp('/status').includes('?')?'&':'?') + '_=' + Date.now()).then(r=>r.json());
    document.getElementById('station').textContent = s.station || '—';
    document.getElementById('now').textContent = s.title || '—';
    if (!settingVol && typeof s.volume === 'number') {
      const volEl = document.getElementById('vol');
      if (Math.abs(parseFloat(volEl.value) - s.volume) > 0.001) volEl.value = String(s.volume);
    }
    const liveEl = document.getElementById('live');
    if (liveEl) liveEl.checked = !!s.startLiveOnResume;
    await rebuildList(s.currentIndex);
  }catch(e){}
}

async function rebuildList(curr){
  const data = await fetch(qp('/stations') + (qp('/stations').includes('?')?'&':'?') + '_=' + Date.now()).then(r=>r.json());
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
  const data = await fetch(qp('/stations/full') + (qp('/stations/full').includes('?')?'&':'?') + '_=' + Date.now()).then(r=>r.json());
  const root = document.getElementById('elist');
  root.innerHTML='';
  data.items.forEach(it=>{
    const row = document.createElement('div');
    row.className='item'+(it.index===data.current?' curr':'');
    const name = document.createElement('div');
    name.textContent = it.name;
    name.style.flex='1';
    const url = document.createElement('div');
    url.textContent = it.url;
    url.className='url';
    url.style.flex='2';
    const up = document.createElement('button'); up.className='small'; up.textContent='▲';
    const dn = document.createElement('button'); dn.className='small'; dn.textContent='▼';
    const del= document.createElement('button'); del.className='small'; del.textContent='🗑';
    up.onclick = ()=> reorder(it.index, Math.max(0, it.index-1));
    dn.onclick = ()=> reorder(it.index, Math.min(data.items.length-1, it.index+1));
    del.onclick= ()=> delStation(it.index);
    const colR = document.createElement('div'); colR.style.display='flex'; colR.style.gap='6px';
    colR.appendChild(up); colR.appendChild(dn); colR.appendChild(del);
    row.appendChild(name); row.appendChild(url); row.appendChild(colR);
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
        const res = await fetch(qp('/settings'), {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({startLiveOnResume: en})});
        document.getElementById('liveMsg').textContent = res.ok ? 'Сохранено' : 'Ошибка';
        setTimeout(()=>{ document.getElementById('liveMsg').textContent=''; }, 1200);
      };
    }
  }catch(e){}
}

async function addStation(){
  const n = document.getElementById('name').value.trim();
  const u = document.getElementById('url').value.trim();
  const msg = document.getElementById('msg');
  if(!n || !u){ msg.textContent='Укажите название и URL'; return; }
  const res = await fetch(qp('/stations/add'), {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({name:n,url:u})});
  msg.textContent = res.ok ? 'Добавлено' : 'Ошибка';
  document.getElementById('name').value='';
  document.getElementById('url').value='';
  await buildEdit(); await refresh();
}

async function delStation(i){
  await fetch(qp('/stations/delete'), {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({index:i})});
  await buildEdit(); await refresh();
}

async function reorder(oldI,newI){
  if(oldI===newI) return;
  await fetch(qp('/stations/reorder'), {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({old:oldI,new:newI})});
  await buildEdit(); await refresh();
}

setInterval(refresh, 2000);
refresh();
</script>
</body></html>
''';
  }
}

// -------------------- UI ----------------------

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

  String? _nowTitle; // кэш «композиции» для отображения/веб-пульта

  final nameCtrl = TextEditingController();
  final urlCtrl = TextEditingController();
  final ScrollController _listCtrl = ScrollController();

  WebRemoteServer? _remote;
  bool _serverEnabled = false;
  bool _serverBusy = false; // индикатор запуска/остановки
  String? _lanUrl;

  // live & мягкая пауза
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
        await _listCtrl.animateTo(0,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      }
      return;
    }
    if (_currentIndex == _stations.length - 1) {
      if (_listCtrl.hasClients) {
        await _listCtrl.animateTo(_listCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
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

      final items =
          _stations.map((s) => MediaItem(id: s.url, title: s.name)).toList();
      await widget.handler.init(items, startIndex: _currentIndex);
      await widget.handler.setVolume(_volume);

      _miSub?.cancel();
      _miSub = widget.handler.mediaItem.listen((item) async {
        if (item == null) return;
        final idx = _stations.indexWhere((s) => s.url == item.id);
        if (idx != -1) {
          setState(() {
            _currentIndex = idx;
            _nowTitle = item.title;
          });
          await storage.saveLastIndex(idx);
          await _ensureSelectedVisible();
        } else {
          setState(() => _nowTitle = item.title);
        }
      });

      if (mounted) setState(() {});
      _syncItemKeys();
      await _ensureSelectedVisible();
    } catch (e, st) {
      dev.log('Init failed', error: e, stackTrace: st);
    }
  }

  // ---------- Операции со станциями ----------

  Future<bool> _addStationByValues(String name, String url) async {
    try {
      setState(() => _stations = List.of(_stations)..add(Station(name: name, url: url)));
      await storage.saveStations(_stations);
      final items = _stations.map((s) => MediaItem(id: s.url, title: s.name)).toList();
      await widget.handler.init(items, startIndex: _currentIndex);
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
      setState(() => _stations = List.of(_stations)..removeAt(i));
      await storage.saveStations(_stations);
      final items = _stations.map((s) => MediaItem(id: s.url, title: s.name)).toList();
      _currentIndex = _stations.isEmpty ? 0 : _currentIndex.clamp(0, _stations.length - 1);
      await widget.handler.init(items, startIndex: _currentIndex);
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
          : null;

      setState(() {
        final item = _stations.removeAt(oldIndex);
        _stations.insert(newIndex, item);
      });

      await storage.saveStations(_stations);
      final items = _stations.map((s) => MediaItem(id: s.url, title: s.name)).toList();
      final restoredIndex =
          currentUrl == null ? newIndex : _stations.indexWhere((s) => s.url == currentUrl);
      _currentIndex = restoredIndex < 0 ? 0 : restoredIndex;

      await widget.handler.init(items, startIndex: _currentIndex);
      await storage.saveLastIndex(_currentIndex);
      _syncItemKeys();
      return true;
    } catch (e, st) {
      dev.log('reorder failed', error: e, stackTrace: st);
      return false;
    }
  }

  // ---------- Кнопки в приложении ----------

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

  // ---------- Веб-сервер ----------

  Future<void> _toggleServer(bool enable) async {
    if (_serverBusy) return;
    final prevEnabled = _serverEnabled;

    setState(() {
      _serverBusy = true;
      _serverEnabled = enable; // оптимистично
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
            if (!_softPaused) {
              _preMuteVolume = _volume;
            }
            await widget.handler.setVolume(0.0);
            setState(() { _softPaused = true; });
          },
          onSoftResume: () async {
            await widget.handler.setVolume(_preMuteVolume);
            setState(() { _softPaused = false; });
          },
          onSetStartLive: (enabled) async {
            setState(() => _startLiveOnResume = enabled);
            await storage.saveStartLiveOnResume(enabled);
          },

          port: 8080,
          token: null,
        );
        await _remote!.start();
        _lanUrl = await _findLanUrl(port: _remote!.port);
      } else {
        await _remote?.stop();
        _remote = null;
        _lanUrl = null;
      }
    } catch (e, st) {
      dev.log('toggle server failed', error: e, stackTrace: st);
      setState(() {
        _serverEnabled = prevEnabled;
        if (prevEnabled && _remote == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось запустить веб-пульт')),
          );
        }
      });
    } finally {
      if (mounted) setState(() => _serverBusy = false);
    }
  }

  Future<String?> _findLanUrl({required int port}) async {
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final ni in ifs) {
        for (final addr in ni.addresses) {
          final ip = addr.address;
          if (!addr.isLoopback &&
              (ip.startsWith('192.168.') ||
               ip.startsWith('10.') ||
               ip.startsWith(RegExp(r'^172\\.(1[6-9]|2[0-9]|3[0-1])')))) {
            return 'http://$ip:$port';
          }
        }
      }
    } catch (_) {}
    return null;
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
        title: const Text('Интернет Радио'),
        actions: [
          IconButton(
            tooltip: 'Редактировать',
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
                    heightFactor: 0.85,
                    child: AnimatedPadding(
                      padding: EdgeInsets.only(bottom: viewInsets),
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOut,
                      child: Column(
                        mainAxisSize: MainAxisSize.max,
                        children: [
                          const SizedBox(height: 8),
                          Container(
                            width: 44, height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                            child: Row(
                              children: [
                                const Text('Редактирование станций',
                                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                                const Spacer(),
                                IconButton(
                                  tooltip: 'Закрыть',
                                  icon: const Icon(Icons.close),
                                  onPressed: () => Navigator.of(ctx).pop(),
                                ),
                              ],
                            ),
                          ),

                          // Веб-пульт
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                            child: Card(
                              color: Colors.blueGrey.withOpacity(0.15),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SwitchListTile(
                                    title: const Text('Веб-пульт по Wi-Fi'),
                                    subtitle: Text(
                                      _serverBusy
                                          ? 'запуск…'
                                          : (_serverEnabled
                                              ? (_lanUrl == null
                                                  ? 'включен, определяю адрес…'
                                                  : _lanUrl!)
                                              : 'выключен'),
                                    ),
                                    value: _serverEnabled,
                                    onChanged: _serverBusy ? null : (v) => _toggleServer(v),
                                  ),
                                  if (_serverBusy)
                                    const Padding(
                                      padding: EdgeInsets.only(bottom: 8),
                                      child: LinearProgressIndicator(minHeight: 2),
                                    ),
                                ],
                              ),
                            ),
                          ),

                          // Режим live (мягкая пауза)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                            child: Card(
                              color: Colors.blueGrey.withOpacity(0.15),
                              child: SwitchListTile(
                                title: const Text('Стартовать с live-места'),
                                subtitle: Text(_startLiveOnResume
                                    ? 'При паузе поток не останавливается, звук отключается'
                                    : 'При паузе поток останавливается'),
                                value: _startLiveOnResume,
                                onChanged: (v) async {
                                  setState(() => _startLiveOnResume = v);
                                  await storage.saveStartLiveOnResume(v);
                                },
                              ),
                            ),
                          ),

                          // Добавление станции
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Column(
                              children: [
                                const SizedBox(height: 8),
                                TextField(
                                  controller: nameCtrl,
                                  textInputAction: TextInputAction.next,
                                  decoration: const InputDecoration(
                                    labelText: 'Название',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: urlCtrl,
                                  textInputAction: TextInputAction.done,
                                  decoration: const InputDecoration(
                                    labelText: 'URL потока',
                                    border: OutlineInputBorder(),
                                  ),
                                  onSubmitted: (_) => _addStation(),
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                    onPressed: _addStation,
                                    child: const Text('Добавить станцию'),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 12),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text('Порядок и удаление',
                                  style: Theme.of(ctx).textTheme.titleSmall),
                            ),
                          ),
                          const SizedBox(height: 8),

                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: ReorderableListView.builder(
                                padding: const EdgeInsets.only(bottom: 16),
                                buildDefaultDragHandles: false,
                                itemCount: _stations.length,
                                onReorder: (o, n) => _reorderStations(o, n),
                                itemBuilder: (context, i) {
                                  final s = _stations[i];
                                  return ListTile(
                                    key: ValueKey(s.url),
                                    dense: true,
                                    title: Text(s.name),
                                    subtitle: Text(s.url, style: const TextStyle(fontSize: 12)),
                                    leading: ReorderableDragStartListener(
                                      index: i,
                                      child: const Icon(Icons.drag_indicator),
                                    ),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () => _removeStation(i),
                                    ),
                                    onTap: () {
                                      Navigator.of(context).pop();
                                      _currentIndex = i;
                                      storage.saveLastIndex(i);
                                      widget.handler.skipToQueueItem(i);
                                      _ensureSelectedVisible();
                                    },
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
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
            final playing = _softPaused ? false : playingRaw; // маскируем soft pause как «не играет»

            return Column(
              children: [
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      onPressed: () async {
                        if (_stations.isEmpty) return;
                        final len = _stations.length;
                        final wasFirst = (_currentIndex == 0);
                        setState(() => _currentIndex = (_currentIndex - 1 + len) % len);
                        await storage.saveLastIndex(_currentIndex);
                        await widget.handler.skipToQueueItem(_currentIndex);
                        if (wasFirst && _listCtrl.hasClients) {
                          await _listCtrl.animateTo(
                            _listCtrl.position.maxScrollExtent,
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                          );
                        } else {
                          await _ensureSelectedVisible();
                        }
                      },
                    ),
                    IconButton(
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow, size: 36),
                      onPressed: () async {
                        if (playing || _softPaused) {
                          // нажали «Пауза»
                          if (_startLiveOnResume) {
                            if (!_softPaused) {
                              _preMuteVolume = _volume;
                            }
                            await widget.handler.setVolume(0.0); // mute
                            setState(() { _softPaused = true; });
                          } else {
                            await widget.handler.pause();
                          }
                        } else {
                          // нажали «Play»
                          if (_startLiveOnResume && _softPaused) {
                            await widget.handler.setVolume(_preMuteVolume); // unmute
                            setState(() { _softPaused = false; });
                          } else {
                            if (_stations.isEmpty) return;
                            await widget.handler.play();
                          }
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: () async {
                        if (_stations.isEmpty) return;
                        final len = _stations.length;
                        final wasLast = (_currentIndex == len - 1);
                        setState(() => _currentIndex = (_currentIndex + 1) % len);
                        await storage.saveLastIndex(_currentIndex);
                        await widget.handler.skipToQueueItem(_currentIndex);
                        if (wasLast && _listCtrl.hasClients) {
                          await _listCtrl.animateTo(
                            0,
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                          );
                        } else {
                          await _ensureSelectedVisible();
                        }
                      },
                    ),
                  ],
                ),

                // Сейчас играет (ICY-метаданные)
                StreamBuilder<MediaItem?>(
                  stream: widget.handler.mediaItem,
                  builder: (context, snap) {
                    final title = snap.data?.title ?? _nowTitle;
                    if (title == null || title.isEmpty) return const SizedBox(height: 6);
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    );
                  },
                ),

                // Громкость
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      const Icon(Icons.volume_down),
                      Expanded(
                        child: Slider(
                          value: _volume,
                          onChanged: (v) async {
                            setState(() => _volume = v);
                            if (_softPaused) {
                              _preMuteVolume = v; // запоминаем желаемую громкость
                              await storage.saveVolume(v);
                            } else {
                              await widget.handler.setVolume(v);
                              await storage.saveVolume(v);
                            }
                          },
                        ),
                      ),
                      const Icon(Icons.volume_up),
                    ],
                  ),
                ),

                // Список станций (только названия)
                Expanded(
                  child: ListView.builder(
                    controller: _listCtrl,
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: _stations.length,
                    itemBuilder: (context, i) {
                      final s = _stations[i];
                      final isSelected = i == _currentIndex;
                      return Container(
                        key: _itemKeys.length == _stations.length ? _itemKeys[i] : null,
                        child: ListTile(
                          leading: isSelected
                              ? const Icon(Icons.play_arrow_rounded)
                              : const SizedBox(width: 24),
                          title: Text(
                            s.name,
                            style: isSelected
                                ? const TextStyle(fontWeight: FontWeight.w600)
                                : null,
                          ),
                          selected: isSelected,
                          selectedTileColor: Colors.blueGrey.withOpacity(0.35),
                          onTap: () async {
                            _currentIndex = i;
                            await storage.saveLastIndex(i);
                            await widget.handler.skipToQueueItem(i);
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
