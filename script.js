// ========== Custom cursor ==========
const dot = document.getElementById('cursor-dot');
const ring = document.getElementById('cursor-ring');
let mx = 0, my = 0, rx = 0, ry = 0;

window.addEventListener('mousemove', (e) => {
  mx = e.clientX; my = e.clientY;
  if (dot) { dot.style.left = mx + 'px'; dot.style.top = my + 'px'; }
});
function loop() {
  rx += (mx - rx) * 0.18;
  ry += (my - ry) * 0.18;
  if (ring) { ring.style.left = rx + 'px'; ring.style.top = ry + 'px'; }
  requestAnimationFrame(loop);
}
loop();

document.querySelectorAll('a, button, .srv, .doc-card, .t-card, .p-cell, .float-card').forEach(el => {
  el.addEventListener('mouseenter', () => ring?.classList.add('hover'));
  el.addEventListener('mouseleave', () => ring?.classList.remove('hover'));
});

// ========== Scroll reveal ==========
const io = new IntersectionObserver((entries) => {
  entries.forEach(e => { if (e.isIntersecting) e.target.classList.add('in'); });
}, { threshold: 0.12 });

document.querySelectorAll('.srv, .doc-card, .t-card, .why, .sec-head, .doc-hero, .poster, .map-card, .hero-left, .hero-right').forEach(el => {
  el.classList.add('reveal');
  io.observe(el);
});

// ========== Parallax on hero scene ==========
const scene = document.querySelector('.scene');
window.addEventListener('mousemove', (e) => {
  if (!scene) return;
  const x = (e.clientX / window.innerWidth - 0.5) * 20;
  const y = (e.clientY / window.innerHeight - 0.5) * 20;
  scene.style.transform = `translate(${x}px, ${y}px)`;
});

// ========== Mobile menu ==========
const toggle = document.querySelector('.menu-toggle');
const links = document.querySelector('.nav-links');
toggle?.addEventListener('click', () => {
  const open = links.style.display === 'flex';
  Object.assign(links.style, open ? { display: '' } : {
    display: 'flex', flexDirection: 'column',
    position: 'absolute', top: '70px', right: '10px',
    background: 'white', padding: '16px', borderRadius: '20px',
    boxShadow: '0 15px 40px rgba(0,0,0,.12)', gap: '4px'
  });
});

// ========== Balloon pop game ==========
const popSounds = ['Zap!', 'Gotcha!', 'Clean!', 'Bye germ!', 'Poof!', 'Healed!'];
let popScore = 0;

const scoreEl = document.createElement('div');
scoreEl.className = 'pop-score';
scoreEl.innerHTML = '🦠 Zapped: <span id="pop-count">0</span>';
document.body.appendChild(scoreEl);

function showScore() {
  scoreEl.classList.add('show');
  clearTimeout(showScore._t);
  showScore._t = setTimeout(() => scoreEl.classList.remove('show'), 2000);
}

function respawnBalloon(el) {
  setTimeout(() => {
    el.classList.remove('popping');
    el.style.animation = 'none';
    void el.offsetWidth;
    el.style.animation = '';
  }, 1500 + Math.random() * 3000);
}

function popBalloon(e) {
  const el = e.currentTarget;
  if (el.classList.contains('popping')) return;

  const rect = el.getBoundingClientRect();
  const cx = rect.left + rect.width / 2;
  const cy = rect.top + rect.height / 2;

  const burst = document.createElement('div');
  burst.className = 'pop-burst';
  burst.textContent = popSounds[Math.floor(Math.random() * popSounds.length)];
  burst.style.left = cx + 'px';
  burst.style.top  = cy + 'px';
  document.body.appendChild(burst);
  setTimeout(() => burst.remove(), 700);

  for (let i = 0; i < 8; i++) {
    const p = document.createElement('div');
    p.className = 'pop-burst';
    p.textContent = ['✨','💫','⚡','🛡️','💊','🧼'][Math.floor(Math.random()*6)];
    p.style.left = cx + 'px';
    p.style.top  = cy + 'px';
    p.style.fontSize = '18px';
    const ang = (i / 8) * Math.PI * 2;
    const dx = Math.cos(ang) * 60;
    const dy = Math.sin(ang) * 60;
    p.animate(
      [ { transform: 'translate(-50%,-50%) scale(.4)', opacity: 1 },
        { transform: `translate(calc(-50% + ${dx}px), calc(-50% + ${dy}px)) scale(1.1)`, opacity: 0 } ],
      { duration: 600, easing: 'cubic-bezier(.2,.8,.3,1)', fill: 'forwards' }
    );
    document.body.appendChild(p);
    setTimeout(() => p.remove(), 650);
  }

  el.classList.add('popping');
  popScore++;
  document.getElementById('pop-count').textContent = popScore;
  showScore();

  respawnBalloon(el);
}

document.querySelectorAll('.balloon').forEach(b => b.addEventListener('click', popBalloon));

// ========== Navbar shadow on scroll ==========
const nav = document.querySelector('.nav');
window.addEventListener('scroll', () => {
  if (window.scrollY > 20) nav?.classList.add('scrolled');
  else nav?.classList.remove('scrolled');
});
