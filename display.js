// Al Madina Polyclinic — clinic display screen
// Shows a QR code patients scan with their phones, plus a live counter
// of the latest number issued today.

const COUNTER_NS = 'almadina-polyclinic';
const GET_URL = (key) => `https://abacus.jasoncameron.dev/get/${COUNTER_NS}/${key}`;
const POLL_MS = 5000;

const $ = (id) => document.getElementById(id);

// Counter key — rotates at midnight AND at 3 PM so the morning and
// evening clinic sessions each start fresh at #1.
function sessionKey() {
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  const session = d.getHours() < 15 ? 'am' : 'pm';
  return `${y}-${m}-${day}-${session}`;
}

function prettyDate() {
  return new Date().toLocaleDateString('en-IN', {
    weekday: 'long', day: 'numeric', month: 'long', year: 'numeric'
  });
}

function todayHours() {
  const day = new Date().getDay();
  if (day === 0) return '🕐 Sun · 10:00 AM – 1:30 PM';
  return '🕐 Mon–Sat · 9:30–10:30 AM & 4:30–6:30 PM';
}

// The page that patients land on after scanning. Defaults to /appointment.html
// on the same origin. Override with &url=https://...
function appointmentBaseURL() {
  const params = new URLSearchParams(location.search);
  const override = params.get('url');
  if (override) return override;
  if (location.protocol === 'file:' || location.hostname === 'localhost' || location.hostname === '127.0.0.1') {
    return 'https://www.almadinapolyclinic.com/appointment.html';
  }
  return new URL('appointment.html', location.href).toString();
}

async function buildScanURL() {
  const base = appointmentBaseURL();
  const token = await window.QueueToken.current();
  const sep = base.includes('?') ? '&' : '?';
  return `${base}${sep}t=${token}`;
}

async function renderQR() {
  const url = await buildScanURL();
  const size = 600;
  const src = `https://api.qrserver.com/v1/create-qr-code/?size=${size}x${size}&margin=10&qzone=2&format=svg&data=${encodeURIComponent(url)}`;
  $('qr-img').src = src;
}

let lastValue = null;

async function pollCounter() {
  try {
    const res = await fetch(GET_URL(sessionKey()), { cache: 'no-store' });
    let value = 0;
    if (res.ok) {
      const data = await res.json();
      if (typeof data.value === 'number') value = data.value;
    }
    updateLive(value);
  } catch (err) {
    console.warn('Counter poll failed:', err);
  }
}

function updateLive(value) {
  const el = $('d-latest');
  const sub = $('d-live-sub');
  el.textContent = value > 0 ? '#' + value : '#0';
  if (value === 0) {
    sub.textContent = 'Be the first patient of the session 👋';
  } else if (value === 1) {
    sub.textContent = '1 number issued so far this session';
  } else {
    sub.textContent = `${value} numbers issued so far this session`;
  }
  if (lastValue !== null && value > lastValue) {
    el.classList.remove('bump');
    void el.offsetWidth; // restart animation
    el.classList.add('bump');
  }
  lastValue = value;
}

function init() {
  // Staff-only gate: require ?key=<DISPLAY_KEY> to load the screen.
  const key = new URLSearchParams(location.search).get('key');
  if (!window.QueueToken.checkDisplayKey(key)) {
    $('d-gate').classList.remove('hidden');
    $('d-main').classList.add('hidden');
    return;
  }
  $('d-gate').classList.add('hidden');
  $('d-main').classList.remove('hidden');

  $('d-date').textContent = prettyDate();
  $('d-hours').textContent = todayHours();
  renderQR();
  pollCounter();

  setInterval(pollCounter, POLL_MS);

  // Refresh the QR every half-window so a fresh token is always shown
  // before the previous one is invalidated.
  setInterval(renderQR, Math.max(60_000, window.QueueToken.TOKEN_WINDOW_MS / 2));

  // Refresh date / hours every minute so a left-on display rolls over at midnight.
  setInterval(() => {
    $('d-date').textContent = prettyDate();
    $('d-hours').textContent = todayHours();
  }, 60_000);
}

document.addEventListener('DOMContentLoaded', init);
