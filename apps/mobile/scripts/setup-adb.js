import { execSync } from 'child_process';

// Adapted from wangsa/scripts/setup-adb.js: forwards the Wangsa wangsa_mobile
// plugin's port (default 9901) instead of the old wangsa web app's 3001/5173,
// so a physical Android device reaching `localhost:9901` gets routed to the
// Wangsa gateway running on the host machine.
const PORT = process.env.WANGSA_MOBILE_PORT || '9901';

try {
  const devicesOutput = execSync('adb devices', { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] });
  const devices = devicesOutput
    .trim()
    .split('\n')
    .slice(1)
    .filter((line) => line.trim().length > 0 && line.includes('device') && !line.includes('offline'));

  if (devices.length > 0) {
    execSync(`adb reverse tcp:${PORT} tcp:${PORT}`, { stdio: 'ignore' });
    console.log(`\x1b[32m[Wangsa ADB]\x1b[0m Port ${PORT} berhasil di-reverse ke ${devices.length} perangkat Android.`);
  }
} catch {
  // Silent fallback jika adb belum ada di PATH atau tidak ada perangkat
}
