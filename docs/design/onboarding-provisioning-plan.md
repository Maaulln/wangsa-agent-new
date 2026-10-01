# Plan: Multi-user isolated bot provisioning — wangsaxhermes

Project: `~/Develop/wangsaxhermes` (fork langsung dari NousResearch/hermes-agent,
di-rebrand "Wangsa" lewat `wangsa_*.py` / `wangsa_cli/`). **Beda project** dari
`~/Develop/wangsa` (rewrite TS/Bun terpisah, punya plan.md sendiri) — dokumen ini
HANYA soal wangsaxhermes.

## Masalah yang mau diselesaikan

Pemilik project mau: setiap end-user punya bot Telegram sendiri (token sendiri),
dan brain/state antar user **tidak connect sama sekali** — isolasi level proses
OS, bukan cuma isolasi data dalam satu proses.

## Apa yang sudah ada di core Hermes/wangsaxhermes (JANGAN dibangun ulang)

Riset terhadap `wangsa_cli/` dan `gateway/` menemukan bahwa isolasi proses penuh
**sudah menjadi fitur bawaan**, hanya belum diotomasi untuk banyak user:

1. **`hermes profile create <nama> [--clone/--clone-from/--clone-all]`**
   (`wangsa_cli/profiles.py:1126`, `create_profile()`) — bikin
   `~/.hermes/profiles/<nama>/` dengan config.yaml, .env, SOUL.md, skills sendiri.
   Sudah dipakai manual di mesin ini (profile `default`, `maaulln_bot`, `maulana1-`).
2. **`hermes --profile <nama> gateway install`** (`wangsa_cli/gateway.py`,
   `launchd_install()` baris 5141 / `systemd_install()` baris 3972) — bikin
   service OS **sendiri** per profile: macOS `~/Library/LaunchAgents/ai.hermes.gateway-<nama>.plist`,
   Linux systemd unit `hermes-gateway-<nama>`. Ini SUDAH proses OS terpisah total —
   crash/restart satu profile tidak menyentuh profile lain, tepat pola "1 bot =
   1 proses" yang disebutkan (mirror dari temannya pemilik project yang pakai
   `screen` — bedanya di sini formalized lewat launchd/systemd, bukan terminal
   multiplexer manual).
3. **`_guard_named_profile_under_multiplexer()`** (`wangsa_cli/gateway.py` ~5621)
   — proteksi bawaan yang MENOLAK `hermes --profile X gateway run` kalau
   `multiplex_profiles: true` aktif di profile default, karena itu akan
   double-bind token/port. Konfirmasi eksplisit dari core sendiri: profile
   bertoken-sendiri harus proses independen, bukan lewat multiplexer.
4. **`gateway/profile_routing.py`** — ini solusi untuk kasus BERBEDA (banyak
   user berbagi SATU token bot, di-routing dalam satu proses via
   `multiplex_profiles`). Pemilik project sempat mengerjakan ini (commit
   `bcf7f85d`/`24c980d9`, menambah matching by `user_id`), TAPI keputusan baru
   di sesi ini: **tidak dipakai untuk kasus "tiap user token sendiri"** — 1
   token Telegram hanya boleh di-poll oleh 1 proses (`getUpdates` conflict kalau
   dua proses pegang token yang sama), jadi routing-dalam-satu-proses tidak
   applicable di sini. `profile_routing.py` TETAP berguna sebagai fitur terpisah
   untuk operator yang sengaja mau banyak komunitas berbagi satu bot — tidak
   dihapus, hanya tidak menjadi jalur untuk kebutuhan ini.
5. **`hermes gateway list`** (`wangsa_cli/gateway.py`) — sudah menampilkan semua
   profile + status gateway masing-masing, bisa dipakai langsung sebagai
   monitoring provisioning tanpa kode baru.

## Gap yang sebenarnya harus ditutup

Bukan mekanisme isolasi (sudah ada), tapi **otomasi**: langkah 1-2 di atas saat
ini manual (operator jalanin `profile create` lalu `gateway install` satu-satu
di CLI). Untuk N user self-serve, ini harus jadi alur otomatis dipicu dari chat.

## Desain: Onboarding bot

Satu proses gateway "onboarding" (profile `default`, TIDAK multiplexed — cuma
dia sendirian, `multiplex_profiles: false`) yang tugasnya sempit:

1. Nerima pesan dari calon user baru berisi token bot Telegram BARU milik
   mereka (dibuat lewat @BotFather sendiri — token tidak pernah dibuat oleh
   sistem, hanya diterima).
2. Validasi dasar: format token, dan test call `getMe` ke Telegram API untuk
   pastikan token valid & belum dipakai profile lain di install ini
   (cross-check terhadap `.env` semua profile yang sudah ada, mencegah dua
   profile berebut token yang sama).
3. Provisioning berurutan, dan **berhenti/rollback bersih kalau langkah
   manapun gagal** (jangan tinggalkan profile setengah jadi):
   a. `create_profile(name=<derived-dari-identitas-user>, no_skills=False)` —
      reuse `wangsa_cli/profiles.py` langsung, tidak reimplement.
   b. Tulis token ke `profiles/<nama>/.env` sebagai `TELEGRAM_BOT_TOKEN`
      (bukan lewat `save_env_value` yang menulis ke profile aktif — perlu
      varian yang menulis ke path `.env` milik profile lain secara eksplisit;
      cek dulu apakah `save_env_value` sudah menerima target path, kalau
      belum tambahkan parameter, jangan tulis file .env secara manual di luar
      helper yang ada).
   c. `hermes --profile <nama> gateway install` lalu `gateway start` (reuse
      `launchd_install()`/`systemd_install()` sesuai OS — deteksi OS sudah ada
      di gateway.py, jangan duplikasi).
4. Balas ke user: sukses (bot mereka sudah hidup, kasih cara chat ke bot itu)
   atau gagal dengan alasan jelas (token invalid / token dipakai orang lain /
   provisioning gagal di langkah mana).
5. Simpan mapping ringan **requester Telegram user_id → nama profile yang
   diprovision** (bukan brain, hanya administrasi — supaya user bisa nanya
   "bot saya yang mana" atau minta reset/hapus lewat onboarding bot yang
   sama). Simpan sebagai file/tabel kecil di HOME onboarding bot sendiri
   (`~/.hermes/wangsa-onboarding-registry.json` atau sejenis), BUKAN di brain
   satu profile manapun.

## Yang TIDAK dikerjakan di plan ini (eksplisit out of scope)

- Tidak mengubah `profile_routing.py` / `multiplex_profiles` — jalur itu tetap
  ada untuk operator yang butuhnya, tidak disentuh.
- Tidak membangun supervisor/IPC custom seperti draft awal sebelum riset ini
  (child-process worker + unix socket) — itu solusi yang dirancang SEBELUM
  ketemu bahwa launchd/systemd install-per-profile sudah menutupi kebutuhan
  yang sama secara native dan lebih teruji.
- Tidak mengotomasi pembuatan token bot Telegram itu sendiri (user tetap bikin
  sendiri lewat @BotFather) — di luar kendali sistem, dan menghindari
  menyimpan kredensial BotFather siapa pun.

## Sequencing

1. ~~Cek `save_env_value`~~ — SELESAI, tidak perlu extend. Terbukti (dites
   langsung, bukan dibaca kodenya saja) bahwa `save_env_value` sudah
   scope-aware lewat `set_hermes_home_override()`/`reset_hermes_home_override()`
   (contextvar): membungkus panggilan dalam scope profile lain menulis ke
   `.env` profile itu, bukan ke root. Root `.env` tetap tidak tersentuh.
2. **SELESAI** — `wangsa_cli/onboarding_provision.py`: modul orkestrasi murni,
   fungsi-fungsi:
   - `looks_like_bot_token()` — shape check sebelum I/O apa pun.
   - `token_already_in_use()` — scan `.env` semua profile lewat context
     override, cegah dua profile berebut token yang sama.
   - `verify_bot_token_live()` — panggil `getMe` Telegram Bot API.
   - `provision_profile_for_token()` — orkestrasi penuh: validasi → cek
     konflik → verifikasi live → `create_profile()` → tulis token → install+
     start gateway. Setiap tahap gagal melempar `ProvisioningError` dengan
     `.stage` yang jelas (`token_invalid`, `token_conflict`,
     `token_unreachable`, `profile_exists`, `token_write_failed`,
     `gateway_install_failed`, `gateway_start_failed`).
   - `ensure_gateway_installed_and_started()` — spawn `hermes --profile
     <nama> gateway install --start-now` lalu `gateway start` sebagai
     SUBPROCESS nyata (bukan panggil `launchd_install()` in-process),
     supaya `--profile` diproses lewat jalur intercept argv yang sama
     seperti pemakaian manual operator (`wangsa_cli/main.py`), menghindari
     campur `HERMES_HOME` context-override dengan proses yang sedang
     berjalan.
   - Test: `tests/wangsa_cli/test_onboarding_provision.py`, 20 test, semua
     lulus (token invalid, token conflict, network error, subprocess
     gagal di tiap tahap, full success path, retry-safety setelah gagal
     di tahap akhir). Tidak ada regresi di
     `tests/wangsa_cli/test_profiles.py` maupun
     `tests/gateway/test_profile_resolution.py` (total 88 passed, 2
     skipped — skip pre-existing, bukan dari perubahan ini).
   - Diverifikasi manual di `HERMES_HOME` sandbox terisolasi (`/tmp`, bukan
     home asli) sebelum ditulis sebagai test permanen, sesuai preferensi
     dry-run dulu.
3. **BELUM** — Sambungkan `provision_profile_for_token()` ke handler pesan
   bot onboarding (gateway terpisah, `multiplex_profiles: false`,
   percakapan sederhana: "kirim token bot Anda" → panggil fungsi ini →
   balas hasil).
4. **BELUM** — Simpan mapping requester → profile (lihat bagian "Desain:
   Onboarding bot" poin 5) untuk keperluan self-service reset/cek status.
5. **BELUM** — Uji end-to-end SUNGGUHAN dengan satu token bot Telegram
   baru asli (bukan token produksi) — modul di atas baru diverifikasi
   dengan subprocess/network di-stub; `hermes gateway install --start-now`
   yang sesungguhnya belum pernah benar-benar dijalankan oleh modul ini.
6. **BELUM** — Dokumentasi `docs/onboarding-provisioning.md` mengikuti pola
   `docs/profile-routing.md`.

## Temuan besar (menggeser arah, disimpan agar tidak diulang risetnya)

Setelah eksekusi sampai poin 2 di atas, ditemukan **`apps/mobile_backend`**
(FastAPI, port 9902) + **`apps/mobile`** (Flutter, sudah connect ke
`/api/mobile/v1`) — sistem signup + isolasi per-user yang SUDAH LENGKAP
dan terpisah dari jalur onboarding-bot-Telegram di atas:

- Signup/login sendiri (`POST /api/mobile/v1/auth/signup`), token per user,
  password di-hash scrypt bersalt, dijamin lewat SQLite dengan tenant
  ownership check di query — bukan lewat filter aplikasi yang bisa lupa.
- **Isolasi per JOB, bukan per proses OS**: tiap job agent jalan di
  container Docker sendiri (non-root, read-only rootfs, capabilities
  di-drop, resource+time limit, named volume per tenant, bridge network
  sendiri, tidak ada port dipublish). Kredensial masuk lewat stdin, tidak
  pernah lewat argumen/env container.
- **Diverifikasi hidup, bukan cuma dibaca kodenya**, pada sesi ini:
  1. `docker build -f Dockerfile.mobile-runtime -t wangsa-mobile-runtime:local .` — sukses.
  2. Full test suite `tests/mobile_backend` — **35/35 lulus** (termasuk
     `test_docker_acceptance.py`, yang memakai container Docker ASLI, 2
     tenant volume terpisah, ~43 detik) — sebelumnya 3 test ini skip
     karena Docker daemon mati, sekarang jalan penuh setelah Docker
     Desktop dinyalakan.
  3. `python -m apps.mobile_backend init/doctor/serve` dijalankan
     sungguhan (bukan simulasi): 2 user asli (`alphauser`, `betauser`)
     signup lewat HTTP, masing-masing dapat token/id berbeda,
     `auth/me` dan `GET /jobs` dikonfirmasi tidak bisa saling lihat data
     satu sama lain. Job dibuat untuk kedua user secara paralel — log
     event `"Menyiapkan ruang kerja agent yang terisolasi."` muncul untuk
     KEDUANYA, membuktikan provisioning container-per-job benar jalan.
     Kedua job berakhir `failed` karena provider `opencode-free` menolak
     dipakai di luar aplikasi OpenCode resmi (pembatasan provider pihak
     ketiga, BUKAN kegagalan isolasi) — bukti isolasi sesungguhnya ada di
     test #2, yang tidak bergantung pada provider eksternal manapun.

**Implikasi untuk rencana onboarding-bot Telegram (poin 3-6 di atas):**
Kalau kebutuhan sebenarnya adalah "user daftar sendiri dan dapat ruang
kerja terisolasi", jalur **mobile_backend sudah menutupi itu sepenuhnya**
hari ini — tidak ada gap tersisa untuk kasus itu, tidak butuh onboarding
bot maupun provisioning profile+launchd sama sekali. Jalur onboarding-bot
Telegram (poin 1-2, sudah selesai) tetap berguna HANYA untuk skenario
berbeda: user yang ingin **bot Telegram pribadi miliknya sendiri**
(percakapan lewat Telegram, bukan lewat app Flutter) dengan token bot
sendiri — pekerjaan itu independen dari mobile_backend dan tidak saling
menggantikan. Operator/pemilik project perlu memutuskan yang mana yang
sebenarnya diprioritaskan sebelum poin 3-6 dikerjakan, karena efeknya kini
terasa redundan dengan sistem yang sudah berjalan.

## Verifikasi tambahan — job COMPLETED nyata + isolasi silang dibuktikan aktif

Verifikasi sebelumnya (init/doctor/serve manual) job-nya `failed` karena
provider eksternal (`opencode-free`) menolak dipakai di luar app OpenCode.
Supaya bukti isolasi tidak bergantung pada policy provider pihak ketiga,
dijalankan verifikasi tambahan pakai server live (port 9903) dengan
`FixtureRuntime` yang SAMA PERSIS dipakai `test_docker_acceptance.py`
(model deterministic disuntik sebagai entrypoint container pengganti,
AIAgent/tool/runtime-nya tetap kode produksi asli) — bukan lagi lewat
`pytest`, tapi lewat `curl` sungguhan ke server yang benar-benar berjalan:

- 2 user baru signup (`alicelive`, `bobbylive`), masing-masing dapat
  token+id berbeda.
- Job `phase-write` (alice) dan `phase-empty` (bobby) diajukan paralel,
  keduanya **status `completed`** (bukan `failed`) dengan report
  `"Deterministic Docker acceptance: {\"output\": \"BOUNDARY_OK\", ...}"`.
  `BOUNDARY_OK` berarti probe keamanan di dalam container ASLI masing-
  masing user lulus semua assert: `os.getuid()==10001` (non-root),
  `CapEff==0` (semua Linux capability di-drop), `NoNewPrivs==1`, docker
  socket host tidak tembus ke dalam container, dan percobaan tulis ke
  path terlarang (`/opt/wangsa/forbidden-write`,
  `/data/home/skills/forbidden-write`) gagal.
- **Isolasi silang dibuktikan aktif, bukan diasumsikan**: token bobby
  dipakai untuk `GET` job milik alice → **HTTP 404** (job tidak
  ditemukan, bukan 403 — dari sisi bobby job itu tidak pernah ada);
  `POST .../cancel` job alice pakai token bobby → **404** juga; request
  tanpa token sama sekali → **401**.
- `docker volume ls` menunjukkan satu named volume Docker terpisah per
  tenant (`wangsa-mobile-<user-id>`) — 16 volume berbeda terakumulasi
  dari seluruh sesi verifikasi hari ini, satu per user/tenant yang pernah
  dibuat, tidak ada yang dibagi.
- Semua resource verifikasi (server test, deployment sementara, 16
  Docker volume, file sementara) sudah dibersihkan setelah selesai —
  tidak ada sisa di lingkungan pengguna.

**Kesimpulan yang bisa dipegang**: isolasi per-tenant di `mobile_backend`
bukan klaim dari membaca kode atau lolos test suite saja — sudah
dibuktikan lewat siklus signup → job berjalan sampai selesai → akses
silang ditolak, di server yang benar-benar hidup dengan container Docker
sungguhan, dua kali (sekali lewat pytest resmi, sekali lewat curl manual
independen).
