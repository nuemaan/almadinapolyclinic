# Al Madina Polyclinic & Laboratory

Website for **Al Madina Polyclinic & Laboratory**, a pediatric clinic in Beehama, Ganderbal (Kashmir).

🌐 **Live:** [almadinapolyclinic.com](https://www.almadinapolyclinic.com/)

## About the clinic

- **Address:** 1st Floor, Al-Rahat Chinar Shopping Complex, Beehama, Ganderbal — 191201
- **Phone:** +91 95965 79443
- **Hours:** Mon–Sat · 9:30–10:30 AM & 4:30–6:30 PM · Sun · 10:00 AM – 1:30 PM
- Appointments are taken on-site.

## Stack

Plain HTML, CSS, and a single JS file — no build step, no framework.

```
index.html
styles.css
script.js

display.html       # in-clinic screen — shows the QR code + live counter
display.css
display.js

appointment.html   # what patients land on after scanning the QR
appointment.css
appointment.js
```

## Appointment queue (QR flow)

Two pages working together:

1. **`display.html`** — open this on the clinic's screen / TV / monitor. It shows a big QR code on one side and a live "latest number issued today" counter on the other.
2. **`appointment.html`** — patients land here after scanning the QR. They tap a button and get their queue number — first scan gets `#1`, second `#2`, and so on.

### How to use

- On a tablet, laptop, or TV in the clinic, open the display URL **with the staff key**:

  ```
  https://www.almadinapolyclinic.com/display.html?key=rayis-clinic-screen-2026
  ```

  Bookmark this URL on the clinic device and put the browser in fullscreen (`F11`). Without the `?key=...`, the page shows a "Staff only" message instead of the QR.
- Patients scan the QR code with their phone camera and tap the link — they get a number.
- The display polls the counter every 5 seconds, so the "latest number" stays up to date.

### Why a staff key + rotating QR token

We don't want patients getting a number from home by typing `/appointment.html` directly. Two layers protect against that:

1. **Staff key** on `display.html` — without `?key=...` the QR isn't shown at all.
2. **Rotating QR token** — the QR encodes a token that changes every 10 minutes. The appointment page only issues a number if the URL has a current token. A URL captured at home becomes invalid quickly.

The staff key and token secret live in `queue-token.js` — change them there if you ever want to "rotate the keys" (e.g. if the URL with key gets shared too widely). After changing, give the new URL to the clinic device and refresh.

> Note: this is "security by deterrence" — the JS source is public, so a determined technical user could read it and compute valid tokens. It's enough to stop casual misuse, not a determined attacker. For airtight enforcement you'd need a backend.

### How it works

- **Counter:** uses [abacus.jasoncameron.dev](https://abacus.jasoncameron.dev) — a free public counter API, no setup needed.
- **Session reset:** the counter key includes today's date and an `am`/`pm` suffix (`YYYY-MM-DD-am` before 3 PM, `YYYY-MM-DD-pm` after), so the queue automatically starts at `#1` for the morning session and again at `#1` for the evening session.
- **Per-device limit:** once a phone has a number for the day, refreshing the appointment page shows the same number (stored in `localStorage`) — patients can't accidentally take multiple numbers by refreshing.

### Custom QR target

By default `display.html` builds the QR from its own origin (so the QR points to `https://your-domain/appointment.html`). To override, append `?url=` to the display URL:

```
display.html?url=https://www.almadinapolyclinic.com/appointment.html
```

### Switching to a more robust backend

The free abacus service is fine for low-volume clinic use. If reliability becomes a concern, swap the URLs in `appointment.js` and `display.js` for a Firebase / Supabase / custom endpoint that exposes the same `{ value: N }` shape on increment / read.

## Run locally

Any static server works. Two quick options:

```bash
python3 -m http.server 8000
# or
npx serve .
```

Then open <http://localhost:8000>.
