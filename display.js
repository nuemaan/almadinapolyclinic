// Al Madina Polyclinic — clinic display screen
// Shows a rotating QR code patients scan with their phones, plus the live
// queue read straight from Supabase (latest number issued + now serving).

const POLL_MS = 5000;
const sb = window.supabaseClient;
const $ = (id) => document.getElementById(id);

function prettyDate() {
  return new Date().toLocaleDateString('en-IN', {
    weekday: 'long', day: 'numeric', month: 'long', year: 'numeric'
  });
}
function todayHours() {
  const day = new Date().getDay();
  if (day === 0) return '🕐 Sun · 10:00 AM – 1:30 PM & 6:30–8:00 PM';
  return '🕐 Mon–Sat · 9:00–10:00 AM & 5:30–8:30 PM';
}

// The page patients land on after scanning. Defaults to /appointment.html on
// the same origin. Override with &url=https://...
function appointmentBaseURL() {
  const override = new URLSearchParams(location.search).get('url');
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
  $('qr-img').src = `https://api.qrserver.com/v1/create-qr-code/?size=${size}x${size}&margin=10&qzone=2&format=svg&data=${encodeURIComponent(url)}`;
}

let lastIssued = null;

async function pollQueue() {
  try {
    const { data, error } = await sb.rpc('queue_status');
    if (error) throw error;
    updateLive(data);
  } catch (err) {
    console.warn('Queue poll failed:', err);
  }
}

function updateLive(s) {
  const el = $('d-latest');
  const sub = $('d-live-sub');
  const issued = s.last_issued || 0;
  el.textContent = issued > 0 ? '#' + issued : '#0';

  const parts = [];
  if (s.now_serving != null) parts.push(`Now serving #${s.now_serving}`);
  if ((s.waiting || 0) > 0) parts.push(`${s.waiting} waiting`);
  if (issued === 0) sub.textContent = 'Be the first patient of the session 👋';
  else sub.textContent = parts.length ? parts.join(' · ') : `${issued} issued so far this session`;

  if (lastIssued !== null && issued > lastIssued) {
    el.classList.remove('bump'); void el.offsetWidth; el.classList.add('bump');
  }
  lastIssued = issued;
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
  pollQueue();

  setInterval(pollQueue, POLL_MS);
  // Refresh the QR every half-window so a fresh token is always shown.
  setInterval(renderQR, Math.max(60_000, window.QueueToken.TOKEN_WINDOW_MS / 2));
  // Roll over date / hours each minute (handles a left-on screen at midnight).
  setInterval(() => {
    $('d-date').textContent = prettyDate();
    $('d-hours').textContent = todayHours();
  }, 60_000);
}

document.addEventListener('DOMContentLoaded', init);
