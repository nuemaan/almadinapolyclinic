// Al Madina Polyclinic — appointment booking page (Supabase-backed)
//
// Two entry modes:
//   • HOME  — opened directly (no QR token). Allowed only inside the booking
//             window; the database enforces this.
//   • WALK-IN — opened by scanning the clinic QR (?t=<rotating token>). The
//             database validates the token, so it works any time the clinic
//             is showing the QR, and bypasses the home window.
// Either way the patient enters name + phone and is issued a queue token from
// one shared, self-resetting (am/pm) sequence.

const STORAGE_KEY = 'almadina_appt';
const MAX_PER_FAMILY = 3;
const STATUS_POLL_MS = 8000;

const sb = window.supabaseClient;
const $ = (id) => document.getElementById(id);

const states = {
  form:    $('state-form'),
  gate:    $('state-gate'),
  loading: $('state-loading'),
  ticket:  $('state-ticket'),
  error:   $('state-error'),
};
function show(name) {
  Object.entries(states).forEach(([k, el]) => el && el.classList.toggle('hidden', k !== name));
}

// QR scan token (present => walk-in mode)
const qrToken = new URLSearchParams(location.search).get('t');
const isWalkin = !!qrToken;

// ---- session + date helpers (client display only; the DB is source of truth)
function sessionKey() {
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  const session = d.getHours() < 15 ? 'am' : 'pm';
  return `${y}-${m}-${day}-${session}`;
}
function prettyDate() {
  return new Date().toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
}
function todayHours() {
  const day = new Date().getDay();
  if (day === 0) return '10:00 AM–1:30 PM & 6:30–8:00 PM';
  return '9:00–10:00 AM & 5:30–8:30 PM';
}
function ordinal(n) {
  const s = ['th','st','nd','rd'], v = n % 100;
  return n + (s[(v - 20) % 10] || s[v] || s[0]);
}
function to12h(hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  const ap = h < 12 ? 'AM' : 'PM';
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}:${String(m).padStart(2, '0')} ${ap}`;
}

// ---- local storage of this device's tokens for the current session
function loadSaved() {
  try {
    const data = JSON.parse(localStorage.getItem(STORAGE_KEY));
    if (data && data.session === sessionKey() && Array.isArray(data.patients) && data.patients.length) return data;
  } catch {}
  return null;
}
function save(patients, phone) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ session: sessionKey(), patients, phone: phone || '' }));
  } catch {}
}

// ---- rendering
let statusTimer = null;

function renderTicket(patients) {
  const numEl = $('ticket-num'), numsEl = $('ticket-nums');
  const labelEl = $('ticket-label'), subEl = $('ticket-sub');
  const tokens = patients.map(p => p.token);

  if (patients.length === 1) {
    numEl.textContent = '#' + tokens[0];
    numEl.classList.remove('hidden');
    numsEl.classList.add('hidden');
    numsEl.innerHTML = '';
    labelEl.textContent = 'Your number';
    subEl.textContent = `${patients[0].name} · ${ordinal(tokens[0])} in today's queue`;
    subEl.classList.remove('hidden');
  } else {
    numEl.classList.add('hidden');
    numsEl.classList.remove('hidden');
    numsEl.innerHTML = patients.map(p => `<span class="num-pill">#${p.token}</span>`).join('');
    labelEl.textContent = `Your ${patients.length} numbers`;
    subEl.textContent = patients.map(p => `#${p.token} ${p.name}`).join('  ·  ');
    subEl.classList.remove('hidden');
  }

  $('ticket-badge').textContent = (patients[0].source === 'home' ? 'Home booking' : 'Walk-in') + " · today's queue";
  $('ticket-date').textContent = prettyDate();
  $('ticket-hours').textContent = todayHours();
  $('add-another-btn').classList.toggle('hidden', patients.length >= MAX_PER_FAMILY);

  show('ticket');
  refreshStatus(); // immediate, then on a timer
  clearInterval(statusTimer);
  statusTimer = setInterval(refreshStatus, STATUS_POLL_MS);
}

async function refreshStatus() {
  const saved = loadSaved();
  if (!saved) return;
  // Track the earliest of this device's tokens (the one called first).
  const primary = Math.min(...saved.patients.map(p => p.token));
  try {
    const { data, error } = await sb.rpc('queue_status', { p_token: primary });
    if (error) throw error;
    paintStatus(data, primary);
  } catch (e) {
    console.warn('status poll failed', e);
  }
}

function paintStatus(s, primary) {
  $('ts-attended').textContent = s.attended ?? 0;
  $('ts-serving').textContent = s.now_serving != null ? '#' + s.now_serving : '—';

  const etaLabel = $('ts-eta-label'), etaEl = $('ts-eta');
  const yourStatus = s.your_status;

  if (yourStatus === 'done') {
    etaLabel.textContent = '✅ Status';
    etaEl.textContent = 'Seen — thank you!';
  } else if (yourStatus === 'attending') {
    etaLabel.textContent = '🔔 Status';
    etaEl.textContent = "It's your turn now!";
  } else if (yourStatus === 'cancelled' || yourStatus === 'noshow') {
    etaLabel.textContent = 'ℹ️ Status';
    etaEl.textContent = 'Please check at reception';
  } else if ((s.ahead ?? 0) === 0) {
    etaLabel.textContent = '⏳ Your turn (approx.)';
    etaEl.textContent = "You're next!";
  } else {
    etaLabel.textContent = `⏳ ${s.ahead} ahead · turn at approx.`;
    const serverNow = s.server_now ? new Date(s.server_now) : new Date();
    const turn = new Date(serverNow.getTime() + (s.eta_seconds || 0) * 1000);
    etaEl.textContent = turn.toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit' });
  }
}

// ---- networking
function friendlyError(err) {
  const m = (err && (err.message || err.code) || '').toString();
  if (m.includes('WINDOW_CLOSED')) return '__WINDOW__';
  if (m.includes('INVALID_SCAN'))  return 'That QR code has expired. Please re-scan the code at the clinic.';
  if (m.includes('NAME_REQUIRED')) return 'Please enter the patient name.';
  if (m.includes('PHONE_INVALID')) return 'Please enter a valid phone number.';
  return null; // unknown -> generic error screen
}

async function bookOne(name, phone) {
  const { data, error } = await sb.rpc('take_token', {
    p_name: name,
    p_phone: phone,
    p_source: isWalkin ? 'walkin' : 'home',
    p_qr_token: qrToken,
  });
  if (error) throw error;
  return data; // a visits row
}

// ---- flows
let addingMore = false;

function showForm({ adding = false } = {}) {
  addingMore = adding;
  const saved = loadSaved();
  $('today-label').textContent = prettyDate();
  $('form-hours').textContent = todayHours();
  $('form-eyebrow').textContent = isWalkin ? '✦ Walk-in queue' : '✦ Book appointment';
  $('form-title').innerHTML = adding
    ? 'Add another <span class="grad">patient</span> 🧒'
    : (isWalkin ? "Get your <span class=\"grad\">queue number</span> 🎟️" : 'Book your <span class="grad">appointment</span> 🎟️');
  $('form-error').classList.add('hidden');
  $('f-name').value = '';
  if (adding && saved && saved.phone) $('f-phone').value = saved.phone;
  show('form');
  $('f-name').focus();
}

async function submitForm() {
  const name = $('f-name').value.trim();
  const phone = $('f-phone').value.trim();
  const errEl = $('form-error');
  errEl.classList.add('hidden');

  if (!name) { errEl.textContent = 'Please enter the patient name.'; errEl.classList.remove('hidden'); return; }
  if (phone.replace(/\D/g, '').length !== 10) { errEl.textContent = 'Please enter a 10-digit mobile number.'; errEl.classList.remove('hidden'); return; }

  $('book-btn').disabled = true;
  show('loading');
  try {
    const visit = await bookOne(name, phone);
    const saved = loadSaved();
    const patients = (addingMore && saved ? saved.patients : []).concat([
      { token: visit.token_number, name, source: visit.source },
    ]);
    save(patients, phone);
    renderTicket(patients);
  } catch (err) {
    console.error('Booking failed:', err);
    const friendly = friendlyError(err);
    if (friendly === '__WINDOW__') { await showGate(); }
    else if (friendly) { showForm({ adding: addingMore }); $('form-error').textContent = friendly; $('form-error').classList.remove('hidden'); }
    else { show('error'); }
  } finally {
    $('book-btn').disabled = false;
  }
}

async function showGate() {
  // Show the configured booking windows for today so patients know when to return.
  try {
    const { data } = await sb.from('settings').select('value').eq('key', 'booking_windows').single();
    const w = data && data.value;
    const dayKey = new Date().getDay() === 0 ? 'sun' : 'mon_sat';
    const d = w && w[dayKey];
    if (d) {
      $('gate-windows').textContent =
        `${to12h(d.am.open)}–${to12h(d.am.close)} · ${to12h(d.pm.open)}–${to12h(d.pm.close)}`;
    }
  } catch (e) { console.warn('window fetch failed', e); }
  show('gate');
}

async function init() {
  $('year').textContent = new Date().getFullYear();

  const saved = loadSaved();
  if (saved) { renderTicket(saved.patients); return; }

  if (isWalkin) {
    showForm();           // DB validates the scan token on submit
    return;
  }

  // Home mode: only show the form if the booking window is open right now.
  try {
    const { data: open, error } = await sb.rpc('is_booking_open');
    if (error) throw error;
    if (open) showForm();
    else await showGate();
  } catch (e) {
    console.error('window check failed', e);
    showForm(); // fail open to the form; the DB will still reject if truly closed
  }
}

// ---- wire up
$('book-btn').addEventListener('click', submitForm);
// Restrict the phone field to digits only, max 10.
$('f-phone').addEventListener('input', (e) => { e.target.value = e.target.value.replace(/\D/g, '').slice(0, 10); });
$('f-phone').addEventListener('keydown', (e) => { if (e.key === 'Enter') submitForm(); });
$('add-another-btn').addEventListener('click', () => showForm({ adding: true }));
$('retry-btn').addEventListener('click', () => { const s = loadSaved(); if (s) renderTicket(s.patients); else init(); });
$('refresh-link').addEventListener('click', (e) => { e.preventDefault(); refreshStatus(); });

document.addEventListener('DOMContentLoaded', init);
