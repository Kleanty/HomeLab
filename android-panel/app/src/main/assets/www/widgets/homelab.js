// HomeLab eklemeleri: dokununca büyük grafik penceresi, büyük uyarı penceresi ve panel ayarları (telefonda saklanır).
import { W } from '../registry.js';
import { D, METRICS, buzz, chime, cssVar, color, fmtRate, h, toast } from '../main.js';

// ---------------------------------------------------------------- ayarlar
const KEY = 'hl-settings';
const DEFAULTS = { vibrate: true, sound: false, popup: true };
export const hlSettings = () => {
  try { return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(KEY) || '{}') }; } catch (_) { return { ...DEFAULTS }; }
};
const saveSettings = (s) => { try { localStorage.setItem(KEY, JSON.stringify(s)); } catch (_) {} };

// ---------------------------------------------------------------- uzun geçmiş (yalnızca bellekte, 5 sn aralık, 1 saat)
const LONG = {};
let lastSample = 0;
export function hlRecord(s) {
  const now = Date.now();
  if (now - lastSample < 5000) return;
  lastSample = now;
  for (const k of ['cpu', 'ram', 'cputemp', 'net', 'ping']) {
    const v = METRICS[k]?.val(s);
    if (v == null) continue;
    const a = LONG[k] || (LONG[k] = []);
    a.push([now, +v]);
    if (a.length > 720) a.shift();
  }
}

const closeBtn = (fn) => {
  const b = h('button', 'hl-x', '×');
  b.type = 'button';
  b.setAttribute('aria-label', 'Kapat');
  b.addEventListener('click', fn);
  return b;
};

// ---------------------------------------------------------------- grafik penceresi
function fmt(m, v) {
  if (v == null || !Number.isFinite(v)) return '—';
  if (m.rate) return fmtRate(v).join(' ');
  return (m.fmt ? m.fmt(v) : String(Math.round(v))) + (typeof m.unit === 'string' && m.unit ? ' ' + m.unit : '');
}

function drawBig(canvas, data, max, col, m, hoverT) {
  const dpr = window.devicePixelRatio || 1, w = canvas.clientWidth * dpr, hh = canvas.clientHeight * dpr;
  if (!w || !hh) return;
  canvas.width = w; canvas.height = hh;
  const g = canvas.getContext('2d'), top = 6 * dpr;
  const yOf = (v) => hh - (Math.min(v, max) / max) * (hh - top);
  g.font = `${11 * dpr}px system-ui, sans-serif`;
  for (const f of [0.25, 0.5, 0.75, 1]) { // eksen çizgileri; üst, orta ve alt çizgiye değer yazılır
    const y = Math.round(hh - f * (hh - top)) + 0.5;
    g.strokeStyle = 'rgba(255,255,255,0.07)'; g.lineWidth = 1;
    g.beginPath(); g.moveTo(0, y); g.lineTo(w, y); g.stroke();
    if (f === 0.5 || f === 1) { g.fillStyle = '#8a94a3'; g.fillText(fmt(m, f * max), 6 * dpr, f === 1 ? y + 13 * dpr : y - 4 * dpr); }
  }
  g.fillStyle = '#8a94a3'; g.fillText(fmt(m, 0), 6 * dpr, hh - 4 * dpr);
  if (data.length < 2) return;
  const t0 = data[0][0], span = Math.max(1, data[data.length - 1][0] - t0);
  const px = (t) => ((t - t0) / span) * w;
  g.beginPath(); g.moveTo(px(data[0][0]), yOf(data[0][1]));
  for (const [t, v] of data) g.lineTo(px(t), yOf(v));
  g.lineWidth = 2 * dpr; g.lineJoin = 'round'; g.strokeStyle = col; g.stroke();
  g.lineTo(w, hh); g.lineTo(0, hh); g.closePath();
  const grad = g.createLinearGradient(0, 0, 0, hh);
  grad.addColorStop(0, col + '55'); grad.addColorStop(1, col + '00');
  g.fillStyle = grad; g.fill();
  if (hoverT != null) { // dokunulan noktanın değeri ve saati
    let best = data[0];
    for (const p of data) if (Math.abs(p[0] - hoverT) < Math.abs(best[0] - hoverT)) best = p;
    const x = px(best[0]), y = yOf(best[1]);
    g.strokeStyle = 'rgba(255,255,255,0.35)'; g.lineWidth = 1; g.beginPath(); g.moveTo(x, 0); g.lineTo(x, hh); g.stroke();
    g.fillStyle = col; g.beginPath(); g.arc(x, y, 4 * dpr, 0, 7); g.fill();
    const label = new Date(best[0]).toLocaleTimeString('tr-TR') + '  ' + fmt(m, best[1]);
    g.font = `600 ${13 * dpr}px system-ui, sans-serif`;
    const tw = g.measureText(label).width + 16 * dpr, bx = Math.min(Math.max(x - tw / 2, 4 * dpr), w - tw - 4 * dpr);
    g.fillStyle = 'rgba(13,16,20,0.92)'; g.fillRect(bx, 4 * dpr, tw, 22 * dpr);
    g.fillStyle = '#fff'; g.fillText(label, bx + 8 * dpr, 20 * dpr);
  }
}

let detailEl = null, detailTimer = 0;
export function closeDetail() {
  clearInterval(detailTimer);
  if (detailEl) detailEl.remove();
  detailEl = null;
}

export function openDetail(key) {
  const m = METRICS[key];
  if (!m || detailEl) return;
  const col = color(m.color) || '#2dd4bf';
  const canvas = h('canvas', 'hl-canvas');
  let hoverT = null;
  const now = h('b', 'hl-now'), sub = h('div', 'hl-sub'), ax = h('div', 'hl-axis'), stats = h('div', 'hl-stats');
  const card = h('div', 'hl-card', h('div', 'hl-head', h('span', null, m.label || key), closeBtn(closeDetail)), now, sub, canvas, ax, stats);
  detailEl = h('div', 'hl-modal', card);
  detailEl.addEventListener('click', (e) => { if (e.target === detailEl) closeDetail(); });
  document.body.appendChild(detailEl);
  const render = () => {
    const s = D.state, a = LONG[key] || [], vals = a.map((p) => p[1]);
    now.textContent = s ? fmt(m, m.val(s)) : '—';
    now.style.color = col;
    sub.textContent = (s && m.sub?.(s)) || '';
    if (!(LONG[key] || []).length) sub.textContent += ' · grafik birkaç saniye içinde dolar';
    const max = Math.max(m.max ? m.max(s || {}) : 100, ...vals) || 1;
    drawBig(canvas, a, max, col, m, hoverT);
    const mins = a.length > 1 ? Math.max(1, Math.round((a[a.length - 1][0] - a[0][0]) / 60000)) : 0;
    ax.replaceChildren(h('span', null, mins ? `${mins} dk önce` : 'veri toplanıyor…'), h('span', null, 'şimdi'));
    const avg = vals.length ? vals.reduce((x, y) => x + y, 0) / vals.length : null;
    const item = (l, v) => h('div', 'hl-stat', h('small', null, l), h('b', null, fmt(m, v)));
    stats.replaceChildren(item('Ortalama', avg), item('En yüksek', vals.length ? Math.max(...vals) : null), item('En düşük', vals.length ? Math.min(...vals) : null));
  };
  const touch = (e) => {
    const a = LONG[key] || [];
    if (a.length < 2) return;
    const r = canvas.getBoundingClientRect();
    hoverT = a[0][0] + Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)) * (a[a.length - 1][0] - a[0][0]);
    render();
  };
  canvas.addEventListener('pointerdown', touch);
  canvas.addEventListener('pointermove', (e) => { if (e.buttons || e.pointerType === 'touch') touch(e); });
  render();
  detailTimer = setInterval(render, 2000);
}

export function bindDetail(box, key) {
  box.style.cursor = 'pointer';
  box.addEventListener('click', () => openDetail(key));
}

// ---------------------------------------------------------------- büyük uyarı penceresi
let alertEl = null, alertList = null;
export function showAlert(d, level) {
  const clock = new Date().toLocaleTimeString('tr-TR', { hour: '2-digit', minute: '2-digit' });
  const entry = h('div', 'hl-al-i', h('b', null, d.title || 'Uyarı'), h('span', null, d.text || ''), h('small', null, clock));
  if (alertEl) { alertList.prepend(entry); alertEl.className = 'hl-modal hl-alert ' + (level === 'err' ? 'err' : 'warn'); return; }
  alertList = h('div', 'hl-al-list', entry);
  const close = () => { alertEl.remove(); alertEl = null; alertList = null; };
  alertEl = h('div', 'hl-modal hl-alert ' + (level === 'err' ? 'err' : 'warn'),
    h('div', 'hl-card', h('div', 'hl-head', h('span', null, '⚠ Uyarı'), closeBtn(close)), alertList));
  alertEl.addEventListener('click', (e) => { if (e.target === alertEl) close(); });
  document.body.appendChild(alertEl);
}

/** handleNotify'dan çağrılır: HomeLab uyarısıysa ayarlara göre pencere/titreşim/ses; true = iş burada bitti. */
export function hlNotify(d, level) {
  if (!(level === 'warn' || level === 'err') || !/HomeLab/i.test(d.title || '')) return false;
  const st = hlSettings();
  if (st.popup) showAlert(d, level); else toast(d.text || '', level, d.title || '', d.seconds || 5);
  if (st.vibrate && d.vibrate !== false) buzz(level === 'err' ? '0,90,90,90,90,160' : '0,70,110,70');
  if (st.sound) chime(70, level === 'err');
  return true;
}

// ---------------------------------------------------------------- ayarlar sayfası (widget)
// Ajan yalnızca kendi bildiği widget türlerini saklar; bu yüzden ayarlar sayfası, kullanılmayan 'breathe' (nefes) türünün yerine geçer.
W.breathe = {
  needs: [],
  create(box) {
    const st = hlSettings();
    const row = (key, label, hint) => {
      const sw = h('button', 'hl-sw');
      sw.type = 'button';
      const paint = () => { sw.setAttribute('aria-pressed', st[key] ? 'true' : 'false'); sw.setAttribute('role', 'switch'); };
      paint();
      sw.addEventListener('click', () => { st[key] = !st[key]; saveSettings(st); paint(); });
      return h('div', 'hl-row', h('div', null, h('b', null, label), h('small', null, hint)), sw);
    };
    const test = h('button', 'hl-test', 'Test uyarısı gönder');
    test.type = 'button';
    test.addEventListener('click', () => hlNotify({ title: 'HomeLab: test', text: 'Bu bir deneme uyarısıdır.' }, 'warn'));
    box.append(h('div', 'w-title', 'Uyarı ayarları'),
      row('popup', 'Büyük uyarı penceresi', 'Sorun çıkınca ekranda açılır, çarpıyla kapanır'),
      row('vibrate', 'Titreşim', 'Uyarıda telefon titrer'),
      row('sound', 'Ses', 'Uyarıda kısa bir uyarı sesi çalar'),
      test);
    return { update() {} };
  },
};
