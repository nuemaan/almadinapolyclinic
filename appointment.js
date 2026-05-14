// Al Madina Polyclinic — appointment queue page

const COUNTER_NS = 'almadina-polyclinic';
const STORAGE_KEY = 'almadina_appt';
const MAX_PER_FAMILY = 3;
const HIT_URL = (key) => `https://abacus.jasoncameron.dev/hit/${COUNTER_NS}/${key}`;
const GET_URL = (key) => `https://abacus.jasoncameron.dev/get/${COUNTER_NS}/${key}`;

const $ = (id) => document.getElementById(id);

const states = {
  gate:    $('state-gate'),
  intro:   $('state-intro'),
  loading: $('state-loading'),
  ticket:  $('state-ticket'),
  error:   $('state-error'),
  latest:  $('state-latest'),
};

function show(name) {
  Object.entries(states).forEach(([k, el]) => el.classList.toggle('hidden', k !== name));
}

function todayKey() {
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

function prettyDate() {
  const d = new Date();
  return d.toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
}

function todayHours() {
  const day = new Date().getDay();
  if (day === 0) return '10:00 AM – 1:30 PM';
  return '9:30–10:30 AM & 4:30–6:30 PM';
}

function ordinal(n) {
  const s = ['th','st','nd','rd'], v = n % 100;
  return n + (s[(v - 20) % 10] || s[v] || s[0]);
}

// --- Storage: array of numbers issued today on this device ---
function loadSaved() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const data = JSON.parse(raw);
    if (!data || data.date !== todayKey()) return null;
    // Migrate old single-number format → array
    if (Array.isArray(data.numbers) && data.numbers.length) return data;
    if (Number.isInteger(data.number)) return { date: data.date, numbers: [data.number] };
    return null;
  } catch { return null; }
}

function save(numbers) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ date: todayKey(), numbers }));
  } catch {}
}

// --- Rendering ---
function renderTicket(numbers) {
  const numEl = $('ticket-num');
  const numsEl = $('ticket-nums');
  const labelEl = $('ticket-label');
  const subEl = $('ticket-sub');

  if (numbers.length === 1) {
    numEl.textContent = '#' + numbers[0];
    numEl.classList.remove('hidden');
    numsEl.classList.add('hidden');
    numsEl.innerHTML = '';
    labelEl.textContent = 'Your number';
    subEl.textContent = `You're the ${ordinal(numbers[0])} patient in today's queue`;
    subEl.classList.remove('hidden');
  } else {
    numEl.classList.add('hidden');
    numsEl.classList.remove('hidden');
    numsEl.innerHTML = numbers.map(n => `<span class="num-pill">#${n}</span>`).join('');
    labelEl.textContent = `Your ${numbers.length} numbers`;
    subEl.textContent = '';
    subEl.classList.add('hidden');
  }

  $('ticket-date').textContent = prettyDate();
  $('ticket-hours').textContent = todayHours();

  // Hide "Add another patient" once we've hit the per-device limit.
  $('add-another-btn').classList.toggle('hidden', numbers.length >= MAX_PER_FAMILY);

  show('ticket');
}

// --- Networking ---
async function fetchJSON(url, { timeout = 8000 } = {}) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeout);
  try {
    const res = await fetch(url, { signal: ctrl.signal, cache: 'no-store' });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    return await res.json();
  } finally {
    clearTimeout(t);
  }
}

async function incrementOnce() {
  const data = await fetchJSON(HIT_URL(todayKey()));
  if (typeof data.value !== 'number') throw new Error('Bad response');
  return data.value;
}

// --- Main flows ---
async function getMyNumber() {
  const token = new URLSearchParams(location.search).get('t');
  if (!await window.QueueToken.isValid(token)) {
    show('gate');
    return;
  }
  show('loading');
  try {
    const issued = await incrementOnce();
    save([issued]);
    renderTicket([issued]);
  } catch (err) {
    console.error('Counter increment failed:', err);
    show('error');
  }
}

async function addAnotherPatient() {
  const saved = loadSaved();
  if (!saved) { show('intro'); return; }
  if (saved.numbers.length >= MAX_PER_FAMILY) return;
  show('loading');
  try {
    const next = await incrementOnce();
    const updated = [...saved.numbers, next];
    save(updated);
    renderTicket(updated);
  } catch (err) {
    console.error('Add-another failed:', err);
    show('error');
  }
}

async function showLatestCount() {
  show('loading');
  try {
    let value = 0;
    try {
      const data = await fetchJSON(GET_URL(todayKey()));
      if (typeof data.value === 'number') value = data.value;
    } catch (e) {
      if (!String(e).includes('HTTP')) throw e;
    }
    $('latest-num').textContent = '#' + value;
    show('latest');
  } catch (err) {
    console.error('Latest count failed:', err);
    show('error');
  }
}

async function init() {
  $('today-label').textContent = prettyDate();
  $('gate-hours').textContent = todayHours();
  $('year').textContent = new Date().getFullYear();

  const saved = loadSaved();
  if (saved) {
    renderTicket(saved.numbers);
  } else {
    const token = new URLSearchParams(location.search).get('t');
    const ok = await window.QueueToken.isValid(token);
    show(ok ? 'intro' : 'gate');
  }

  $('get-number-btn').addEventListener('click', getMyNumber);
  $('add-another-btn').addEventListener('click', addAnotherPatient);
  $('retry-btn').addEventListener('click', () => {
    const s = loadSaved();
    if (s) renderTicket(s.numbers); else getMyNumber();
  });
  $('lost-link').addEventListener('click', (e) => { e.preventDefault(); showLatestCount(); });
  $('back-to-ticket').addEventListener('click', () => {
    const s = loadSaved();
    if (s) renderTicket(s.numbers); else show('intro');
  });
}

document.addEventListener('DOMContentLoaded', init);
