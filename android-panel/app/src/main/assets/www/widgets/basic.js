import { $, API, D, LEVEL_COLOR, LOCALE, METRICS, PANEL_HEADERS, PREVIEW, ago, api, buildLayout, buzz, cfg, chime, cfgVersion, chart, color, cssVar, currentProcessesSort, emit, fillIcon, fmtClock, fmtDur, fmtHM, fmtMem, fmtTime, fmtValue, gotoProcesses, gpuMem, gpusOf, h, en, haptic, hasProcessesPage, hist, hour12, icon, keyButton, setKeyFace, labelled, levelOf, metricText, online, openSheet, pad, pushView, r1, registerProcessesSorter, renderStatus, ringSvg, configMark, configReadSince, localWriteStored, shortDur, shortGpu, store, t, tick, toast, wxBlock, wxDeg, wxIcon, emo, rich, tp, tpv } from '../main.js';
import { W } from '../registry.js';
import { invalidateDeckState } from './controls.js';
import { bindDetail } from './homelab.js';

function bindProcessLink(box, sortTarget) {
  if (!hasProcessesPage()) return;
  box.style.cursor = 'pointer';
  box.addEventListener('click', () => {
    if (!hasProcessesPage()) return;
    haptic();
    gotoProcesses(sortTarget);
  });
}

// ================================================================= widgets
// Each widget: { needs: [data kinds], bare?: no card background, create(box, ctx) -> { update(kind) } }
// Data kinds: tick (every second), fast (4×/s), state, weather, quotas, work, procs, push, notes.

W.clock = {
  bare: true, needs: ['tick', 'state', 'weather', 'quotas', 'work'],
  create(box, { o }) {
    const status = o.status !== false ? h('div', 'status') : null;
    const hh = h('span', 'hh', '--'), colon = h('span', 'colon', ':'), mm = h('span', 'mm', '--'), ss = h('span', 'sec'), ap = h('span', 'ap');
    const date = o.date !== false ? h('div', 'date') : null;
    const wx = o.weather !== false ? wxBlock() : null;
    box.append(status || '', h('div', 'clock', hh, colon, mm, ss, ap), date || '', wx || '');
    box.style.setProperty('--tf', (0.84 - (status ? 0.1 : 0) - (date ? 0.11 : 0) - (wx ? 0.2 : 0)).toFixed(2));
    return {
      // without the weather line the clock must not make the panel fetch the weather
      needs: wx ? W.clock.needs : W.clock.needs.filter((k) => k !== 'weather'),
      update(kind) {
        if (kind === 'tick') {
          const now = new Date();
          const H = now.getHours(), h12 = hour12();
          hh.textContent = h12 ? String(H % 12 || 12) : pad(H);
          ap.textContent = h12 ? (H < 12 ? 'AM' : 'PM') : '';
          mm.textContent = pad(now.getMinutes());
          ss.textContent = cfg.display?.showSeconds === false ? '' : pad(now.getSeconds());
          // the colon blinks once a second from here, not from a CSS animation: a running animation makes the browser draw a frame
          // on every display refresh (120 a second on some phones) for something that changes once a second
          colon.classList.toggle('dim', now.getSeconds() % 2 === 1);
          if (date) date.textContent = now.toLocaleDateString(LOCALE, { weekday: 'long', day: 'numeric', month: 'long' });
          if (status && now.getSeconds() % 30 === 0) renderStatus(status, o); // battery
        } else if (kind === 'weather') wx?.update();
        else if (status) renderStatus(status, o);
      },
    };
  },
};

W.weather = {
  needs: ['weather'],
  create(box) {
    const wx = wxBlock();
    box.append(wx);
    return { update: () => wx.update() };
  },
};

W.forecast = {
  needs: ['weather'],
  create(box, { o }) {
    const daily = o.mode === 'daily';
    const row = h('div', 'fc');
    box.append(h('div', 'w-title', en(daily ? '7-day forecast' : 'Next hours'), h('span', 'w-sub', '')), row);
    return {
      update() {
        const w = D.weather;
        if (!w?.hourly || !w?.daily) { row.replaceChildren(h('div', 'empty', D.weather === null ? t('w.loading') : t('w.weatherUnavailable'))); return; }
        box.querySelector('.w-sub').textContent = cfg.weather?.city || '';
        const vertical = box.clientHeight > box.clientWidth * 0.9;
        const room = vertical ? box.clientHeight - 30 : box.clientWidth - 16;
        const n = Math.max(3, Math.min(daily ? 7 : 12, Math.floor(room / (vertical ? 30 : 50))));
        row.classList.toggle('vert', vertical);
        const cells = [];
        if (daily) {
          const d = w.daily;
          for (let i = 0; i < Math.min(n, d.time.length); i++) {
            // some models (Météo-France, CMA) forecast fewer than 7 days and send null for the rest: stop there, not at "0°"
            if (d.temperature_2m_max?.[i] == null) break;
            const day = i === 0 ? t('time.today') : new Date(d.time[i] + 'T12:00').toLocaleDateString(LOCALE, { weekday: 'short' });
            const rain = d.precipitation_probability_max?.[i];
            cells.push(h('div', 'fc-i', h('span', 'fc-t', day), h('span', 'fc-ic', emo(wxIcon(d.weather_code[i]))),
              h('span', 'fc-v', wxDeg(d.temperature_2m_max[i]) + '°', h('small', null, ' ' + wxDeg(d.temperature_2m_min[i]) + '°')),
              h('span', 'fc-r', rain >= 20 ? rich(`💧${rain}%`) : '')));
          }
        } else {
          const hr = w.hourly;
          let start = hr.time.indexOf((w.current?.time || '').slice(0, 13) + ':00');
          if (start < 0) start = 0;
          const step = n >= 10 ? 1 : 2;
          for (let k = 0; k < n; k++) {
            const i = start + k * step;
            if (i >= hr.time.length || hr.temperature_2m?.[i] == null) break;
            const rain = hr.precipitation_probability?.[i];
            cells.push(h('div', 'fc-i', h('span', 'fc-t', k === 0 ? 'Now' : hr.time[i].slice(11, 13)), h('span', 'fc-ic', emo(wxIcon(hr.weather_code[i], hr.is_day?.[i]))),
              h('span', 'fc-v', wxDeg(hr.temperature_2m[i]) + '°'), h('span', 'fc-r', rain >= 20 ? rich(`💧${rain}%`) : '')));
          }
        }
        row.replaceChildren(...cells);
      },
    };
  },
};


W.stat = {
  needs: ['state'],
  create(box, { o }) {
    const m = METRICS[o.metric] || METRICS.cpu;
    const c = color(m.color);
    box.style.setProperty('--c', c);
    const lbl = h('div', 't-label', tp(m.label));
    const val = h('b', null, '—'), unit = h('small'), sub = h('div', 't-sub', ' ');
    box.append(lbl, h('div', 't-val', val, unit), sub);
    if (o.metric === 'cpu' || o.metric === 'ram') bindProcessLink(box, o.metric === 'cpu' ? 'cpu' : 'mem');
    return {
      update() {
        const s = D.state;
        if (!s) return;
        const [v, u] = metricText(m, s);
        val.textContent = v;
        unit.textContent = u;
        const pctVal = m.pct?.(s);
        lbl.textContent = pctVal != null && m.label === 'RAM' ? `RAM (${Math.round(pctVal)}%)` : tp(m.label);
        sub.textContent = m.sub?.(s) || ' ';
      },
    };
  },
};

W.gauge = {
  needs: ['state'],
  create(box, { o }) {
    const m = METRICS[o.metric] || METRICS.cpu;
    box.style.setProperty('--q', color(m.color));
    const dial = h('div', 'g-dial'), pct = h('div', 'g-val'), sub = h('div', 'g-sub');
    box.append(dial, h('div', 'g-label', tp(m.label)), sub);
    dial.append(pct);
    if (o.metric === 'cpu' || o.metric === 'ram') bindProcessLink(box, o.metric === 'cpu' ? 'cpu' : 'mem');
    let svg = null;
    return {
      update() {
        const s = D.state;
        if (!s) return;
        const raw = m.pct ? m.pct(s) : m.val(s);
        const p = raw == null ? 0 : (raw / (m.pct ? 100 : m.max(s))) * 100;
        const warn = m.hot ? (raw > m.hot[1] ? '#ef4444' : raw > m.hot[0] ? '#f59e0b' : '') : (p >= 95 ? '#ef4444' : p >= 85 ? '#f59e0b' : '');
        dial.style.setProperty('--qc', warn || 'var(--q)');
        if (svg) svg.remove();
        dial.insertAdjacentHTML('afterbegin', ringSvg(p));
        svg = dial.firstElementChild;
        const [v, u] = metricText(m, s);
        pct.replaceChildren(v, h('small', null, u));
        sub.textContent = m.sub?.(s) || '';
      },
    };
  },
};

W.chart = {
  needs: ['state'],
  create(box, { o }) {
    // a list of only unknown names falls back like no list at all; own keys only, so "constructor" is unknown too
    const keys = (Array.isArray(o.metrics) && o.metrics.length ? o.metrics : ['cpu']).filter((k) => Object.prototype.hasOwnProperty.call(METRICS, k));
    if (!keys.length) keys.push('cpu');
    const single = keys.length === 1 ? METRICS[keys[0]] : null;
    const isNet = keys.every((k) => k === 'down' || k === 'up');
    const label = single ? tp(single.name) : isNet ? tp('Network') : keys.map((k) => tp(METRICS[k].name)).join(' · ');
    box.style.setProperty('--c', color((single || METRICS[keys[0]]).color));
    const head = h('div', 's-head', h('span', 's-label', label), h('span', 's-name', ''));
    const main = h('div', 's-main');
    const canvas = h('canvas');
    box.append(head, main, canvas);
    // tapping a graph opens the large one (history is kept for cpu, ram, cputemp, net)
    bindDetail(box, isNet ? 'net' : keys[0]);
    return {
      update() {
        const s = D.state;
        if (!s) return;
        if (single) {
          const [v, u] = metricText(single, s);
          main.replaceChildren(h('b', null, v), h('small', null, u), h('span', 'chips', single.sub?.(s) ? h('span', 'chip', single.sub(s)) : ''));
          head.lastChild.textContent = single.title?.(s) || '';
        } else {
          main.replaceChildren(...keys.map((k) => {
            const mm = METRICS[k];
            const [v, u] = metricText(mm, s);
            const e = h('span', 'multi', (k === 'down' ? '↓ ' : k === 'up' ? '↑ ' : tp(mm.label) + ' '), h('b', null, v + ' ' + u));
            e.style.color = color(mm.color);
            return e;
          }));
          head.lastChild.textContent = isNet && s.ping ? tpv('Ping {ms} · loss {loss}%', { ms: s.ping.ms != null ? Math.round(s.ping.ms) + ' ms' : '—', loss: s.ping.lossPct }) : '';
        }
        chart(canvas, keys.map((k) => ({ data: hist[METRICS[k].hist || k], color: color(METRICS[k].color), max: METRICS[k].max(s) })), { grid: true });
      },
    };
  },
};

W.meters = {
  needs: ['state'],
  create(box) {
    box.style.setProperty('--c', cssVar('--ram'));
    const up = h('span', 's-name');
    const list = h('div', 'meters');
    box.append(h('div', 's-head', h('span', 's-label', t('w.memory')), up), list);
    bindDetail(box, 'ram');
    const meter = (name, txt, pct, c) => {
      const e = h('div', 'meter', h('div', 'm-row', h('span', null, name), h('span', null, txt)), h('div', 'track', h('i')));
      e.querySelector('i').style.width = Math.min(100, pct) + '%';
      if (c) e.style.setProperty('--c', c);
      return e;
    };
    return {
      update() {
        const pc = D.state?.pc;
        if (!pc) return;
        const s = pc.uptimeSec, d = Math.floor(s / 86400), hr = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
        up.textContent = tp('Up ') + (d ? `${d} d ${hr} h` : hr ? `${hr} h ${m} min` : `${m} min`);
        const rows = [meter('RAM', `${r1(pc.ramUsedGb)} / ${Math.round(pc.ramTotalGb)} GB`, (pc.ramUsedGb / pc.ramTotalGb) * 100)];
        // one row per GPU (the integrated one counts its shared memory); named once there is more than one
        const gpus = gpusOf(D.state);
        for (const g of gpus) {
          const m = gpuMem(g);
          if (m) rows.push(meter(gpus.length > 1 ? `${m.label === 'VRAM' ? 'VRAM' : 'GPU'} · ${shortGpu(g.name)}` : m.label === 'VRAM' ? 'VRAM' : tp('GPU MEMORY'),
            `${r1(m.used)} / ${Math.round(m.total)} GB`, (m.used / m.total) * 100, cssVar('--gpu')));
        }
        const disks = h('div', 'disks', ...(pc.disks || []).map((dk) => meter(dk.name === '/' ? tp('DISK') : dk.name, Math.round((dk.usedGb / dk.totalGb) * 100) + '%', (dk.usedGb / dk.totalGb) * 100, '#94a3b8')));
        list.replaceChildren(...rows, disks);
      },
    };
  },
};





W.processes = {
  needs: ['procs', 'state'],
  create(box, { o }) {
    const canKill = o.allowKill !== false;
    let sort = currentProcessesSort();
    const sum = h('span', 'p-sum');
    const seg = h('div', 'seg', h('button', sort === 'cpu' ? 'on' : null, 'CPU'), h('button', sort === 'mem' ? 'on' : null, 'RAM'));
    const grid = h('div', 'p-grid', h('div', 'empty', t('w.procsWait')));
    box.style.setProperty('--c', '#f472b6');
    box.append(h('div', 'p-head', h('span', 's-label', t('w.processes')), sum, seg), grid);
    const els = new Map();
    const rowEl = (g) => {
      let e = els.get(g.name);
      if (e) return e;
      e = h('div', 'proc');
      e.innerHTML = '<div class="p-ico"></div><div class="p-info"><div class="p-title"><span class="p-t"></span><span class="p-count"></span><span class="p-lock"></span></div>' +
        '<div class="p-bar"><i></i></div></div><div class="p-nums"><b></b><small></small></div>';
      fillIcon(e.querySelector('.p-ico'), g);
      e.addEventListener('click', () => { haptic(); openSheet(e._g, canKill); });
      els.set(g.name, e);
      return e;
    };
    const render = () => {
      const data = D.procs;
      if (!data) return;
      if (!data.groups.length) { sum.textContent = ''; grid.replaceChildren(h('div', 'empty', t('w.measuring'))); return; }
      const cols = box.clientWidth > 460 ? 2 : 1;
      const rows = Math.max(1, Math.floor((box.clientHeight - 46) / 40));
      grid.style.gridTemplateColumns = `repeat(${cols}, minmax(0, 1fr))`;
      grid.style.gridTemplateRows = `repeat(${rows}, 1fr)`;
      const list = [...data.groups].sort((a, b) => (sort === 'cpu' ? b.cpu - a.cpu || b.memMb - a.memMb : b.memMb - a.memMb)).slice(0, cols * rows);
      const max = Math.max(0.1, ...list.map((g) => (sort === 'cpu' ? g.cpu : g.memMb)));
      const pc = D.state?.pc;
      const cpuPct = pc && pc.cpu != null ? Math.round(pc.cpu) : null;
      const ramPct = pc && pc.ramTotalGb ? Math.round((pc.ramUsedGb / pc.ramTotalGb) * 100) : null;
      const ramStr = ramPct != null && pc.ramUsedGb != null && pc.ramTotalGb != null
        ? `Total RAM ${ramPct}% (${Math.round(pc.ramUsedGb)}/${Math.round(pc.ramTotalGb)} GB) · `
        : (ramPct != null ? `Total RAM ${ramPct}% · ` : '');
      const loadPart = sort === 'cpu'
        ? (cpuPct != null ? `Total CPU ${cpuPct}% · ` : '')
        : ramStr;
      sum.textContent = box.clientWidth > 380 ? loadPart + t('w.procsSummary', { n: data.total, apps: data.groupCount ?? data.groups.length }) : loadPart + t('w.procsSummaryShort', { n: data.total });
      if (grid.querySelector('.empty')) grid.replaceChildren();
      const keep = new Set(list.map((g) => g.name));
      for (const [n, e] of els) if (!keep.has(n)) { e.remove(); els.delete(n); }
      for (const g of list) {
        const e = rowEl(g);
        e._g = g;
        e.querySelector('.p-t').textContent = g.title;
        e.querySelector('.p-count').textContent = g.count > 1 ? '×' + g.count : '';
        e.querySelector('.p-lock').replaceChildren(...(g.locked ? [emo('🔒')] : []));
        e.querySelector('.p-bar i').style.width = ((sort === 'cpu' ? g.cpu : g.memMb) / max) * 100 + '%';
        e.querySelector('.p-nums b').textContent = sort === 'cpu' ? g.cpu.toFixed(1) + '%' : fmtMem(g.memMb);
        e.querySelector('.p-nums small').textContent = sort === 'cpu' ? fmtMem(g.memMb) : g.cpu.toFixed(1) + '%';
        grid.appendChild(e); // keeps the order
      }
    };
    const setSort = (s) => {
      sort = s === 'mem' ? 'mem' : 'cpu';
      [...seg.children].forEach((x, i) => x.classList.toggle('on', (i === 0 ? 'cpu' : 'mem') === sort));
      render();
    };
    registerProcessesSorter(setSort);
    [...seg.children].forEach((b, i) => b.addEventListener('click', () => {
      haptic();
      setSort(i === 0 ? 'cpu' : 'mem');
    }));
    return { update: render };
  },
};

// On / off keys light up from the agent's state (D.state.toggles: { id: true | false }).
export function applyToggles(root) {
  const t = D.state?.toggles || {};
  root.querySelectorAll('.key.toggle').forEach((b) => b.classList.toggle('on', t[b.dataset.id] === true));
  applyCycles(root);
}

// A key that cycles through other keys shows the one that ran last (D.state.cycles: { id: the id of that key }); before the
// first tap, and after the agent restarted, it shows its own icon and name. The agent sends the id, not a position, so
// the face never depends on which version of the list the phone has loaded.
function applyCycles(root) {
  const at = D.state?.cycles || {}, all = cfg.shortcuts || [];
  root.querySelectorAll('.key.cycle').forEach((b) => {
    const id = b.dataset.id, own = all.find((x) => x.id === id);
    if (!own) return;
    const want = at[id] != null ? all.find((x) => x.id === at[id]) : (b.dataset.face ? own : null);
    // a key the phone has not loaded yet leaves the face as it is: not the key's own, which did not run
    if (!want || (b.dataset.face || '') === (want.id === id ? '' : want.id)) return;
    setKeyFace(b, want, b._cover === true);
  });
}

W.shortcuts = {
  needs: ['state'],
  create(box, { o }) {
    const all = cfg.shortcuts || [];
    const ids = Array.isArray(o.ids) && o.ids.length ? o.ids : null;
    const list = ids ? ids.map((id) => all.find((s) => s.id === id)).filter(Boolean) : all;
    if (!list.length) {
      box.append(h('div', 'empty', all.length ? t('w.shortcutsMissing') : t('w.shortcutsWait')));
      return {};
    }
    const cols = Math.min(8, Math.max(1, o.columns || 4));
    const grid = h('div', 'deck-grid', ...list.map(keyButton));
    grid.style.gridTemplateColumns = `repeat(${Math.min(cols, list.length)}, 1fr)`;
    grid.style.gridTemplateRows = `repeat(${Math.ceil(list.length / cols)}, 1fr)`;
    box.append(grid);
    return { update: () => applyToggles(box) };
  },
};

W.button = {
  bare: true, needs: ['state'],
  create(box, { o }) {
    const s = (cfg.shortcuts || []).find((x) => x.id === o.id) || (cfg.shortcuts || [])[0];
    box.append(s ? keyButton(s, { cover: o.cover === true, label: o.showLabel !== false }) : h('div', 'empty', t('w.pickShortcut')));
    return { update: () => applyToggles(box) };
  },
};

W.worldclock = {
  needs: ['tick'],
  create(box, { o }) {
    const zones = (Array.isArray(o.zones) && o.zones.length ? o.zones : ['Tallinn=Europe/Tallinn', 'Istanbul=Europe/Istanbul', 'London=Europe/London', 'New York=America/New_York', 'Tokyo=Asia/Tokyo'])
      .map((z) => { const i = z.indexOf('='); return i > 0 ? [z.slice(0, i).trim(), z.slice(i + 1).trim()] : [z.split('/').pop().replace(/_/g, ' '), z.trim()]; });
    const items = zones.map(([name, tz]) => {
      let fmt = null;
      try { fmt = new Intl.DateTimeFormat('en-GB', { timeZone: tz, year: 'numeric', month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }); } catch (_) {}
      const t = h('div', 'wc-t', fmt ? '--:--' : '??'), s = h('div', 'wc-s', fmt ? '' : 'unknown zone');
      return { fmt, t, s, el: h('div', 'wc', h('div', 'wc-n', name), t, s) };
    });
    const row = h('div', 'wc-row', items.map((i) => i.el));
    box.append(row);
    let shown = -1;
    return {
      update() {
        // once a minute, and at once after ticks were missed (the page was not visible, the night screen was on)
        const minute = Math.floor(Date.now() / 60000);
        if (minute === shown) return;
        shown = minute;
        const now = new Date();
        const localUtc = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate(), now.getHours(), now.getMinutes());
        row.classList.toggle('vert', box.clientHeight > box.clientWidth * 1.1);
        row.classList.toggle('h12', hour12());
        for (const it of items) {
          if (!it.fmt) continue;
          const p = Object.fromEntries(it.fmt.formatToParts(now).map((x) => [x.type, x.value]));
          const [hm, ap] = fmtClock(+p.hour % 24, +p.minute).split(' ');
          it.t.replaceChildren(hm, ap ? h('span', 'wc-ap', ' ' + ap) : '');
          const zoneUtc = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute);
          const diffH = Math.round((zoneUtc - localUtc) / 360000) / 10;
          const dayDiff = Math.round((Date.UTC(+p.year, +p.month - 1, +p.day) - Date.UTC(now.getFullYear(), now.getMonth(), now.getDate())) / 86400000);
          const day = dayDiff > 0 ? t('time.tomorrow') : dayDiff < 0 ? t('time.yesterday') : t('time.today');
          it.s.textContent = diffH === 0 ? day : `${day}, ${diffH > 0 ? '+' : '−'}${Math.abs(diffH)}h`;
        }
      },
    };
  },
};


export function isoWeek(d) {
  const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
  t.setUTCDate(t.getUTCDate() + 4 - (t.getUTCDay() || 7));
  return Math.ceil(((t - Date.UTC(t.getUTCFullYear(), 0, 1)) / 86400000 + 1) / 7);
}

/**
 * A Pomodoro sequence from text such as "25 focus, 5 break, 25 focus, 15 long" ("focus 25", "25 min long break" and
 * "f / b / l" work too). Returns { steps, bad }: steps is null when the text is empty or not understood.
 */
export function parsePomodoro(text) {
  const kindOf = (k) => (/^l/i.test(k) ? 'long' : /^(b|s)/i.test(k) ? 'break' : 'focus');
  const KIND = '(focus|work|f|short\\s*break|break|b|long\\s*break|long|l)';
  const re = new RegExp(`^(?:${KIND}\\s*(\\d{1,3})\\s*(?:m|min|minutes?)?|(\\d{1,3})\\s*(?:m|min|minutes?)?\\s*${KIND})$`, 'i');
  const steps = [];
  for (const raw of String(text || '').split(/[,;\n]+/)) {
    const part = raw.trim();
    if (!part) continue;
    const m = part.match(re);
    const min = m ? +(m[2] || m[3]) : 0;
    if (!m || min < 1 || min > 600) return { steps: null, bad: part };
    steps.push({ kind: kindOf(m[1] || m[4]), ms: min * 60_000 });
    if (steps.length > 48) return { steps: null, bad: 'more than 48 steps' };
  }
  return { steps: steps.length ? steps : null, bad: null };
}

W.pomodoro = {
  needs: ['tick'],
  always: true, // the alarm goes off on whatever page is showing
  create(box, { o, page, w }) {
    const key = `pomo:${page.id}/${w.id}`;
    const minutes = (v, d, max) => Math.min(max, Math.max(1, +v || d)) * 60_000;
    const focus = { kind: 'focus', ms: minutes(o.focus, 25, 180) }, brk = { kind: 'break', ms: minutes(o.break, 5, 60) };
    const long = { kind: 'long', ms: minutes(o.longBreak, 15, 120) };
    const every = Math.min(12, Math.max(0, Math.floor(+o.longEvery || 0)));
    const rounds = Math.min(99, Math.max(0, Math.floor(+o.rounds || 0)));
    const custom = parsePomodoro(o.sequence);
    // the plan: the own sequence, or focus / break with a long break after every N focus sessions
    let plan = custom.steps;
    if (!plan) {
      plan = [];
      if (!every) plan.push(focus, brk);
      else for (let i = 0; i < every; i++) plan.push(focus, i === every - 1 ? long : brk);
    }
    const sig = plan.map((s) => `${s.kind[0]}${s.ms / 60_000}`).join(' ') + `/${rounds}`;
    const focusTotal = plan.filter((s) => s.kind === 'focus').length;
    const today = new Date().toDateString();
    let st = store.get(key, null);
    if (!st || typeof st !== 'object') st = { phase: 'focus', endsAt: null, left: plan[0].ms, count: 0, day: today };
    if (st.sig === undefined) {
      // state from before sequences (focus / break only): keep a running timer where it is
      st.step = st.phase === 'break' && plan.length > 1 ? 1 : 0;
      st.round = 0;
      st.sig = sig;
    } else if (st.sig !== sig) {
      // the sequence was changed in the settings: start it from the beginning
      Object.assign(st, { step: 0, round: 0, endsAt: null, left: plan[0].ms, sig });
    }
    if (!(st.step >= 0 && st.step < plan.length)) st.step = 0;
    if (st.day !== today) { st.count = 0; st.day = today; }
    const save = () => { st.phase = plan[st.step].kind; store.set(key, st); };
    save();
    const dial = h('div', 'g-dial'), time = h('div', 'g-val'), phase = h('div', 'g-label'), count = h('div', 'g-sub');
    const play = labelled(h('button', 'pb main', icon('play')), t('w.a.start')), reset = labelled(h('button', 'pb', icon('rotate-ccw')), t('w.a.restart')), skip = labelled(h('button', 'pb', icon('skip-forward')), t('w.a.skip'));
    dial.append(time);
    box.append(dial, phase, count, h('div', 'pomo-btns', reset, play, skip));
    let svg = null;
    const total = () => plan[st.step].ms;
    const remaining = () => (st.endsAt ? Math.max(0, st.endsAt - Date.now()) : st.left);
    /** Moves to the next step; returns true when the last round of the sequence is over (the timer then stops). */
    const advance = (manual) => {
      if (plan[st.step].kind === 'focus' && !manual) st.count++;
      st.step++;
      if (st.step >= plan.length) { st.step = 0; st.round = (st.round || 0) + 1; }
      st.left = total();
      const finished = rounds > 0 && st.round >= rounds;
      if (finished) st.round = 0;
      st.endsAt = manual || finished ? null : Date.now() + st.left;
      save();
      return finished;
    };
    const label = () => {
      const s = plan[st.step];
      if (s.kind === 'long') return t('w.longBreak');
      if (s.kind === 'break') return t('w.break');
      const n = plan.slice(0, st.step + 1).filter((x) => x.kind === 'focus').length;
      return focusTotal > 1 ? `${t('w.focus')} ${n}/${focusTotal}` : t('w.focus');
    };
    const render = () => {
      // "today" starts over at midnight also while the panel stays open
      const day = new Date().toDateString();
      if (st.day !== day) { st.count = 0; st.day = day; save(); }
      if (st.endsAt && remaining() <= 0) {
        const was = plan[st.step].kind;
        const finished = advance(false);
        buzz(finished ? '0,200,120,200,120,200,120,600' : '0,200,120,200,120,400');
        if (o.sound === true) chime(o.soundVolume, finished);
        const next = plan[st.step].kind;
        toast(finished ? 'Sequence finished, well done'
          : next === 'long' ? 'Time for a long break' : next === 'break' ? 'Time for a break'
            : was === 'focus' ? tp('Next focus session') : tp('Back to focus'), 'ok', '🍅 Pomodoro', 5);
      }
      const left = remaining();
      const kind = plan[st.step].kind;
      box.classList.toggle('brk', kind !== 'focus');
      box.classList.toggle('long', kind === 'long');
      box.classList.toggle('run', !!st.endsAt);
      if (svg) svg.remove();
      dial.insertAdjacentHTML('afterbegin', ringSvg(100 * (1 - left / total())));
      svg = dial.firstElementChild;
      time.textContent = fmtTime(left + 999);
      phase.textContent = label();
      const tomatoes = st.count ? '🍅'.repeat(Math.min(st.count, 6)) + (st.count > 6 ? ` ×${st.count}` : '') : t('w.noSessionsToday');
      count.replaceChildren(rich(custom.bad ? `Sequence not understood: "${custom.bad}"`
        : rounds > 1 ? `Round ${(st.round || 0) + 1}/${rounds} · ${tomatoes}` : tomatoes));
      // the tomato icons are decorative (aria-hidden), so say the count in words for screen readers
      if (st.count && !custom.bad) count.append(h('span', 'sr-only', ' ' + t('w.a.sessionsToday', { n: st.count })));
      play.replaceChildren(icon(st.endsAt ? 'pause' : 'play'));
      labelled(play, t(st.endsAt ? 'w.a.pause' : 'w.a.start'));
    };
    play.addEventListener('click', () => {
      haptic();
      if (st.endsAt && remaining() <= 0) {
        render();
        if (!st.endsAt) return;
      }
      if (st.endsAt) { st.left = remaining(); st.endsAt = null; } else st.endsAt = Date.now() + st.left;
      save(); render();
    });
    // ↺ restarts this step; pressed again on a step that has not started, it goes back to the start of the sequence
    reset.addEventListener('click', () => {
      haptic();
      if (!st.endsAt && st.left === total()) { st.step = 0; st.round = 0; }
      st.endsAt = null; st.left = total(); save(); render();
    });
    skip.addEventListener('click', () => { haptic(); advance(true); render(); });
    return { update: render };
  },
};

W.countdown = {
  needs: ['tick'],
  create(box, { o }) {
    const m = String(o.target || '').trim().match(/^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$/);
    let target = NaN;
    if (m) {
      const [, year, month, day, hour = '0', minute = '0', second = '0'] = m;
      const date = new Date(0);
      date.setFullYear(+year, +month - 1, +day);
      date.setHours(+hour, +minute, +second, 0);
      if (date.getFullYear() === +year && date.getMonth() === +month - 1 &&
          date.getDate() === +day && +hour < 24 && +minute < 60 && +second < 60) {
        // the time is checked as numbers: one the clocks skip (spring forward) still counts, moved on like before
        target = date.getTime();
      }
    }
    const big = h('div', 'cd-v'), sub = h('div', 'cd-s');
    box.append(h('div', 'cd-l', o.label || tp('Countdown')), big, sub);
    if (Number.isNaN(target)) { big.textContent = '—'; sub.textContent = t('w.setDateFormat'); return {}; }
    sub.textContent = new Date(target).toLocaleDateString(LOCALE, { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }) + ', ' + fmtHM(new Date(target));
    return {
      update() {
        let d = target - Date.now();
        const past = d < 0;
        d = Math.abs(d);
        const days = Math.floor(d / 86400000), hrs = Math.floor((d % 86400000) / 3600000), mins = Math.floor((d % 3600000) / 60000), secs = Math.floor((d % 60000) / 1000);
        big.textContent = (past ? '+' : '') + (days ? `${days}d ${hrs}h` : hrs ? `${hrs}h ${pad(mins)}m` : `${mins}:${pad(secs)}`);
        box.classList.toggle('past', past);
      },
    };
  },
};

const NOTE_MAX = 500;

W.note = {
  bare: true, needs: [],
  create(box, { o, page, w }) {
    const paint = () => {
      const text = String(o.text ?? '');
      box.style.setProperty('--n', o.color || '#fbbf24');
      box.style.setProperty('--nf', text.length < 25 ? 15 : text.length < 70 ? 10.5 : text.length < 160 ? 8 : 6.5);
      box.replaceChildren(h('div', 'note-t', text));
    };
    paint();
    if (PREVIEW || String(w.id).includes(':')) return {};
    box.addEventListener('click', () => {
      if (!$('overview').hidden) return;
      haptic();
      const wrap = h('div', 'note-edit');
      wrap.onclick = (e) => { if (e.target === wrap) wrap.remove(); };
      const card = h('div', 'note-card');
      const ta = document.createElement('textarea');
      ta.className = 'note-ta';
      ta.value = String(o.text ?? '');
      let opened = cfgVersion;
      let unsure = null; // the text of a save that timed out: the agent may have stored it anyway
      ta.maxLength = NOTE_MAX;
      ta.rows = 6;
      const row = h('div', 'note-actions');
      const cancel = h('button', 'btn sm', t('w.note.cancel'));
      cancel.onclick = () => wrap.remove();
      const save = h('button', 'btn primary sm', t('w.note.save'));
      save.onclick = async () => {
        const submitted = ta.value;
        save.disabled = true;
        ta.disabled = true;
        try {
          const path = '/widget/' + encodeURIComponent(page.id) + '/' + encodeURIComponent(w.id)
            + '/note?text=' + encodeURIComponent(submitted) + '&version=' + encodeURIComponent(opened ?? '');
          const mark = configMark();
          const result = await api(path, 'POST', 8000);
          o.text = submitted;
          // a config read that started after this save already holds it (or something newer): leave it alone.
          // Otherwise the config the panel holds gets the text first, then the version, so an identical refresh keeps
          // it and a rebuild doesn't bring the old text back; reads that started before the save can't apply over it
          if (!configReadSince(mark)) {
            const saved = (cfg.pages || []).find((p) => p.id === page.id)?.widgets?.find((x) => x.id === w.id);
            if (saved) { saved.options = { ...(saved.options || {}), text: submitted }; store.set('cfg', cfg); }
            localWriteStored(result?.version);
          }
          paint();
          // a refresh while the editor was open rebuilt the page under it: draw the new widget from the updated config
          if (!box.isConnected) buildLayout();
          wrap.remove();
        } catch (error) {
          if (error?.status === 409) {
            // a save that timed out may have been stored: then this conflict is our own, so save again on top of it
            if (unsure != null) {
              const earlier = unsure;
              unsure = null;
              // read the agent's config without applying it: a rebuild now would replace this widget under the editor
              const current = await api('/config').catch(() => null);
              if (!wrap.isConnected) return; // the editor was closed meanwhile: nothing to save
              const now = (current?.config?.pages || []).find((p) => p.id === page.id)?.widgets?.find((x) => x.id === w.id)?.options?.text;
              if (now === earlier && current?.version != null) {
                opened = current.version;
                return save.onclick();
              }
            }
            wrap.remove();
            toast(t('w.note.changed'));
            return;
          }
          // no HTTP answer (a timeout or a dropped connection): the agent may still have stored it
          if (error?.status == null) unsure = submitted;
          save.disabled = false;
          ta.disabled = false;
          toast(t('w.note.failed'));
        }
      };
      row.append(cancel, save);
      card.append(ta, row);
      wrap.append(card);
      document.body.append(wrap);
      ta.focus();
    });
    return {};
  },
};

W.label = {
  bare: true, needs: [],
  create(box, { o }) {
    box.append(h('div', 'lbl-t', o.text || ''));
    return {};
  },
};

W.command = {
  needs: ['tick'],
  create(box, { o, page, w }) {
    const out = h('div', 'cmd-o', '…'), foot = h('div', 'cmd-f', '');
    box.append(h('div', 'w-title', o.title || en('Command')), out, foot);
    let last = 0, busy = false, res = null;
    const load = async (force) => {
      if (busy) return;
      busy = true;
      try {
        res = await api(`/widget/${encodeURIComponent(page.id)}/${encodeURIComponent(w.id)}${force ? '?force=true' : ''}`, 'GET', 4000);
        const text = res.output ?? '';
        out.textContent = text || (res.running ? t('w.running') : t('w.noOutput'));
        const short = text.length <= 14 && !text.includes('\n');
        out.classList.toggle('big', short);
        box.classList.toggle('bad', res.ok === false);
      } catch (_) { if (!res) out.textContent = online ? t('w.unavailable') : '—'; }
      busy = false;
    };
    box.addEventListener('click', () => { haptic(); last = Date.now(); load(true).then(() => setTimeout(() => load(false), 1500)); });
    return {
      update() {
        if (res?.at) foot.textContent = (res.running ? 'refreshing · ' : '') + ago(res.at) + (res.durationMs ? ` · ${Math.round(res.durationMs)} ms` : '');
        if (!online || Date.now() - last < (res?.running || !res?.at ? 2000 : 5000)) return;
        last = Date.now();
        load(false);
      },
    };
  },
};

W.push = {
  needs: ['push', 'tick'],
  create(box, { o }) {
    const key = o.key || '';
    let lastAt = -1;
    const render = () => {
      const item = D.push[key];
      if (!item) {
        if (lastAt === 0) return;
        lastAt = 0;
        box.style.removeProperty('--c');
        box.replaceChildren(h('div', 'w-title', o.title || key), h('div', 'push-empty', t('w.noDataYet'), h('code', null, `POST /api/push/${key}`)));
        return;
      }
      const ageEl = box.querySelector('.push-age');
      if (item.at === lastAt) { if (ageEl) ageEl.textContent = ago(item.at); return; }
      lastAt = item.at;
      const v = pushView(item);
      const lvl = levelOf(v);
      const c = v.color || LEVEL_COLOR[lvl] || '';
      if (c) box.style.setProperty('--c', c); else box.style.removeProperty('--c');
      const unit = v.unit ?? o.unit ?? '';
      const style = o.style && o.style !== 'auto' ? o.style : v.items ? 'list' : 'big';
      const title = h('div', 'w-title', v.icon ? rich(v.icon + ' ') : '', o.title || v.title || key, h('span', 'push-age w-sub', ago(item.at)));
      let body;
      if (style === 'list') {
        const items = v.items || (v.value != null ? [v.value] : []);
        body = h('div', 'push-list', items.slice(0, 30).map((x) => {
          if (x && typeof x === 'object') {
            const li = h('div', 'pl-i', h('span', 'pl-l', x.label ?? x.title ?? x.name ?? ''), h('span', 'pl-v', fmtValue(x.value ?? x.status ?? '')));
            const lc = LEVEL_COLOR[x.level || levelOf({ value: x.value ?? x.status })];
            if (lc) li.style.setProperty('--lc', lc);
            return li;
          }
          return h('div', 'pl-i', h('span', 'pl-l', fmtValue(x)));
        }));
      } else if (style === 'gauge') {
        const min = v.min ?? (typeof o.min === 'number' ? o.min : 0), max = v.max ?? (typeof o.max === 'number' ? o.max : 100);
        const num = typeof v.value === 'number' ? v.value : parseFloat(v.value);
        const pct = v.progress != null ? v.progress * 100 : Number.isFinite(num) ? ((num - min) / (max - min || 1)) * 100 : 0;
        const dial = h('div', 'g-dial');
        dial.innerHTML = ringSvg(pct);
        dial.appendChild(h('div', 'g-val', fmtValue(v.value ?? Math.round(pct)), h('small', null, unit)));
        box.style.setProperty('--q', c || 'var(--cpu)');
        body = h('div', 'push-gauge', dial, v.sub ? h('div', 'g-sub', v.sub) : null);
      } else {
        body = h('div', 'push-big', h('div', 'pv', fmtValue(v.value), unit ? h('small', null, unit) : null),
          v.sub ? h('div', 'ps', String(v.sub)) : null,
          v.progress != null ? h('div', 'track', h('i')) : null);
        const bar = body.querySelector('.track i');
        if (bar) bar.style.width = Math.max(0, Math.min(100, v.progress * 100)) + '%';
      }
      box.className = box.className.replace(/\bps-\w+/g, '') + ' ps-' + style;
      box.replaceChildren(title, body);
    };
    return { update: render };
  },
};

W.inbox = {
  needs: ['notes', 'tick'],
  create(box) {
    const list = h('div', 'inbox');
    const clear = h('button', 'mini-btn', tp('Clear'));
    clear.addEventListener('click', () => { haptic(); D.notes = []; store.set('notes', []); emit('notes'); });
    box.append(h('div', 'w-title', en('Notifications'), clear), list);
    let shown = '';
    return {
      update(kind) {
        const key = D.notes.length + ':' + (D.notes[0]?.at || 0) + ':' + Math.floor(Date.now() / 60000);
        if (key === shown && kind === 'tick') return;
        shown = key;
        list.replaceChildren(...(D.notes.length ? D.notes.map((n) => {
          const e = h('div', 'ib-i', h('div', 'ib-h', h('b', null, n.title || n.text), h('span', null, ago(n.at))), n.title && n.text ? h('div', 'ib-t', n.text) : null);
          e.style.setProperty('--lc', LEVEL_COLOR[n.level] || 'var(--dim)');
          return e;
        }) : [h('div', 'empty', t('w.notifyEmpty'))]));
      },
    };
  },
};
