import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'voice_summoner.dart';

/// [SummonDisplay] memakai `flutter_local_notifications`: satu-satunya
/// berkas yang boleh mengimpor paket itu (lihat komentar di
/// `voice_summoner.dart`).
class LocalNotificationSummon implements SummonDisplay {
  static const _channelId = 'wangsa_wake_summon';
  static const _notificationId = 3782;

  final FlutterLocalNotificationsPlugin _plugin;

  bool _initialized = false;

  LocalNotificationSummon({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  Future<void> _initOnce() async {
    if (_initialized) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );
    await _plugin.initialize(settings);
    const channel = AndroidNotificationChannel(
      _channelId,
      'Panggilan Wangsa',
      description: 'Muncul saat kata pemicu terdengar ketika aplikasi di background.',
      importance: Importance.max,
    );
    final android =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(channel);
    _initialized = true;
  }

  @override
  Future<bool> ensurePermissions() async {
    await _initOnce();
    final android =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true;
    final notifications = await android.requestNotificationsPermission() ?? false;
    // Android 14+: tanpa ini fullScreenIntent diabaikan diam-diam.
    final fullScreen = await android.requestFullScreenIntentPermission() ?? true;
    return notifications && fullScreen;
  }

  @override
  Future<void> showSummon(String wakeWord) async {
    await _initOnce();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'Panggilan Wangsa',
        channelDescription: 'Muncul saat kata pemicu terdengar ketika aplikasi di background.',
        importance: Importance.max,
        priority: Priority.high,
        // Kategori panggilan + fullScreenIntent = perilaku ala Siri:
        // heads-up di atas aplikasi lain, layar penuh saat terkunci.
        // Ketukannya membuka aplikasi (overlay suara sudah terbuka di sana).
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        ongoing: true,
        autoCancel: false,
      ),
    );
    await _plugin.show(
      _notificationId,
      'Wangsa mendengar "$wakeWord"',
      'Ketuk untuk bicara.',
      details,
      payload: 'voice-summon',
    );
  }

  @override
  Future<void> hideSummon() async {
    if (!_initialized) return;
    await _plugin.cancel(_notificationId);
  }
}
