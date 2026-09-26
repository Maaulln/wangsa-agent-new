/// Daftar kandidat alamat API + probing fallback otomatis + penelusuran LAN.
///
/// Latar: URL backend yang tersimpan di HP bisa basi kapan saja — IP Wi-Fi
/// laptop berubah tiap konek ulang (DHCP), `adb reverse` hilang tiap kabel
/// dicabut, dan backend gateway memang tidak selalu jalan. Sebelum ada
/// berkas ini, aplikasi hanya mencoba SATU url lalu menyerah dengan pesan
/// generik "Tidak bisa menghubungi API Wangsa", sehingga pengguna harus
/// mengedit URL manual setiap `flutter run`.
///
/// Sekarang alurnya: coba URL utama dulu; kalau gagal total (RUNTIME_ERROR —
/// jaringan mati/timeout/bukan JSON), coba kandidat lain satu per satu.
/// Kandidat yang menjawab — walau menjawab NOT_FOUND/UNAUTHORIZED, artinya
/// servernya hidup — dipakai dan disimpan, tanpa campur tangan pengguna.
/// Bila kandidat statis juga mati (misalnya HP belum pernah tersambung ke
/// laptop lewat Wi-Fi ini), [discoverLanBackendUrls] menelusuri subnet
/// lokal HP untuk backend yang IP-nya tidak disimpan siapa pun.
library;

import 'dart:io';

import 'wangsa_api_client.dart';

/// Port bawaan plugin `wangsa_mobile` (lihat WANGSA_MOBILE_PORT di
/// `plugins/platforms/wangsa_mobile/` dan `scripts/run_mobile_backend.py`).
const int wangsaDefaultPort = 9901;

/// URL generic yang tersimpan pada versi aplikasi sebelumnya bisa berasal
/// dari mode pekerjaan API 9902, bukan dari gateway chat. Pertahankan URL
/// lama lain agar instalasi gateway custom tetap kompatibel.
String? usableLegacyGatewaySavedUrl(String? value) {
  final saved = _normalizeHttpUrl(value);
  if (saved == null) return null;
  final uri = Uri.tryParse(saved);
  if (uri?.port == 9902) return null;
  return saved;
}

/// The Android Studio emulator reaches the host through 10.0.2.2. Translate
/// loopback URLs that were saved on the host so signup can connect before the
/// authenticated chat's automatic endpoint probing is available.
String adaptLoopbackApiUrl(String value, {required bool androidEmulator}) {
  if (!androidEmulator) return value;
  final uri = Uri.tryParse(value.trim());
  if (uri == null || (uri.host != 'localhost' && uri.host != '127.0.0.1')) {
    return value;
  }
  return uri
      .replace(host: '10.0.2.2')
      .toString()
      .replaceFirst(RegExp(r'/$'), '');
}

/// Menyusun kandidat alamat API dengan urutan coba.
///
/// Urutan: URL simpanan (pilihan pengguna, paling dihormati) →
/// `--dart-define=WANGSA_API_BASE_URL` → `localhost` (USB + `adb reverse`,
/// juga jalan di desktop) → `10.0.2.2` (alias host khusus emulator
/// Android; di HP fisik gagal cepat lalu dilewati).
///
/// Pasangan kandidat pertama lokal mengikuti port simpanan/env agar instalasi
/// custom tetap terjangkau; pasangan port gateway bawaan selalu dicoba setelahnya.
List<String> buildApiCandidates({
  String? savedUrl,
  String? envUrl,
  int defaultPort = wangsaDefaultPort,
}) {
  final saved = _normalizeHttpUrl(savedUrl);
  final env = _normalizeHttpUrl(envUrl);
  final port = _portOf(saved) ?? _portOf(env) ?? defaultPort;
  final ordered = <String>[
    ?saved,
    ?env,
    'http://localhost:$port',
    'http://10.0.2.2:$port',
    if (port != defaultPort) 'http://localhost:$defaultPort',
    if (port != defaultPort) 'http://10.0.2.2:$defaultPort',
  ];
  // Dedup dengan hormat urutan (simpanan tetap pertama).
  final seen = <String>{};
  return [
    for (final u in ordered)
      if (seen.add(u)) u,
  ];
}

/// Mencoba tiap kandidat sampai ada yang menjawab.
///
/// "Menjawab" = `GET /api/v1/agents/:id` (publik, tanpa token) pulang TANPA
/// RUNTIME_ERROR. Sukses tentu dihitung; tapi NOT_FOUND (id agent salah)
/// atau UNAUTHORIZED (server multi-user butuh token) juga dihitung —
/// keduanya membuktikan servernya hidup, hanya masalah identitas, bukan
/// koneksi. RUNTIME_ERROR (timeout/host tak dikenal/bukan JSON) berarti
/// coba kandidat berikutnya.
///
/// [currentUrl] dilewati karena pemanggil sudah mencobanya duluan.
/// Mengembalikan URL yang hidup, atau null bila semua gagal. Klien
/// sementara selalu di-close agar tidak bocor socket.
Future<String?> findReachableApiUrl({
  required List<String> candidates,
  required String agentId,
  required String currentUrl,
  Duration timeout = const Duration(seconds: 3),
  WangsaApiClient Function(String url)? clientFactory,
}) async {
  final current = _normalizeHttpUrl(currentUrl);
  for (final raw in candidates) {
    final candidate = _normalizeHttpUrl(raw);
    if (candidate == null || candidate == current) continue;
    final client = clientFactory != null
        ? clientFactory(candidate)
        : WangsaApiClient(baseUrl: candidate, requestTimeout: timeout);
    try {
      final result = await client.getAgent(agentId);
      if (result.isSuccess) return candidate;
      if (result.errorOrNull?.code != 'RUNTIME_ERROR') return candidate;
    } catch (_) {
      // factory jahat / client rusak — anggap kandidat ini mati.
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }
  return null;
}

/// Satu antarmuka jaringan lokal: alamat IPv4 + panjang prefiks jaringannya.
typedef LanIpv4Info = ({String address, int prefixLength});

/// Apakah [address] alamat IPv4 privat RFC1918 — satu-satunya tempat
/// backend Wangsa bisa berada di jaringan rumahan/kantor.
///
/// `127.x` (loopback), `169.254.x` (link-local), dan `100.64/10` (CGNAT
/// seluler) sengaja ditolak: backend tidak pernah ada di sana, dan
/// memindainya hanya membuang waktu (dan di kasus CGNAT, memindai jaringan
/// operator).
bool isPrivateLanIpv4(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final p in parts) {
    final v = int.tryParse(p);
    if (v == null || v < 0 || v > 255) return false;
    octets.add(v);
  }
  final a = octets[0];
  if (a == 10) return true;
  if (a == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
  if (a == 192 && octets[1] == 168) return true;
  return false;
}

/// Daftar host yang layak dipindai pada subnet [address]/[prefixLength].
///
/// Aturan main, masing-masing belajar dari kegagalan nyata:
/// - Subnet lebih lebar dari /24 (mis. /16, /21) dipadatkan ke SATU /24
///   yang memuat [address]. Pindaian penuh /16 dari HP berarti puluhan
///   ribu host dan berpuluh-puluh menit — tidak masuk akal untuk cek
///   "server hidup?".
/// - Subnet lebih sempit dari /24 (/28, /30, dst.) dipakai apa adanya.
/// - Alamat network & broadcast dibuang bila prefix ≤ 30.
/// - Maksimal 254 host (ukuran satu /24) sebagai jaring pengaman.
List<String> lanProbeHosts({
  required String address,
  required int prefixLength,
}) {
  final parts = address.split('.');
  if (parts.length != 4) return const [];
  final octets = <int>[];
  for (final p in parts) {
    final v = int.tryParse(p);
    if (v == null || v < 0 || v > 255) return const [];
    octets.add(v);
  }
  if (prefixLength < 0 || prefixLength > 32) return const [];
  final effective = prefixLength < 24 ? 24 : prefixLength;
  final ip =
      (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3];
  final mask = (0xFFFFFFFF << (32 - effective)) & 0xFFFFFFFF;
  final network = ip & mask;
  final broadcast = network | (~mask & 0xFFFFFFFF);
  final first = effective >= 31 ? network : network + 1;
  final last = effective >= 31 ? broadcast : broadcast - 1;
  final hosts = <String>[];
  for (var host = first; host <= last && hosts.length < 254; host++) {
    hosts.add(
      '${(host >> 24) & 0xFF}.${(host >> 16) & 0xFF}.${(host >> 8) & 0xFF}.${host & 0xFF}',
    );
  }
  return hosts;
}

/// Menelusuri subnet Wi-Fi lokal HP untuk backend Wangsa yang hidup.
///
/// Dipakai sebagai upaya TERAKHIR bila URL utama dan seluruh kandidat
/// statis mati — kasus klasik: HP baru konek ke Wi-Fi laptop, tidak ada
/// URL tersimpan yang cocok, `adb reverse` pun tidak ada. Alih-alih
/// meminta pengguna mengetik IP laptop (yang berubah tiap DHCP), aplikasi
/// sendiri yang mencari.
///
/// Langkahnya: baca antarmuka IPv4 privat HP → perluas ke host subnet
/// (lihat [lanProbeHosts]) → TCP-probe port [port] secara paralel → yang
/// portnya terbuka diverifikasi sungguhan lewat `GET /api/v1/agents/:id`
/// (NOT_FOUND/UNAUTHORIZED tetap dihitung hidup — masalah identitas, bukan
/// koneksi). Berhenti begitu satu batch menghasilkan backend hidup: satu
/// backend sudah cukup, tak perlu menelusuri sisa /24.
///
/// Semua hook bisa disuntikkan untuk pengujian; produksi memakai
/// [NetworkInterface.list] + `Socket.connect` sungguhan.
Future<List<String>> discoverLanBackendUrls({
  String agentId = 'wangsa',
  int port = wangsaDefaultPort,
  Duration timeout = const Duration(milliseconds: 800),
  int concurrency = 32,
  Future<List<LanIpv4Info>> Function()? listLocalIpv4,
  Future<bool> Function(String host, int port, Duration timeout)? tcpProbe,
  WangsaApiClient Function(String url)? clientFactory,
}) async {
  final interfaces = await (listLocalIpv4 ?? _defaultListLocalIpv4)();
  final hosts = <String>{};
  for (final iface in interfaces) {
    if (!isPrivateLanIpv4(iface.address)) continue;
    for (final host in lanProbeHosts(
      address: iface.address,
      prefixLength: iface.prefixLength,
    )) {
      if (host == iface.address) continue;
      hosts.add(host);
    }
  }
  if (hosts.isEmpty) return const [];

  final probe = tcpProbe ?? _defaultTcpProbe;
  final width = concurrency < 1 ? 1 : concurrency;
  final alive = <String>[];
  final ordered = hosts.toList(growable: false);
  for (var i = 0; i < ordered.length; i += width) {
    final batch = ordered.skip(i).take(width);
    final hits = await Future.wait(
      batch.map((host) async {
        final open = await probe(host, port, timeout);
        if (!open) return null;
        return _confirmWangsaAlive(
          'http://$host:$port',
          agentId: agentId,
          timeout: timeout,
          clientFactory: clientFactory,
        );
      }),
    );
    for (final hit in hits) {
      if (hit != null) alive.add(hit);
    }
    if (alive.isNotEmpty) break;
  }
  return alive;
}

/// Antarmuka IPv4 privat yang terpasang di perangkat ini (loopback,
/// link-local, dan alamat non-privat sudah dibuang di pemanggil).
Future<List<LanIpv4Info>> _defaultListLocalIpv4() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLinkLocal: false,
  );
  final result = <LanIpv4Info>[];
  for (final ni in interfaces) {
    for (final addr in ni.addresses) {
      result.add((address: addr.address, prefixLength: addr.prefixLength));
    }
  }
  return result;
}

/// TCP connect singkat: port terbuka = kandidat layak diverifikasi HTTP.
/// Port mati di subnet yang ARP-nya tak terjawab menggantung sampai timeout
/// — maka timeout di sini sengaja pendek.
Future<bool> _defaultTcpProbe(String host, int port, Duration timeout) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Verifikasi "ini memang backend Wangsa?" — sama semantiknya dengan
/// [findReachableApiUrl]: sukses, NOT_FOUND, atau UNAUTHORIZED = hidup;
/// RUNTIME_ERROR / exception = bukan server ini.
Future<String?> _confirmWangsaAlive(
  String url, {
  required String agentId,
  required Duration timeout,
  WangsaApiClient Function(String url)? clientFactory,
}) async {
  final client = clientFactory != null
      ? clientFactory(url)
      : WangsaApiClient(baseUrl: url, requestTimeout: timeout);
  try {
    final result = await client.getAgent(agentId);
    if (result.isSuccess) return url;
    if (result.errorOrNull?.code != 'RUNTIME_ERROR') return url;
    return null;
  } catch (_) {
    return null;
  } finally {
    try {
      client.close();
    } catch (_) {}
  }
}

/// Petunjuk Indonesia spesifik-host untuk layar galat.
///
/// Pesan generik "tidak bisa menghubungi" membuat orang menebak-nebak.
/// Petunjuk ini menjawab pertanyaan sebenarnya: "saya harus apa?"
String diagnoseConnectionHint(String url) {
  final host = Uri.tryParse(url.trim())?.host ?? '';
  if (host == 'localhost' || host == '127.0.0.1') {
    return 'Cek dua hal di laptop: backend jalan '
        '(`python scripts/run_mobile_backend.py` menjawab di :9901), lalu '
        '`adb reverse tcp:9901 tcp:9901` (hilang tiap kabel dicabut — '
        'pasang ulang lalu hot-restart dengan R).';
  }
  if (host == '10.0.2.2') {
    return 'Alamat 10.0.2.2 hanya berlaku di emulator Android. Di HP fisik '
        'pakai http://localhost:9901 via kabel USB (+ adb reverse) atau IP '
        'LAN laptop (mis. http://192.168.1.7:9901) satu jaringan Wi-Fi.';
  }
  return 'IP LAN laptop bisa berubah tiap konek Wi-Fi (DHCP), jadi URL '
      'simpanan ini bisa basi. Cek IP terbaru laptop (ipconfig/ifconfig), '
      'atau pakai http://localhost:9901 via kabel USB (+ adb reverse).';
}

String? _normalizeHttpUrl(String? value) {
  final trimmed = (value ?? '').trim();
  if (trimmed.isEmpty) return null;
  if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
    return null;
  }
  var result = trimmed;
  while (result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  return result.isEmpty ? null : result;
}

int? _portOf(String? normalizedUrl) {
  if (normalizedUrl == null) return null;
  final port = Uri.tryParse(normalizedUrl)?.port;
  if (port == null || port <= 0) return null;
  return port;
}
