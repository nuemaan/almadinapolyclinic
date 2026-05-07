// Al Madina Polyclinic — appointment queue page

const COUNTER_NS = 'almadina-polyclinic';
const STORAGE_KEY = 'almadina_appt';
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

// Mon–Sat: 9:30–10:30 AM & 4:30–6:30 PM. Sun: 10:00 AM – 1:30 PM
function todayHours() {
  const day = new Date().getDay(); // 0=Sun
  if (day === 0) return '10:00 AM – 1:30 PM';
  return '9:30–10:30 AM & 4:30–6:30 PM';
}

function ordinal(n) {
  const s = ['th','st','nd','rd'], v = n % 100;
  return n + (s[(v - 20) % 10] || s[v] || s[0]);
}

function loadSaved() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const data = JSON.parse(raw);
    if (data && data.date === todayKey() && Number.isInteger(data.number)) return data;
  } catch {}
  return null;
}

function save(number) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ date: todayKey(), number }));
  } catch {}
}

function renderTicket(number) {
  $('ticket-num').textContent = '#' + number;
  $('ticket-sub').textContent = `You're the ${ordinal(number)} patient in today's queue`;
  $('ticket-date').textContent = prettyDate();
  $('ticket-hours').textContent = todayHours();
  show('ticket');
}

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

async function getMyNumber() {
  // Re-validate the token in case it rotated between page-load and tap.
  const token = new URLSearchParams(location.search).get('t');
  if (!await window.QueueToken.isValid(token)) {
    show('gate');
    return;
  }
  show('loading');
  try {
    const data = await fetchJSON(HIT_URL(todayKey()));
    if (typeof data.value !== 'number') throw new Error('Bad response');
    save(data.value);
    renderTicket(data.value);
  } catch (err) {
    console.error('Counter increment failed:', err);
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
      // /get/ returns an error if the key has never been hit; treat as 0
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
    // If they already got a number today, always show it — no gate.
    renderTicket(saved.number);
  } else {
    // Otherwise require a valid scan token from the clinic display.
    const token = new URLSearchParams(location.search).get('t');
    const ok = await window.QueueToken.isValid(token);
    show(ok ? 'intro' : 'gate');
  }

  $('get-number-btn').addEventListener('click', getMyNumber);
  $('retry-btn').addEventListener('click', () => {
    const s = loadSaved();
    if (s) renderTicket(s.number); else getMyNumber();
  });
  $('lost-link').addEventListener('click', (e) => { e.preventDefault(); showLatestCount(); });
  $('back-to-ticket').addEventListener('click', () => {
    const s = loadSaved();
    if (s) renderTicket(s.number); else show('intro');
  });
}

document.addEventListener('DOMContentLoaded', init);
