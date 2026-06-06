// Shared token logic for the clinic queue — used by both display.js and
// appointment.js. The token rotates every TOKEN_WINDOW_MS so a URL captured
// at home becomes invalid quickly.
//
// NOTE: this is "security by deterrence" — the JS is public, so a determined
// user can read this file and compute a valid token. It's intended to stop
// casual misuse (someone typing /appointment.html at home and grabbing a
// number), not to be cryptographically airtight.

window.QueueToken = (() => {
  const SECRET = 'almadina-clinic-queue-v1-2026';
  const TOKEN_WINDOW_MS = 10 * 60 * 1000; // 10 minutes

  // Stable clinic scan token — the QR uses this so it NEVER expires (a printed
  // QR or a slightly-old scan always works). The clinic display is staff-only,
  // and walk-ins always join the current session regardless of time/schedule.
  const SCAN_TOKEN = 'amq7f3k9scan';

  // Display staff key — required on display.html as ?key=<this>
  const DISPLAY_KEY = 'rayis-clinic-screen-2026';

  function currentSlot() {
    return Math.floor(Date.now() / TOKEN_WINDOW_MS);
  }

  async function makeToken(slot) {
    const data = new TextEncoder().encode(`${SECRET}:${slot}`);
    const buf = await crypto.subtle.digest('SHA-256', data);
    return Array.from(new Uint8Array(buf))
      .slice(0, 6)
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');
  }

  async function current() {
    return makeToken(currentSlot());
  }

  // Accept current slot OR the previous one — gives ~10 minutes of grace
  // for slow scans / network hiccups around a window boundary.
  async function isValid(token) {
    if (!token || typeof token !== 'string') return false;
    const slot = currentSlot();
    const a = await makeToken(slot);
    const b = await makeToken(slot - 1);
    return token === a || token === b;
  }

  function checkDisplayKey(key) {
    return typeof key === 'string' && key === DISPLAY_KEY;
  }

  function scanToken() { return SCAN_TOKEN; }

  return { current, isValid, scanToken, checkDisplayKey, TOKEN_WINDOW_MS, DISPLAY_KEY, SCAN_TOKEN };
})();
