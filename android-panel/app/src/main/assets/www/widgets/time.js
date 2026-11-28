import { $, LOCALE, buzz, fmtTime, h, en, haptic, icon, labelled, pad, r1, rich, store, t, tick, toast, tp } from '../main.js';
import { W } from '../registry.js';
import { dialEl, lines } from './helpers.js';
const tr = (...args) => t(...args); // some widgets below name a local `t` (a timer element), which hides the translator


W.progress = {
  needs: ['tick'],
  create(box) {
    const rows = ['Day', 'Week', 'Month', 'Year'].map((n) => {
      const pct = h('span'), bar = h('i');
      const row = h('div', 'pr-row', h('div', 'm-row', h('span', null, n), pct), h('div', 'track', bar));
      return { pct, bar, row };
    });
    box.append(h('div', 'w-title', en('Time')), h('div', 'pr-list', rows.map((r) => r.row)));
    let shown;
    return {
      update() {
        const now = new Date();
        const minute = Math.floor(now.getTime() / 60_000);
        if (minute === shown) return;
        shown = minute;
        const day0 = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        const day1 = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
        const wk0 = new Date(day0); wk0.setDate(day0.getDate() - ((day0.getDay() + 6) % 7));
        const wk1 = new Date(wk0); wk1.setDate(wk0.getDate() + 7);
        const m0 = new Date(now.getFullYear(), now.getMonth(), 1), m1 = new Date(now.getFullYear(), now.getMonth() + 1, 1);
        const y0 = new Date(now.getFullYear(), 0, 1), y1 = new Date(now.getFullYear() + 1, 0, 1);
        const vals = [(now - day0) / (day1 - day0), (now - wk0) / (wk1 - wk0), (now - m0) / (m1 - m0), (now - y0) / (y1 - y0)];
        vals.forEach((v, i) => { rows[i].pct.textContent = (v * 100).toFixed(i === 3 ? 1 : 0) + '%'; rows[i].bar.style.width = v * 100 + '%'; });
      },
    };
  },
};

W.stopwatch = {
  needs: ['fast'],
  create(box, { page, w }) {
    const key = `sw:${page.id}/${w.id}`;
    let st = store.get(key, null) || { start: null, acc: 0, laps: [] };
    const save = () => store.set(key, st);
    const t = h('div', 'sw-t'), laps = h('div', 'sw-laps');
    const a = labelled(h('button', 'pb main', icon('play')), tr('w.a.start')), b = labelled(h('button', 'pb', icon('rotate-ccw')), tr('w.a.restart'));
    box.append(h('div', 'w-title', en('Stopwatch')), t, h('div', 'pomo-btns', b, a), laps);
    const elapsed = () => st.acc + (st.start ? Date.now() - st.start : 0);
    const fmtSw = (ms) => { const s = Math.floor(ms / 1000); const hh = Math.floor(s / 3600); return (hh ? hh + ':' + pad(Math.floor((s % 3600) / 60)) : Math.floor(s / 60)) + ':' + pad(s % 60) + '.' + Math.floor((ms % 1000) / 100); };
    const renderLaps = () => laps.replaceChildren(...st.laps.slice(-6).reverse().map((l, i, arr) => h('div', 'sw-lap', h('span', null, '#' + (st.laps.length - i)), h('span', null, fmtSw(l)))));
    const paint = () => { a.replaceChildren(icon(st.start ? 'pause' : 'play')); b.replaceChildren(icon(st.start ? 'flag' : 'rotate-ccw')); labelled(a, tr(st.start ? 'w.a.pause' : 'w.a.start')); labelled(b, tr(st.start ? 'w.a.lap' : 'w.a.restart')); box.classList.toggle('run', !!st.start); };
    a.addEventListener('click', () => { haptic(); if (st.start) { st.acc = elapsed(); st.start = null; } else st.start = Date.now(); save(); paint(); });
    b.addEventListener('click', () => { haptic(); if (st.start) st.laps.push(elapsed()); else st = { start: null, acc: 0, laps: [] }; save(); paint(); renderLaps(); });
    paint(); renderLaps();
    return { update() { t.textContent = fmtSw(elapsed()); } };
  },
};

W.timer = {
  needs: ['tick'],
  always: true, // the alarm goes off on whatever page is showing
  create(box, { o, page, w }) {
    const key = `tm:${page.id}/${w.id}`;
    const presets = lines(o.presets, ['1', '3', '5', '10', '15', '25']).map(Number)
      .filter((n) => n > 0 && Number.isFinite(n * 60_000)).slice(0, 8);
    let st = store.get(key, null) || { endsAt: null, left: 0, total: 0 };
    const save = () => store.set(key, st);
    const dial = dialEl(), btns = h('div', 'tm-btns');
    box.append(h('div', 'w-title', o.label || en('Timer')), dial, btns);
    box.style.setProperty('--q', o.color || '#38bdf8');
    const remaining = () => (st.endsAt ? Math.max(0, st.endsAt - Date.now()) : st.left);
    const renderBtns = () => {
      if (!st.total) {
        btns.replaceChildren(...presets.map((m) => { const b = h('button', 'chip-btn', m + 'm'); b.addEventListener('click', () => { haptic(); st = { endsAt: Date.now() + m * 60000, left: m * 60000, total: m * 60000 }; save(); renderBtns(); render(); }); return b; }));
      } else {
        const p = labelled(h('button', 'pb main', icon(st.endsAt ? 'pause' : 'play')), tr(st.endsAt ? 'w.a.pause' : 'w.a.start')), x = labelled(h('button', 'pb', icon('x')), tr('w.a.clear'));
        p.addEventListener('click', () => {
          haptic();
          if (st.endsAt) {
            const left = remaining();
            if (left <= 0) { render(); return; }
            st.left = left;
            st.endsAt = null;
          } else st.endsAt = Date.now() + st.left;
          save();
          renderBtns();
        });
        x.addEventListener('click', () => { haptic(); st = { endsAt: null, left: 0, total: 0 }; save(); renderBtns(); render(); });
        btns.replaceChildren(x, p);
      }
    };
    const render = () => {
      if (st.endsAt && remaining() <= 0) {
        st = { endsAt: null, left: 0, total: 0 }; save(); renderBtns();
        buzz('0,300,150,300,150,600');
        toast(tp('Time is up'), 'ok', '⏳ ' + (o.label || tp('Timer')), 6);
      }
      const left = remaining();
      dial.set(st.total ? 100 * (left / st.total) : 0, st.total ? fmtTime(left + 999) : '—');
      box.classList.toggle('run', !!st.endsAt);
    };
    renderBtns();
    return { update: render };
  },
};



W.checklist = {
  needs: ['tick'],
  create(box, { o, page, w }) {
    const items = lines(o.items, ['Water the plants', 'Stretch', 'Inbox zero']);
    const key = `cl:${page.id}/${w.id}`;
    const day = () => new Date().toDateString();
    let st = store.get(key, null) || { day: day(), done: [] };
    const fresh = () => { if (o.daily !== false && st.day !== day()) st = { day: day(), done: [] }; };
    const head = h('span', 'w-sub');
    const list = h('div', 'cl-list');
    box.append(h('div', 'w-title', o.title || t('time.today'), head), list);
    const render = () => {
      fresh();
      const n = items.filter((x) => st.done.includes(x)).length;
      head.textContent = `${n} / ${items.length}`;
      box.classList.toggle('all', n === items.length && n > 0);
      list.replaceChildren(...items.map((it) => {
        const done = st.done.includes(it);
        const row = h('button', 'cl-i' + (done ? ' done' : ''), h('span', 'cl-box', done ? icon('check') : ''), h('span', 'cl-t', it));
        row.addEventListener('click', () => {
          haptic();
          fresh();
          st.done = st.done.includes(it) ? st.done.filter((x) => x !== it) : [...st.done, it];
          st.day = day();
          store.set(key, st);
          render();
        });
        return row;
      }));
    };
    let lastDay = day();
    render();
    return { update() { if (day() !== lastDay) { lastDay = day(); render(); } } };
  },
};

// The time in words, to the nearest five minutes ("quarter past ten").
const NUM_WORDS = ['twelve', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven'];
export function timeInWords(d) {
  const total = d.getHours() * 60 + d.getMinutes();
  const r = Math.round(total / 5) * 5;
  const exact = r === total, over = total > r;
  const m = r % 60, hr = Math.floor(r / 60) % 24;
  const hourName = (x) => NUM_WORDS[x % 12];
  const minutes = { 5: 'five', 10: 'ten', 15: 'quarter', 20: 'twenty', 25: 'twenty-five', 30: 'half' };
  let main;
  if (m === 0) main = hr === 0 ? ['midnight'] : hr === 12 ? ['noon'] : [hourName(hr), "o'clock"];
  else if (m <= 30) main = [minutes[m], 'past', hourName(hr)];
  else main = [minutes[60 - m], 'to', hourName(hr + 1)];
  return { lead: exact ? "it's" : over ? "it's just after" : "it's almost", main };
}

