# Wangsa Mobile

Klien Android untuk Agent Wangsa yang sudah dipublikasikan.

> **Dipindahkan ke wangsaxhermes (v1, Wangsa `wangsa_mobile` plugin):** aplikasi
> ini sekarang bicara langsung ke gateway Wangsa lewat plugin platform
> `plugins/platforms/wangsa_mobile/` (dua route REST: `GET
> /api/v1/agents/{agentId}` dan `POST /api/v1/agents/{agentId}/messages`),
> bukan lagi ke API/config-server lama di `wangsa/apps/api` +
> `apps/web/static/config.json`. `fallbackConfig` di `lib/main.dart` sudah
> menunjuk ke `http://localhost:9901` (default `WANGSA_MOBILE_PORT`), dan
> startup tidak lagi menunggu HTTP fetch `config.json` — bagian di bawah ini
> yang membahas `WANGSA_CONFIG_URL` / `apps/web/static/config.json` adalah
> dokumentasi versi lama, dipertahankan untuk konteks sejarah.
>
> Untuk menjalankan versi ini:
> 1. Jalankan Wangsa gateway dengan plugin `wangsa_mobile` aktif di port 9901
>    (`hermes gateway setup` lalu aktifkan platform "Wangsa Mobile", atau set
>    `WANGSA_MOBILE_PORT=9901`).
> 2. Untuk perangkat Android fisik, jalankan
>    `node apps/mobile/scripts/setup-adb.js` (forward `adb reverse tcp:9901`)
>    sebelum `flutter run`, supaya `localhost:9901` di HP diteruskan ke host.
> 3. `flutter run` dari `apps/mobile`.

Produk dan lingkupnya ada di [PRD.md](PRD.md). Alasan teknis di balik
pemilihan Flutter ada di [`docs/mobile-client-decision.md`](../../docs/mobile-client-decision.md).

## Struktur

```text
lib/
  api/        klien dua endpoint publik, model, dan amplop hasil
  chat/       bloc dan layar percakapan
  config/     konfigurasi yang dibaca dari server saat aplikasi dibuka
  settings/   layar pengaturan kecil
  voice/      kontrak masukan suara, batas antara layar dan mesin suara
```

`lib/voice/voice_input.dart` adalah batas antar tim. Layar chat hanya
mengenal antarmuka itu, sehingga implementasi wake word yang memakai
Porcupine dan layanan latar depan Android bisa dipasang tanpa mengubah
satu baris pun di layar.

## Menjalankan

Pastikan API dan web config berjalan lebih dulu:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d
```

Cek device atau emulator yang terdeteksi:

```bash
flutter devices
```

Untuk Android Emulator, gunakan `10.0.2.2` agar emulator menjangkau API di komputer host:

```bash
flutter run --dart-define=WANGSA_CONFIG_URL=http://10.0.2.2:5173/config.json
```

Aplikasi ini hanya menargetkan Android. Folder `web/` dan `windows/` di
proyek ini ada dari eksperimen platform lain, tapi lapisan suara
(`lib/voice/native_voice_input.dart`) memakai `porcupine_flutter` dan
`flutter_foreground_task`, dua plugin yang hanya mendukung Android dan
iOS — menjalankan `flutter run -d chrome` atau target Windows akan gagal
dikompilasi selama lapisan suara ini yang dipakai. Android memerlukan
Android Studio emulator atau device USB dengan USB debugging aktif.

Hanya satu nilai yang ditanam saat membangun, yaitu alamat berkas
konfigurasi. Alamat API, id Agent bawaan, dan kata pemicu dibaca dari
berkas itu, jadi menggantinya tidak menuntut build ulang.

Nilai bawaannya memakai `10.0.2.2`, alamat yang dipakai emulator Android
untuk menjangkau localhost mesin pengembang. Untuk perangkat sungguhan,
ganti dengan alamat IP mesinmu di jaringan yang sama, atau yang lebih
andal, sambungkan lewat kabel USB seperti di bagian
[Menjalankan di HP fisik lewat kabel USB](#menjalankan-di-hp-fisik-lewat-kabel-usb).

Bentuk berkas konfigurasinya:

```json
{
  "apiBaseUrl": "http://10.0.2.2:3001",
  "defaultAgentId": "id-agent-yang-sudah-dipublikasikan",
  "wakeWord": "porcupine",
  "wakeWordAccessKey": "AccessKey dari Picovoice Console, opsional"
}
```

Contohnya ada di [`apps/web/static/config.json`](../web/static/config.json),
yang otomatis tersaji di `/config.json` saat `bun run dev:web` berjalan
(berkas itu sendiri belum memuat `wakeWordAccessKey` — lihat
[`docs/wake-word-setup-mobile.md`](../../docs/wake-word-setup-mobile.md)
untuk menambahkannya). Tanpa `wakeWordAccessKey`, aplikasi tetap berjalan
normal — tombol mikrofon untuk dikte manual tetap berfungsi, hanya
pengawasan kata pemicu di latar belakang yang nonaktif.

## Menyiapkan satu Agent untuk diajak bicara

Aplikasi ini butuh Agent yang sudah disetujui dan dipublikasikan. Buat
lewat web, ikuti bagian "Enabling the full flow locally" di README utama,
lalu salin id Proposal setelah dipublikasikan. Id itulah yang dipakai
sebagai `defaultAgentId`.

## Menjalankan di HP fisik lewat kabel USB

Cara ini tidak bergantung pada Wi-Fi. Semua lalu lintas dari HP ke laptop
lewat kabel, jadi HP dan laptop tidak perlu satu jaringan, dan jaringan
kampus yang memblokir antarperangkat tidak jadi masalah.

1. Aktifkan USB debugging di HP, colok ke laptop, dan pastikan HP muncul
   di `flutter devices`.
2. Teruskan port laptop ke HP. `adb` sering tidak ada di PATH, jadi pakai
   jalur lengkapnya di folder `platform-tools` Android SDK:

   ```bash
   adb reverse tcp:3001 tcp:3001
   adb reverse tcp:5173 tcp:5173
   ```

3. Isi `apiBaseUrl` di `apps/web/static/config.json` dengan
   `http://localhost:3001`. Lewat kabel, `localhost` di HP menunjuk ke
   laptop.
4. Jalankan API seperti biasa dengan `bun run dev:api`.
5. Jalankan web dari folder `apps/web` dengan perintah ini, **bukan**
   `bun run dev:web`:

   ```bash
   bunx vite dev --host 127.0.0.1
   ```

6. Dari folder `apps/mobile`:

   ```bash
   flutter run --dart-define=WANGSA_CONFIG_URL=http://localhost:5173/config.json
   ```

**Kenapa langkah 5 wajib.** Di Windows, Vite secara bawaan hanya membuka
port di alamat IPv6 (`[::1]`), sedangkan `adb reverse` meneruskan
permintaan HP ke alamat IPv4 laptop. Browser di laptop tetap bisa membuka
`localhost:5173`, jadi dari laptop semuanya terlihat normal, tapi dari HP
berkas konfigurasi tidak pernah sampai. Aplikasi lalu jatuh ke
konfigurasi cadangan yang menunjuk `10.0.2.2`, alamat khusus emulator,
dan HP sungguhan tidak bisa menjangkaunya. API tidak kena masalah ini
karena ia membuka IPv4 dan IPv6 sekaligus.

Cara mengenalinya: layar galat di aplikasi menampilkan blok **Memakai
konfigurasi cadangan**, dengan alamat API `10.0.2.2`. Cek dari laptop
dengan `netstat -ano | findstr :5173`. Kalau yang tertulis hanya
`[::1]:5173`, Vite dijalankan tanpa `--host 127.0.0.1`.

**Penerusan port hilang setiap kali kabel terputus.** Kalau HP sempat
tercabut atau tersambung ulang, jalankan lagi dua perintah `adb reverse`
di langkah 2, lalu tekan `R` besar di terminal `flutter run` untuk hot
restart. Periksa dengan `adb reverse --list`.

## Yang masih perlu disesuaikan

Tata letak dan warna layar chat dipindahkan dari rancangan Yardan (bola
gelombang, kartu lapisan suara, warna) di atas mesin suara Irawan
(Porcupine, wake word, layanan latar depan). Ini tempelan yang
disengaja — cepat dipasang, bukan rancangan akhir — dan beberapa hal
sengaja belum dirapikan:

- **Bentuk interaksinya sudah diubah dari rancangan asli Yardan.**
  Rancangan pertama menaruh Suara dan Chat sebagai dua tab sejajar yang
  bisa ditukar. Itu janggal: wake word bisa menyela dari tab mana pun,
  jadi ia bukan tab, melainkan sesuatu yang menyela. Sekarang chat
  adalah satu-satunya rumah, dan lapisan suara (`_voiceOverlay` di
  `chat_page.dart`) muncul menimpa layar itu saat mikrofon ditekan atau
  kata pemicu terdengar, lalu menutup dirinya sendiri begitu ucapan
  selesai dikirim.
- **Percakapan suara berkelanjutan.** Balasan Agent atas ucapan
  dibacakan (`lib/voice/tts_engine.dart`, `flutter_tts`, id-ID), lalu
  mikrofon dibuka lagi untuk lanjutan tanpa "Hallo Wangsa". Diam atau
  tidak ada ucapan mengakhiri percakapan dan kata pemicu menyala lagi.
  Selama percakapan, kata pemicu sengaja mati supaya suara Agent tidak
  terdengar olehnya. Pesan yang diketik tidak dibacakan. Kode TTS lama
  Yardan (`tts_output*.dart`) tidak dipakai karena menembak lalu lupa,
  sedangkan di sini mikrofon baru boleh dibuka setelah suaranya selesai.
  Tombol "Bacakan" per gelembung belum ada.
- **Pemilih Agent belum ada.** Tombol menu Yardan yang membuka daftar
  Agent sengaja tidak dipindahkan — backend memang tidak menyediakan
  endpoint untuk mendaftar Agent yang ada (lihat `docs/API.md`), supaya
  orang luar tidak bisa menebak Agent apa saja yang berjalan.
- **`assets/logo.png` masih PNG mentah, tidak dipakai kode mana pun.**
  Vektornya sekarang ada di `assets/logo.svg` (dipakai `ChatNotice.empty`
  lewat `flutter_svg`) — PNG ini sisa sebelum itu, dibiarkan sampai ada
  keputusan menghapusnya sekalian atau tidak.

## Koneksi tanpa enkripsi saat pengembangan

Sejak Android 9, koneksi tanpa enkripsi ditolak diam-diam. Karena itu
`android/app/src/debug/AndroidManifest.xml` mengizinkannya **hanya untuk
build debug**. Build rilis tetap menolak dan wajib memakai HTTPS.

## Memeriksa

```bash
flutter analyze
flutter test
```

Catatan: aplikasi Flutter saat ini adalah client untuk Agent publik yang sudah
dipublish. Daftar Agent workspace dan aksi hapus dikelola di web builder karena
keduanya membutuhkan identity, workspace, dan permission owner.
