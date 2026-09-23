/// Adapter tipis di atas `flutter_foreground_task` — satu-satunya berkas
/// yang boleh mengimpor paket itu, alasan yang sama seperti
/// `wake_word_engine.dart` dan `speech_engine.dart`: memanggil
/// `FlutterForegroundTask` langsung dari `NativeVoiceInput` akan membuat
/// setiap test unitnya mencoba menjangkau kanal platform sungguhan yang
/// tidak ada di lingkungan test (bukan di perangkat Android), dan gagal
/// dengan `MissingPluginException` alih-alih menguji logikanya.
library;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

abstract interface class ForegroundServiceController {
  Future<void> start();
  Future<void> stop();
}

/// Nomor sembarang, hanya perlu unik di dalam aplikasi ini.
const _foregroundServiceId = 3781;

/// TaskHandler kosong yang sengaja tidak melakukan apa-apa selain
/// membuat proses ini tetap dianggap "berjalan" oleh Android selagi
/// notifikasi layanan latar depan tampil.
///
/// Mesin Porcupine yang sesungguhnya TETAP berjalan di isolate utama,
/// tidak dipindahkan ke sini — layanan ini hanya menaikkan prioritas
/// proses (lewat foregroundServiceType "microphone" di
/// AndroidManifest.xml) supaya OS mengizinkan akses mikrofon bertahan
/// saat layar mati. Ini "Opsi A" dari catatan desain milestone ini,
/// dipilih karena lebih sederhana dari memindahkan Porcupine ke isolate
/// terpisah lewat `TaskHandler` (Opsi B) dan sudah cukup untuk kebutuhan
/// PRD (layar mati, bukan aplikasi disingkirkan paksa dari daftar
/// terkini). Kelayakannya di perangkat sungguhan — apakah Doze/App
/// Standby tetap membunuhnya walau layanan ini hidup — belum dibuktikan
/// tanpa uji manual; lihat docs/wake-word-setup-mobile.md.
@pragma('vm:entry-point')
void wangsaForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_NoopTaskHandler());
}

// Ketujuh method di bawah ini persis daftar yang dipakai contoh resmi
// paketnya sendiri (example/lib/main.dart) — semuanya di-override
// meski sebagian mungkin sudah punya badan bawaan, supaya tidak perlu
// menebak mana yang benar-benar wajib untuk versi paket yang terpasang.
class _NoopTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {}

  @override
  void onNotificationDismissed() {}
}

class FlutterForegroundServiceController implements ForegroundServiceController {
  const FlutterForegroundServiceController();

  @override
  Future<void> start() => FlutterForegroundTask.startService(
        serviceId: _foregroundServiceId,
        notificationTitle: 'Wangsa mendengarkan',
        notificationText: 'Ucapkan "Halo Wangsa" untuk memanggil asisten.',
        callback: wangsaForegroundTaskCallback,
      );

  @override
  Future<void> stop() => FlutterForegroundTask.stopService();
}
