# Berkas Picovoice untuk Android

Direktori ini sengaja kosong di repository. Ikuti
[`docs/wake-word-setup-mobile.md`](../../../../docs/wake-word-setup-mobile.md)
untuk melatih kata pemicu "Hallo Wangsa" di Picovoice Console (platform
**Android**, bukan Web/WASM — berkas web dan mobile tidak bisa dipakai
saling bertukar) lalu taruh hasilnya di sini dengan nama persis:

```text
assets/voice/hallo-wangsa_android.ppn
assets/voice/porcupine_params.pv
```

Seluruh direktori ini sudah didaftarkan di `pubspec.yaml` (`flutter: assets:
- assets/voice/`), jadi menambahkan kedua berkas di atas sudah cukup — tidak
perlu baris baru di `pubspec.yaml`. Setelah menaruhnya, jalankan
`flutter pub get` lalu build ulang aplikasi supaya berkasnya ikut terbundel.

Sampai kedua berkas ini ada, `NativeVoiceInput` (lihat
`lib/voice/native_voice_input.dart`) memperlakukan wake word sebagai
tidak dikonfigurasi dan tidak pernah menyentuh mikrofon untuk mendengarkan
kata pemicu — persis perilaku `missing_configuration` yang sudah dipakai
versi web (`apps/web/src/lib/voice/wake-word.ts`). Ini bukan bug; ini
keadaan yang diharapkan untuk checkout repository yang belum diisi aset
Picovoice-nya.
