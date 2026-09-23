import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'api/wangsa_api_client.dart';
import 'chat/bloc/chat_bloc.dart';
import 'chat/view/chat_page.dart';
import 'config/app_config.dart';
import 'config/config_loader.dart';
import 'llm/llm_settings_controller.dart';
import 'theme/theme_controller.dart';
import 'theme/wangsa_theme.dart';
import 'voice/native_voice_input.dart';
import 'voice/summon_notifications.dart';
import 'voice/voice_input.dart';
import 'voice/voice_summoner.dart';
import 'voice/wake_word_engine.dart';

/// Alamat host default. Selalu `localhost` — baik di Windows Desktop
/// maupun Android (emulator atau HP fisik lewat USB) — karena
/// `scripts/setup-adb.js` (`bun run dev:mobile`/`dev:api`/`dev:web`,
/// atau `adb:reverse` manual) sudah memasang `adb reverse tcp:3001` dan
/// `tcp:5173` ke tiap perangkat Android yang tersambung, jadi
/// `localhost` di perangkat itu ikut diteruskan ke host. Dulu dikhususkan
/// ke 10.0.2.2 untuk emulator, tapi itu bukan alamat yang valid di HP
/// fisik (bukan NAT alias seperti di emulator) — dengan adb reverse,
/// satu alamat ini sudah cukup untuk emulator maupun HP asli.
String get _defaultHost => 'localhost';

/// Alamat berkas konfigurasi. Jika dioper via --dart-define maka dipakai,
/// jika tidak maka otomatis memilih host sesuai platform.
String get configUrl {
  const envUrl = String.fromEnvironment('WANGSA_CONFIG_URL');
  if (envUrl.isNotEmpty) return envUrl;
  return 'http://$_defaultHost:5173/config.json';
}

/// Dipakai bila berkas konfigurasi tidak terjangkau.
///
/// v1 Hermes wangsa_mobile plugin: tidak ada config server terpisah lagi
/// (dulu `http://localhost:5173/config.json`) — agen dijangkau langsung
/// lewat plugin REST `wangsa_mobile` di gateway Hermes, default port 9901
/// (lihat WANGSA_MOBILE_PORT di plugins/platforms/wangsa_mobile).
AppConfig get fallbackConfig => AppConfig(
  apiBaseUrl: 'http://$_defaultHost:9901',
  defaultAgentId: 'belum-diatur',
  wakeWord: 'Halo Wangsa',
  wakeWordAccessKey: 'sherpa-onnx-offline',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Layanan latar depan hanya diinisialisasi pada platform Android
  // (Windows desktop tidak mendukung flutter_foreground_task).
  bool isAndroid = false;
  try {
    isAndroid = Platform.isAndroid;
  } catch (_) {}

  if (isAndroid) {
    // Sekali di awal, sebelum runApp(): dokumentasi flutter_foreground_task
    // mewajibkan initCommunicationPort() dipanggil di sini, dan init()
    // menyiapkan kanal notifikasi yang wajib tampil selama layanan latar
    // depan hidup (lihat NativeVoiceInput — layanan ini yang menahan akses
    // mikrofon selagi layar mati).
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'wangsa_wake_word',
        channelName: 'Wangsa mendengarkan kata pemicu',
        channelDescription: 'Tampil selama aplikasi mengawasi "Halo Wangsa" di latar belakang.',
        onlyAlertOnce: true,
      ),
      // Wajib diisi oleh flutter_foreground_task 11, walaupun aplikasi ini
      // hanya menargetkan Android. Nilai bawaannya sudah benar untuk kita,
      // jadi cukup disebutkan agar kompilasi lolos.
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // TaskHandler kosong (lihat native_voice_input.dart) tidak
        // butuh dibangunkan berkala — wake word tetap berjalan sendiri di
        // isolate utama. Interval sepanjang ini praktis sama dengan tidak
        // ada, tapi API paket ini mewajibkan sebuah interval.
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: false, // Android 15 melarang ini untuk layanan mikrofon — lihat docs/mobile-client-decision.md.
        allowWakeLock: true,
      ),
    );
  }

  // v1: tidak ada config server (dulu HTTP round-trip ke config.json) —
  // langsung pakai AppConfig dari dart-define/fallback. ConfigLoader tetap
  // ada untuk kompatibilitas siapa pun yang masih memanggilnya langsung,
  // tapi startup tidak lagi menunggu jaringan untuk konfigurasi dasar.
  final result = ConfigLoadResult(config: fallbackConfig);

  // Dibuat sekali di sini, bukan di dalam WangsaApp.build() — build() bisa
  // dipanggil ulang (mis. saat hot reload), dan ChatPage hanya
  // berlangganan events sekali lewat initState(), jadi instance baru
  // pada rebuild akan diam-diam tidak pernah didengarkan.
  // "Hallo Wangsa" memakai classifier custom hallo_wangsa_v1.onnx
  // (hasil training tim) di atas pipeline openWakeWord, menggantikan
  // classifier pretrained "hey jarvis" (bahasa Inggris) dan zipformer
  // yang tidak mendeteksi logat Indonesia
  // (docs/wake-word-mobile-status-for-irawan-yardan.md).
  // Bobot dasar openWakeWord berlisensi CC BY-NC-SA 4.0, non-komersial.
  final voiceInput = NativeVoiceInput(
    accessKey: result.config.wakeWordAccessKey,
    createWakeWordEngine: createOpenWakeWordEngine,
  );
  // Bel ala Siri: saat kata pemicu terdeteksi ketika aplikasi di
  // background, tampilkan notifikasi full-screen (lihat voice_summoner.dart).
  // Saat foreground tidak melakukan apa pun — overlay chat sudah cukup.
  // Di background dikte otomatis ditunda (mic tetap dipegang pengawasan
  // kata pemicu) dan baru dimulai saat pengguna kembali ke aplikasi.
  VoiceSummoner(
    display: LocalNotificationSummon(),
    wakeWord: result.config.wakeWord,
    onVisibilityChanged: (backgrounded) =>
        voiceInput.deferAutoListen = backgrounded,
    onSummonAccepted: () => voiceInput.startListening(),
  ).attach(voiceInput);
  // Default ON atas keputusan eksplisit Irawan (17 Sept 2026): wake word
  // di-auto-start saat bootstrap. startWakeWordWatch() sendiri no-op bila
  // wake word tidak dikonfigurasi, dan galat internal sudah ditangani
  // try/catch di dalamnya — jadi fire-and-forget tanpa memblokir runApp().
  // Risiko kontensi mic vs tombol dikte biasa diketahui & diterima tanpa
  // mitigasi tambahan; sakelar Pengaturan tetap ada sebagai override manual.
  unawaited(voiceInput.startWakeWordWatch());
  final themeController = await ThemeController.load();
  final llmSettings = await LlmSettingsController.load();

  runApp(
    WangsaApp(
      configResult: result,
      voiceInput: voiceInput,
      themeController: themeController,
      llmSettings: llmSettings,
    ),
  );
}

class WangsaApp extends StatelessWidget {
  final ConfigLoadResult configResult;
  final VoiceInput voiceInput;
  final ThemeController themeController;
  final LlmSettingsController llmSettings;

  const WangsaApp({
    super.key,
    required this.configResult,
    required this.voiceInput,
    required this.themeController,
    required this.llmSettings,
  });

  @override
  Widget build(BuildContext context) {
    final config = configResult.config;

    // `home` dibangun SEKALI di sini, bukan di dalam builder ValueListenableBuilder
    // di bawah. ValueListenableBuilder memanggil builder-nya lagi setiap kali
    // mode tema berubah — kalau BlocProvider(create: ...) ada di dalam builder
    // itu, tiap ganti tema diam-diam membuat ChatBloc baru (riwayat chat hilang,
    // ChatOpened terpanggil ulang) dan MaterialApp.home jadi widget baru, yang
    // mereset Navigator ke halaman awal walau pengguna sedang membuka Pengaturan.
    // Meneruskannya lewat parameter `child` membuat ValueListenableBuilder
    // memakai instance yang sama pada setiap rebuild.
    final home = BlocProvider(
      create: (_) => ChatBloc(
        apiClient: WangsaApiClient(baseUrl: config.apiBaseUrl),
        agentId: config.defaultAgentId,
      )..add(const ChatOpened()),
      child: ChatPage(
        config: config,
        configProblem: configResult.problem,
        voiceInput: voiceInput,
        themeController: themeController,
        llmSettings: llmSettings,
      ),
    );

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeController,
      builder: (context, mode, child) => MaterialApp(
        title: 'Wangsa',
        debugShowCheckedModeBanner: false,
        theme: WangsaTheme.forBrightness(Brightness.light),
        darkTheme: WangsaTheme.forBrightness(Brightness.dark),
        themeMode: mode,
        home: child,
      ),
      child: home,
    );
  }
}
