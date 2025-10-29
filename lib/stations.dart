class Station {
final String name;
final String url; // прямая ссылка на поток (mp3/aac/m3u8)
final String? logoUrl;
const Station({required this.name, required this.url, this.logoUrl});


Map<String, dynamic> toJson() => {"name": name, "url": url, "logo": logoUrl};
factory Station.fromJson(Map<String, dynamic> j) => Station(
name: j['name'] as String,
url: j['url'] as String,
logoUrl: j['logo'] as String?,
);
}


const kDefaultStations = <Station>[
Station(name: '1.FM - Alternative Rock', url: 'http://prmstrm.1.fm:8000/x'),
Station(name: '1.FM - Classic Rock', url: 'http://prmstrm.1.fm:8000/crock'),
Station(name: '1.FM - Rock Classics',   url: 'http://prmstrm.1.fm:8000/rockclassics'),
Station(name: '1.FM - 90s Alternative', url: 'http://prmstrm.1.fm:8000/partyzone90s'),
Station(name: '1.FM - Adore Jazz', url: 'http://prmstrm.1.fm:8000/ajazz'),
Station(name: '1.FM - Smooth Jazz', url: 'http://prmstrm.1.fm:8000/smoothjazz'),
Station(name: '1.FM - Blues', url: 'http://prmstrm.1.fm:8000/blues'),
Station(name: '1.FM - Classical',       url: 'http://prmstrm.1.fm:8000/classical'),
Station(name: '1.FM - Opera',       url: 'http://prmstrm.1.fm:8000/opera'),
Station(name: '1.FM - Essential Classical',       url: 'http://prmstrm.1.fm:8000/polskafm'),
Station(name: '1.FM - 60s-70s',       url: 'http://prmstrm.1.fm:8000/60s_70s'),
Station(name: '1.FM - 70s',             url: 'http://prmstrm.1.fm:8000/70s'),
Station(name: '1.FM - 90s',             url: 'http://prmstrm.1.fm:8000/90s'),
Station(name: '1.FM - Y2K',             url: 'http://prmstrm.1.fm:8000/hits2000'),
Station(name: '1.FM - Millennial Nostalgia', url: 'http://prmstrm.1.fm:8000/eurovision'),
Station(name: '1.FM - Top 40 Ballads',  url: 'http://prmstrm.1.fm:8000/top40ballads'),
Station(name: '1.FM - Italia On Air',  url: 'http://prmstrm.1.fm:8000/italiaonair'),
];