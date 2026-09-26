import { execFileSync } from 'child_process';
import { existsSync } from 'fs';
import { homedir, platform } from 'os';
import { join } from 'path';

// Meneruskan port plugin wangsa_mobile (default 9901) dari host ke tiap
// perangkat Android yang tersambung, supaya `localhost:9901` di HP
// diteruskan ke gateway Wangsa di laptop.
//
// Kenapa berkas ini penting: `adb reverse` HILANG setiap kabel dicabut /
// perangkat tersambung ulang. Tanpa reverse, aplikasi hanya melihat
// "Tidak bisa menghubungi API Wangsa" tanpa tahu sebabnya — padahal
// backend-nya hidup. Sejak ada auto-fallback di aplikasi
// (lib/api/api_endpoints.dart), kasus ini pulih sendiri bila reverse
// dipasang ulang; skrip ini yang memasangnya.
//
// Keluar 0 bila tidak ada perangkat (emulator memakai 10.0.2.2 dan tidak
// butuh reverse) atau semua reverse terverifikasi. Keluar 1 hanya bila ada
// perangkat tapi reverse-nya gagal dipasang — supaya pemanggil
// (run.ps1 / CI) tahu ada yang salah, bukan diam-diam lanjut.
const PORT = process.env.WANGSA_MOBILE_PORT || '9901';

// adb sering tidak ada di PATH (Android Studio tidak menambahkannya),
// jadi cari di lokasi SDK bawaan sebelum menyerah.
function resolveAdb() {
  const candidates = [];
  if (process.env.ANDROID_HOME) {
    candidates.push(join(process.env.ANDROID_HOME, 'platform-tools', 'adb'));
  }
  if (process.env.ANDROID_SDK_ROOT) {
    candidates.push(join(process.env.ANDROID_SDK_ROOT, 'platform-tools', 'adb'));
  }
  const home = homedir();
  if (platform() === 'win32') {
    if (process.env.LOCALAPPDATA) {
      candidates.push(join(process.env.LOCALAPPDATA, 'Android', 'Sdk', 'platform-tools', 'adb.exe'));
    }
  } else if (platform() === 'darwin') {
    candidates.push(join(home, 'Library', 'Android', 'sdk', 'platform-tools', 'adb'));
  } else {
    candidates.push(join(home, 'Android', 'Sdk', 'platform-tools', 'adb'));
  }
  candidates.push('adb'); // terakhir: andalkan PATH
  for (const c of candidates) {
    if (c === 'adb') return c;
    try {
      if (existsSync(c)) return c;
    } catch {
      // abaikan, lanjut kandidat berikut
    }
  }
  return 'adb';
}

function run(adb, args) {
  return execFileSync(adb, args, { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'] });
}

const adb = resolveAdb();

let devicesOutput;
try {
  devicesOutput = run(adb, ['devices']);
} catch {
  console.warn(
    `[Wangsa ADB] adb tidak ditemukan. Pasang Android platform-tools atau set ANDROID_HOME, ` +
      `lalu jalankan manual: adb reverse tcp:${PORT} tcp:${PORT}`,
  );
  process.exit(0);
}

const serials = devicesOutput
  .trim()
  .split('\n')
  .slice(1)
  .map((line) => line.trim().split(/\s+/))
  .filter((parts) => parts.length >= 2 && parts[1] === 'device')
  .map((parts) => parts[0]);

if (serials.length === 0) {
  console.log('[Wangsa ADB] Tidak ada perangkat fisik — lewati (emulator memakai 10.0.2.2).');
  process.exit(0);
}

let failed = 0;
for (const serial of serials) {
  try {
    run(adb, ['-s', serial, 'reverse', `tcp:${PORT}`, `tcp:${PORT}`]);
  } catch {
    console.error(`[Wangsa ADB] Gagal reverse ${PORT} di ${serial}.`);
    failed++;
  }
}

// Verifikasi PER-SERIAL. Dua bug lama digabung jadi satu perbaikan:
// (1) `adb reverse --list` tanpa `-s` error "more than one device/emulator"
//     bila ada >1 perangkat — skrip lama selalu warning walau reverse sukses;
// (2) baris `--list` memuat nama transport (mis. `UsbFfs`/`host-15`), bukan
//     serial perangkat, jadi pencocokan `list.includes(serial)` mustahil
//     cocok. Yang diverifikasi cukup: port-nya ada di daftar reverse
//     perangkat itu.
let verified = 0;
for (const serial of serials) {
  try {
    const list = run(adb, ['-s', serial, 'reverse', '--list']).trim();
    if (list.includes(`tcp:${PORT}`)) {
      verified++;
    } else {
      console.error(`[Wangsa ADB] Reverse ${PORT} tidak tercatat di ${serial}.`);
      failed++;
    }
  } catch {
    console.warn(`[Wangsa ADB] Verifikasi reverse gagal di ${serial}.`);
    failed++;
  }
}
console.log(
  `\x1b[32m[Wangsa ADB]\x1b[0m Port ${PORT} di-reverse ke ${verified}/${serials.length} perangkat. ` +
    `Periksa ulang kapan saja: adb -s <serial> reverse --list`,
);

process.exit(failed > 0 ? 1 : 0);
