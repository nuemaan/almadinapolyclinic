// Al Madina Polyclinic — appointment booking page (Supabase + smart routing)
//
// On booking we send the patient's name, phone, and (if allowed) GPS location
// to book_appointment(), which picks the earliest session they can actually
// reach: today morning -> today evening -> the next open day. The ticket then
// shows a live countdown if the slot is the current session, or a scheduled
// card if it's later.

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
function show(name) { Object.entries(states).forEach(([k, el]) => el && el.classList.toggle('hidden', k !== name)); }

const qrToken = new URLSearchParams(location.search).get('t');
const isWalkin = !!qrToken;

let currentSession = null;  // {session_date, session} from the server
let statusTimer = null;
let addingMore = false;

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function ordinal(n) { const s = ['th','st','nd','rd'], v = n % 100; return n + (s[(v-20)%10] || s[v] || s[0]); }

// ---- storage ----
function loadSaved() {
  try { const d = JSON.parse(localStorage.getItem(STORAGE_KEY)); if (d && Array.isArray(d.patients) && d.patients.length) return d; } catch {}
  return null;
}
function save(patients, phone) {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify({ patients, phone: phone || '', ts: Date.now() })); } catch {}
}

async function ensureSession() {
  if (currentSession) return;
  try { const { data } = await sb.rpc('app_current_session'); currentSession = Array.isArray(data) ? data[0] : data; } catch {}
}
function isCurrentBooking(b) { return currentSession && b.session_date === currentSession.session_date && b.session === currentSession.session; }
// A booking is "past" once its session has finished (earlier day, or this
// morning when it is already evening). Past bookings are dropped so an old
// ticket from a previous day never lingers or mixes with a new one.
function isPastBooking(b) {
  // Legacy/corrupt entries (older app version with no stored date) -> drop.
  if (!b || !b.session_date || isNaN(new Date(b.session_date + 'T00:00:00').getTime())) return true;
  if (!currentSession) return false;
  if (b.session_date < currentSession.session_date) return true;
  if (b.session_date === currentSession.session_date && currentSession.session === 'pm' && b.session === 'am') return true;
  return false;
}
function pruneSaved() {
  const saved = loadSaved();
  if (!saved) return null;
  const fresh = saved.patients.filter(p => !isPastBooking(p));
  if (fresh.length !== saved.patients.length) {
    if (fresh.length) save(fresh, saved.phone);
    else { try { localStorage.removeItem(STORAGE_KEY); } catch {} }
  }
  return fresh.length ? { patients: fresh, phone: saved.phone } : null;
}

function sessionLabel(dateStr, sess) {
  const sName = sess === 'am' ? 'Morning' : 'Evening';
  const base = currentSession ? currentSession.session_date : dateStr;
  const diff = Math.round((new Date(dateStr + 'T00:00:00') - new Date(base + 'T00:00:00')) / 86400000);
  let day;
  if (diff <= 0) day = 'Today';
  else if (diff === 1) day = 'Tomorrow';
  else day = new Date(dateStr + 'T00:00:00').toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short' });
  return `${day} · ${sName}`;
}
function fullDate(dateStr) {
  return new Date(dateStr + 'T00:00:00').toLocaleDateString('en-IN', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
}

// ---- geolocation (best effort) ----
function getLocation() {
  return new Promise((res) => {
    if (!navigator.geolocation) return res(null);
    let done = false;
    const finish = (v) => { if (!done) { done = true; res(v); } };
    const t = setTimeout(() => finish(null), 9000);
    navigator.geolocation.getCurrentPosition(
      (p) => { clearTimeout(t); finish({ lat: p.coords.latitude, lng: p.coords.longitude }); },
      () => { clearTimeout(t); finish(null); },
      { enableHighAccuracy: false, timeout: 8000, maximumAge: 300000 }
    );
  });
}

// ---- rendering ----
function renderTicket(patients) {
  const numEl = $('ticket-num'), numsEl = $('ticket-nums'), labelEl = $('ticket-label'), subEl = $('ticket-sub');
  if (patients.length === 1) {
    numEl.textContent = '#' + patients[0].token;
    numEl.classList.remove('hidden'); numsEl.classList.add('hidden'); numsEl.innerHTML = '';
    labelEl.textContent = 'Your number';
    subEl.textContent = patients[0].name;
  } else {
    numEl.classList.add('hidden'); numsEl.classList.remove('hidden');
    numsEl.innerHTML = patients.map(p => `<span class="num-pill">#${p.token}</span>`).join('');
    labelEl.textContent = `Your ${patients.length} numbers`;
    subEl.textContent = patients.map(p => `#${p.token} ${p.name}`).join('  ·  ');
  }

  // "When" banner — one line per booking with its session label
  $('ticket-when').innerHTML = patients.map(p =>
    `<span class="tw-row">🗓 <b>${sessionLabel(p.session_date, p.session)}</b>${patients.length > 1 ? ` · #${p.token}` : ''}<span class="tw-date">${fullDate(p.session_date)}</span><span class="tw-turn" data-token="${p.token}"></span></span>`
  ).join('');

  // Friendly routing message (from the latest booking)
  const last = patients[patients.length - 1];
  $('ticket-headline').textContent = last.headline || '';
  $('ticket-msg').textContent = last.message || '';
  $('ticket-msg').classList.toggle('hidden', !last.message);

  $('ticket-badge').textContent = (patients[0].source === 'home' ? 'Home booking' : 'Walk-in');

  const anyCurrent = patients.some(isCurrentBooking);
  $('ticket-status').classList.toggle('hidden', !anyCurrent);
  document.querySelector('.ticket-info')?.classList.add('hidden');
  $('add-another-btn').classList.toggle('hidden', patients.length >= MAX_PER_FAMILY);

  show('ticket');
  clearInterval(statusTimer);
  if (anyCurrent) { refreshStatus(); statusTimer = setInterval(refreshStatus, STATUS_POLL_MS); }
}

async function refreshStatus() {
  const saved = pruneSaved(); if (!saved) return;
  const current = saved.patients.filter(isCurrentBooking).sort((a, b) => a.token - b.token);
  if (!current.length) return;
  try {
    const results = [];
    for (const p of current) {
      const { data, error } = await sb.rpc('queue_status', { p_token: p.token });
      if (!error && data) results.push({ token: p.token, s: data });
    }
    if (!results.length) return;
    const first = results[0].s;
    // session-level cells (same for everyone)
    $('ts-attended').textContent = first.attended ?? 0;
    $('ts-serving').textContent = first.now_serving != null ? '#' + first.now_serving : '—';
    // per-patient turn time next to each number
    results.forEach(({ token, s }) => {
      const span = document.querySelector(`.tw-turn[data-token="${token}"]`);
      if (span) span.textContent = shortTurn(s);
    });
    // headline eta cell → the earliest of this device's patients
    paintEta(first);
  } catch (e) { console.warn('status poll failed', e); }
}

function turnTime(s) {
  return s.turn_at ? new Date(s.turn_at)
    : new Date(new Date(s.server_now || Date.now()).getTime() + (s.eta_seconds || 0) * 1000);
}
function sessionStarted(s) { return !s.session_open || new Date(s.session_open) <= new Date(s.server_now || Date.now()); }
function hhmm(d) { return d.toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit' }); }

// compact per-number badge shown in the "when" rows
function shortTurn(s) {
  const st = s.your_status;
  if (st === 'done') return '✅ seen';
  if (st === 'attending') return '🔔 now serving you';   // being served → no time estimate
  if (st === 'cancelled' || st === 'noshow') return 'check reception';
  if ((s.ahead ?? 0) === 0 && sessionStarted(s)) return "⏳ you're next";
  return '⏳ ~' + hhmm(turnTime(s));
}

function paintEta(s) {
  const lbl = $('ts-eta-label'), el = $('ts-eta'), st = s.your_status;
  el.classList.remove('serving-you');
  if (st === 'done') { lbl.textContent = '✅ Status'; el.textContent = 'Seen — thank you!'; }
  else if (st === 'attending') { lbl.textContent = '🔔 Your turn'; el.textContent = 'Now serving you!'; el.classList.add('serving-you'); }  // no time while being served
  else if (st === 'cancelled' || st === 'noshow') { lbl.textContent = 'ℹ️ Status'; el.textContent = 'Please check at reception'; }
  else if ((s.ahead ?? 0) === 0 && sessionStarted(s)) { lbl.textContent = '⏳ Your turn (approx.)'; el.textContent = "You're next!"; }
  else if ((s.ahead ?? 0) === 0) { lbl.textContent = '⏳ Your turn (approx.)'; el.textContent = hhmm(turnTime(s)); }
  else { lbl.textContent = `⏳ ${s.ahead} ahead · turn approx.`; el.textContent = hhmm(turnTime(s)); }
}

// ---- networking ----
function friendlyError(err) {
  const m = (err && (err.message || err.code) || '').toString();
  if (m.includes('NO_SLOT'))       return '__NOSLOT__';
  if (m.includes('INVALID_SCAN'))  return 'That QR code has expired. Please re-scan the code at the clinic.';
  if (m.includes('NAME_REQUIRED')) return 'Please enter the patient name.';
  if (m.includes('PHONE_INVALID')) return 'Please enter a 10-digit mobile number.';
  return null;
}

async function bookOne(name, phone, loc, age, residence) {
  const { data, error } = await sb.rpc('book_appointment', {
    p_name: name, p_phone: phone,
    p_source: isWalkin ? 'walkin' : 'home',
    p_qr_token: qrToken,
    p_lat: loc ? loc.lat : null,
    p_lng: loc ? loc.lng : null,
    p_age_years: age.y, p_age_months: age.m, p_age_days: age.d,
    p_residence: residence || null,
  });
  if (error) throw error;
  return data;
}

function showForm({ adding = false } = {}) {
  addingMore = adding;
  const saved = loadSaved();
  $('form-eyebrow').textContent = isWalkin ? '✦ Walk-in queue' : '✦ Book appointment';
  $('form-title').innerHTML = adding
    ? 'Add another <span class="grad">patient</span> 🧒'
    : (isWalkin ? 'Get your <span class="grad">queue number</span> 🎟️' : 'Book your <span class="grad">appointment</span> 🎟️');
  $('form-note').innerHTML = isWalkin
    ? "You're at the clinic — you'll be added to the current session's queue."
    : "📍 We'll ask for your location to give you a slot you can reach in time. Your name &amp; number are shared only with the clinic.";
  $('form-error').classList.add('hidden');
  $('f-name').value = '';
  ['f-age-y', 'f-age-m', 'f-age-d'].forEach(id => { if ($(id)) $(id).value = ''; });
  $('f-residence').value = '';
  if (adding && saved && saved.phone) $('f-phone').value = saved.phone;
  // hide the "today/hours" meta — routing decides the slot now
  const meta = document.querySelector('#state-form .appt-meta'); if (meta) meta.classList.add('hidden');
  show('form');
  $('f-name').focus();
}

async function submitForm() {
  const name = $('f-name').value.trim();
  const phone = $('f-phone').value.trim();
  const num = (id) => { const s = ($(id).value || '').trim(); return s === '' ? null : (isNaN(+s) ? null : Math.max(0, parseInt(s, 10))); };
  const ageY = num('f-age-y'), ageM = num('f-age-m'), ageD = num('f-age-d');
  const residence = $('f-residence').value.trim();
  const errEl = $('form-error'); errEl.classList.add('hidden');
  if (!name) { errEl.textContent = 'Please enter the patient name.'; errEl.classList.remove('hidden'); return; }
  if (phone.replace(/\D/g, '').length !== 10) { errEl.textContent = 'Please enter a 10-digit mobile number.'; errEl.classList.remove('hidden'); return; }
  if ((ageY || 0) + (ageM || 0) + (ageD || 0) <= 0) { errEl.textContent = 'Please enter the patient age (years, months, or days).'; errEl.classList.remove('hidden'); return; }
  if (!residence) { errEl.textContent = 'Please enter the residence (village / town).'; errEl.classList.remove('hidden'); return; }

  $('book-btn').disabled = true;
  show('loading');
  $('loading-text').textContent = isWalkin ? 'Reserving your spot…' : '📍 Checking your location & finding a slot…';
  try {
    const loc = isWalkin ? null : await getLocation();
    const res = await bookOne(name, phone, loc, { y: ageY, m: ageM, d: ageD }, residence);
    const saved = pruneSaved();
    const patients = (addingMore && saved ? saved.patients : []).concat([
      { token: res.token_number, name, source: res.source, session_date: res.session_date, session: res.session, headline: res.headline, message: res.message },
    ]);
    save(patients, phone);
    await ensureSession();
    renderTicket(patients);
  } catch (err) {
    console.error('Booking failed:', err);
    const f = friendlyError(err);
    if (f === '__NOSLOT__') showNoSlot();
    else if (f) { showForm({ adding: addingMore }); $('form-error').textContent = f; $('form-error').classList.remove('hidden'); }
    else show('error');
  } finally { $('book-btn').disabled = false; }
}

function showNoSlot() {
  $('gate-emoji') && ($('gate-emoji').textContent = '🌙');
  const gate = $('state-gate');
  gate.querySelector('h1').innerHTML = 'No upcoming <span class="grad">slots</span> right now';
  gate.querySelector('.appt-lead').textContent = 'The clinic has no open sessions available at the moment. Please try again later or call us — we\'ll be glad to help.';
  const meta = gate.querySelector('.appt-meta'); if (meta) meta.classList.add('hidden');
  show('gate');
}

async function init() {
  $('year').textContent = new Date().getFullYear();
  await ensureSession();
  const saved = pruneSaved();
  if (saved) { renderTicket(saved.patients); return; }
  showForm();
}

$('book-btn').addEventListener('click', submitForm);
$('f-phone').addEventListener('input', (e) => { e.target.value = e.target.value.replace(/\D/g, '').slice(0, 10); });
$('f-phone').addEventListener('keydown', (e) => { if (e.key === 'Enter') submitForm(); });
$('add-another-btn').addEventListener('click', () => showForm({ adding: true }));
$('retry-btn').addEventListener('click', () => { const s = pruneSaved(); if (s) renderTicket(s.patients); else init(); });
$('refresh-link') && $('refresh-link').addEventListener('click', (e) => { e.preventDefault(); refreshStatus(); });

document.addEventListener('DOMContentLoaded', init);
