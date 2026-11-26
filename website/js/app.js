// Andén on the web (andenapp.com): home (search, location, popular stations) and /estacion/{id}
// boards. Same board as the app's home screen (app/lib/ui/home_screen.dart), minus following,
// widgets and the destination filter. Port of the platform repo's site/js/app.js.
import { fetchJson, ApiError, validBoard, validStations } from './api.js';
import { parseRoute, extraBelongs } from './route.js';
import { nearestStations, searchStations, formatDistance } from './stations.js';
import { waitText, delayMinutes, isLate, platformText, hhmm, shortStopName, liveText } from './text.js';

const APP_STORE = 'https://apps.apple.com/es/app/id6835200430';
const REFRESH_MS = 30_000;
const CLOCK_MS = 15_000;
const STALE_MS = 2 * 60_000; // older boards show "Actualizado hh:mm"
const EXPIRE_MS = 10 * 60_000; // too old to show trains
const RATE_LIMIT_MS = 5 * 60_000;
const POPULAR = [
  ['18000', 'Madrid-Atocha Cercanías', 'Madrid'], ['17000', 'Madrid-Chamartín-Clara Campoamor', 'Madrid'],
  ['18101', 'Sol', 'Madrid'], ['71801', 'Barcelona-Sants', 'Rodalies de Catalunya'],
  ['78805', 'Barcelona Plaça de Catalunya', 'Rodalies de Catalunya'], ['65000', 'València-Estació del Nord', 'Valencia'],
  ['51003', 'Sevilla-Santa Justa', 'Sevilla'], ['13200', 'Bilbao-Intermod. Abando Indalecio Prieto', 'Bilbao'],
  ['54517', 'Málaga-Centro Alameda', 'Málaga'], ['60911', 'Alicante/Alacant-Terminal', 'Murcia/Alicante'],
  ['11511', 'San Sebastián-Donostia', 'San Sebastián'], ['04040', 'Zaragoza Delicias', 'Zaragoza'],
];
const HOME_TITLE = 'Andén — ¿de qué andén sale mi tren?';
const HOME_DESC = 'Próximos trenes de Cercanías y Rodalies con su andén, retrasos y cancelaciones en tiempo real, cada 30 segundos. Gratis y sin registro.';

const root = document.getElementById('app');

// ---- state ------------------------------------------------------------------------------------
let stationsPromise = null;
let stations = null; // [{id, name, lat, lon, nucleo}] once loaded
let located = null; // {id, meters} from «Cerca de ti», this page session only
let gen = 0; // bumped on every navigation: answers from an older one are dropped
let abort = new AbortController();
let refreshTimer = null;
let clockTimer = null;
let s = null; // station page state
let searchActive = null; // id highlighted in the suggestions, kept across re-renders

function loadStations() {
  stationsPromise ??= fetchJson('/stations.json')
    .then((j) => { if (!validStations(j)) throw new ApiError('unavailable'); return (stations = j); })
    .catch(() => { stationsPromise = null; return null; });
  return stationsPromise;
}

const stationOf = (id) => stations?.find((x) => x.id === id) ?? null;
const nameOf = (id) => stationOf(id)?.name ?? POPULAR.find(([i]) => i === id)?.[1] ?? null;

// ---- DOM helper -------------------------------------------------------------------------------
function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs ?? {})) {
    if (v == null || v === false) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else el.setAttribute(k, v === true ? '' : String(v));
  }
  for (const kid of kids.flat(Infinity)) if (kid != null && kid !== false) el.append(kid);
  return el;
}

/** Replaces the page content. Focus survives: the element with the same data-key or the search
 * box, with its text and caret, gets it back (the clock re-renders the station page). */
function put(...kids) {
  const el = document.activeElement;
  const key = el?.dataset?.key;
  const typing = el?.matches?.('.search input') ? { value: el.value, pos: el.selectionStart } : null;
  root.replaceChildren(...kids.flat(Infinity).filter((k) => k != null && k !== false));
  if (typing) {
    const input = root.querySelector('.search input');
    if (!input) return;
    input.value = typing.value;
    input.focus({ preventScroll: true });
    input.setSelectionRange(typing.pos, typing.pos);
    if (typing.value) input.dispatchEvent(new Event('input'));
  } else if (key) {
    [...root.querySelectorAll('[data-key]')].find((x) => x.dataset.key === key)?.focus({ preventScroll: true });
  }
}

const badge = (small = false) => h('a', { class: small ? 'badge small' : 'badge', href: APP_STORE, rel: 'noopener' },
  h('img', { src: '/app-store-badge.svg', alt: 'Descárgalo en el App Store', width: small ? 102 : 120, height: small ? 34 : 40 }));

const footer = () => h('footer', {}, 'Datos: Renfe · ', h('a', { href: '/estaciones' }, 'Estaciones'), ' · ',
  h('a', { href: '/privacidad' }, 'Privacidad'), ' · ', h('a', { href: '/ayuda' }, 'Ayuda'));

function link(path, label, cls) {
  return h('a', { href: path, class: cls, onclick: (e) => {
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
    e.preventDefault();
    go(path);
  } }, label);
}

// ---- navigation -------------------------------------------------------------------------------
function go(path, replace = false) {
  if (replace) history.replaceState(null, '', path); else history.pushState(null, '', path);
  route();
}

function stopTimers() {
  clearInterval(refreshTimer);
  clearInterval(clockTimer);
  refreshTimer = clockTimer = null;
}

function route() {
  gen++;
  abort.abort();
  abort = new AbortController();
  stopTimers();
  window.scrollTo(0, 0);
  const extra = document.getElementById('extra'); // server-built, for the page first loaded
  if (extra && !extraBelongs(extra.dataset.path, location.pathname)) {
    extra.remove();
    document.querySelector('script[type="application/ld+json"]')?.remove(); // describes that page
  }
  const r = parseRoute(location.pathname);
  if (r.page === 'station') {
    if (location.pathname !== r.canonical) return go(r.canonical, true);
    return openStation(r.id);
  }
  s = null;
  if (r.page === 'home') return renderHome();
  renderNotFound('Página no encontrada');
}

// ---- search box ---------------------------------------------------------------------------------
function searchBox(placeholder) {
  const input = h('input', { type: 'search', placeholder, 'aria-label': placeholder, autocomplete: 'off',
    autocapitalize: 'off', spellcheck: 'false', role: 'combobox', 'aria-expanded': 'false', 'aria-controls': 'suggest' });
  const list = h('ul', { class: 'suggest', id: 'suggest', role: 'listbox', hidden: true });
  let results = [];
  let active = -1;
  const pick = (st) => { searchActive = null; input.blur(); go(`/estacion/${st.id}`); };
  const move = (i) => { active = i; searchActive = results[i]?.id ?? null; draw(); };
  const draw = () => {
    list.replaceChildren(...results.map((st, i) => h('li', {
      role: 'option', 'aria-selected': i === active ? 'true' : 'false',
      onmousedown: (e) => { e.preventDefault(); pick(st); },
    }, h('span', {}, st.name), h('span', { class: 'crs' }, st.nucleo ?? ''))));
    list.hidden = results.length === 0;
    input.setAttribute('aria-expanded', String(!list.hidden));
  };
  input.addEventListener('focus', () => loadStations());
  input.addEventListener('input', async () => {
    const q = input.value;
    const all = stations ?? (await loadStations()) ?? [];
    if (q !== input.value) return; // typed on meanwhile
    results = searchStations(all, q);
    const kept = results.findIndex((x) => x.id === searchActive);
    active = kept >= 0 ? kept : results.length ? 0 : -1;
    draw();
  });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown' && results.length) { move((active + 1) % results.length); e.preventDefault(); }
    else if (e.key === 'ArrowUp' && results.length) { move((active - 1 + results.length) % results.length); e.preventDefault(); }
    else if (e.key === 'Enter' && active >= 0) { e.preventDefault(); pick(results[active]); }
    else if (e.key === 'Escape') { results = []; searchActive = null; draw(); }
  });
  input.addEventListener('blur', () => setTimeout(() => { results = []; draw(); }, 150));
  return h('div', { class: 'search' }, input, list);
}

// ---- home -------------------------------------------------------------------------------------
function setMeta(title, description) {
  document.title = title;
  const set = (sel, v) => document.querySelector(sel)?.setAttribute(sel.startsWith('link') ? 'href' : 'content', v);
  set('meta[name="description"]', description);
  set('meta[property="og:title"]', title);
  set('meta[property="og:description"]', description);
  const url = `https://andenapp.com${location.pathname}`;
  set('link[rel="canonical"]', url);
  set('meta[property="og:url"]', url);
}

function renderHome() {
  setMeta(HOME_TITLE, HOME_DESC);
  const note = h('p', { class: 'note', hidden: true, role: 'status' });
  const locate = h('button', { class: 'btn', type: 'button' }, 'Estaciones cerca de ti');
  locate.addEventListener('click', () => useLocation(locate, note));
  put(
    h('div', { class: 'top' }, h('span', { class: 'logo' }, 'Andén')),
    badge(),
    h('h1', {}, '¿De qué andén sale mi tren?'),
    h('p', { class: 'tag' }, 'Próximos trenes de Cercanías y Rodalies con su andén, retrasos y cancelaciones en tiempo real.'),
    locate, note,
    searchBox('Busca tu estación'),
    h('div', { class: 'label' }, 'Estaciones populares'),
    h('div', { class: 'grid' }, POPULAR.map(([id, name, nucleo]) =>
      link(`/estacion/${id}`, [name, h('span', { class: 'crs' }, nucleo)]))),
    footer(),
  );
}

function useLocation(button, note) {
  const say = (t) => { note.textContent = t; note.hidden = false; };
  const off = 'Ubicación desactivada. Busca tu estación.';
  if (!navigator.geolocation) return say(off);
  button.disabled = true;
  button.textContent = 'Buscando tu estación…';
  const myGen = gen;
  const done = () => { button.disabled = false; button.textContent = 'Estaciones cerca de ti'; };
  navigator.geolocation.getCurrentPosition(async (pos) => {
    const all = stations ?? (await loadStations());
    if (myGen !== gen) return;
    done();
    if (!all?.length) return say('No se pudo cargar la lista de estaciones. Inténtalo de nuevo.');
    const [{ station, meters }] = nearestStations(all, pos.coords.latitude, pos.coords.longitude, 1);
    located = { id: station.id, meters };
    go(`/estacion/${station.id}`);
  }, () => {
    if (myGen !== gen) return;
    done();
    say(off);
  }, { timeout: 10_000, maximumAge: 60_000 });
}

function renderNotFound(title) {
  setMeta(`${title} | Andén`, HOME_DESC);
  put(
    h('div', { class: 'top' }, link('/', '← Andén', 'logo'), badge(true)),
    h('div', { class: 'station' }, title),
    searchBox('Busca tu estación'),
    footer(),
  );
}

// ---- station page -----------------------------------------------------------------------------
function openStation(id) {
  s = { id, board: null, failed: null, loading: true, rateLimitedUntil: 0, openTrip: null };
  renderStation();
  refresh();
  loadStations().then(() => { if (s?.id === id && !s.board) renderStation(); }); // the name, sooner
  refreshTimer = setInterval(() => { if (document.visibilityState === 'visible') refresh(); }, REFRESH_MS);
  clockTimer = setInterval(() => { if (document.visibilityState === 'visible') renderStation(); }, CLOCK_MS);
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'visible' || !s) return;
  renderStation(); // at once: countdowns and stale banners from the current clock
  const age = s.board ? Date.now() - Date.parse(s.board.generatedAt) : Infinity;
  if (age > REFRESH_MS) refresh();
});

const rateLimited = () => s && Date.now() < s.rateLimitedUntil;

let inFlight = null; // {gen, promise}: one board request at a time per page

function refresh(manual = false) {
  if (!s || (rateLimited() && !manual)) return null;
  if (inFlight?.gen === gen) return inFlight.promise;
  const promise = doRefresh().finally(() => { if (inFlight?.promise === promise) inFlight = null; });
  inFlight = { gen, promise };
  return promise;
}

async function doRefresh() {
  const myGen = gen, id = s.id;
  try {
    const b = await fetchJson(`/api/board/${id}`, fetch, abort.signal);
    if (myGen !== gen) return;
    if (!validBoard(b)) throw new ApiError('unavailable');
    s.board = b;
    s.failed = null;
  } catch (e) {
    if (myGen !== gen || e?.name === 'AbortError') return;
    s.failed = e instanceof ApiError ? e.kind : 'unavailable';
    if (s.failed === 'ratelimited') s.rateLimitedUntil = Date.now() + RATE_LIMIT_MS;
  }
  s.loading = false;
  renderStation();
}

/** Minutes left now, from the estimated time (the board's own `minutes` was at generatedAt). */
const minutesLeft = (d, now) => Math.max(0, Math.floor((Date.parse(d.estimated) - now) / 60_000));

/** Black or white text on a line colour, whichever reads better (as the app's lineTextColor). */
function lineInk(hex) {
  const ch = (i) => {
    const c = parseInt(hex.slice(i, i + 2), 16) / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * ch(1) + 0.7152 * ch(3) + 0.0722 * ch(5) > 0.179 ? 'ink-dark' : 'ink-light';
}

/** A line badge in its line's colour. Set through the CSSOM (el.style), which the page CSP
 * allows; a style="" attribute in markup would be blocked. The colour was checked by validBoard. */
function lineBadge(d) {
  const el = h('span', { class: `line ${lineInk(d.color)}` }, d.line);
  el.style.backgroundColor = d.color;
  return el;
}

function toggleStops(trip) {
  s.openTrip = s.openTrip === trip ? null : trip;
  renderStation();
}

function stopsPanel(d) {
  const rest = d.stops.slice(1);
  return h('div', { class: 'stops' },
    rest.length === 0 ? h('div', { class: 'sub' }, 'Sin más paradas')
      : rest.map((st) => h('div', { class: 's' }, h('b', {}, hhmm(st.time)), h('span', {}, st.name))),
    h('a', { class: 'cta', href: APP_STORE, rel: 'noopener' }, '🔔 Sigue este tren y recibe avisos — descarga la app'));
}

function timeEl(d) {
  const delay = delayMinutes(d);
  const kids = [];
  if (!d.live) kids.push(h('span', { class: 'planned', title: 'previsto', 'aria-label': 'previsto' }, '○'));
  if (delay != null) {
    kids.push(h('s', {}, hhmm(d.scheduled)), ' ',
      h('span', { class: delay < 0 ? 'st-good' : isLate(d) ? 'st-late' : '' }, hhmm(d.estimated)));
  } else {
    kids.push(d.cancelled ? h('s', {}, hhmm(d.estimated)) : hhmm(d.estimated));
  }
  return h('span', { class: 'clock' }, kids);
}

function trainRow(d, now) {
  const open = s.openTrip === d.tripId;
  const plat = platformText(d);
  const wait = d.cancelled ? h('span', { class: 'st-bad' }, 'Cancelado')
    : h('span', { class: isLate(d) ? 'st-late' : '' }, waitText(minutesLeft(d, now)));
  const toggle = () => toggleStops(d.tripId);
  return [
    h('div', { class: d.cancelled ? 'row cancelled' : 'row', role: 'button', tabindex: 0, 'data-key': `t:${d.tripId}@${d.scheduled}`,
      'aria-expanded': String(open), onclick: toggle,
      onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); } } },
    lineBadge(d),
    h('div', { class: 'd' }, h('div', { class: 'name' }, `→ ${shortStopName(d.dest)}`),
      h('div', { class: 'sub' }, timeEl(d), plat ? [' · ', h('span', { class: d.livePlatform ? 'plat-live' : '' }, plat)] : null)),
    h('div', { class: 'w' }, wait)),
    open ? stopsPanel(d) : null,
  ];
}

function banner(text, onRetry) {
  return h('div', { class: 'banner', role: 'status' }, h('span', {}, text),
    onRetry ? h('button', { type: 'button', 'data-key': 'retry', onclick: onRetry }, 'Reintentar') : null);
}

function renderStation() {
  if (!s) return;
  try {
    drawStation();
  } catch (e) {
    // Never a frozen page: an answer the page cannot draw shows as the API being unavailable.
    console.error(e);
    put(h('div', { class: 'top' }, link('/', '← Andén', 'logo'), badge(true)),
      banner('No se pudieron mostrar los trenes', () => { s.board = null; s.loading = true; drawStation(); refresh(true); }),
      footer());
  }
}

function drawStation() {
  const now = Date.now();
  const b = s.board;
  const name = b?.station.name ?? nameOf(s.id);
  if (s.failed === 'notfound' && !b) return renderNotFound('Estación no encontrada');
  const where = b ? b.station.nucleos.join(', ') : stationOf(s.id)?.nucleo;
  setMeta(name ? `${name} — próximos trenes y andén | Andén` : 'Andén',
    name ? `Próximos trenes desde ${name}${where ? ` (${where})` : ''}: andén, retrasos y cancelaciones en tiempo real, cada 30 segundos. Gratis y sin registro.` : HOME_DESC);

  const head = [
    h('div', { class: 'top' }, link('/', '← Andén', 'logo'), badge(true)),
    h('h1', { class: 'station' }, name ?? ''),
  ];
  const meta = [];
  if (where) meta.push(h('span', {}, where));
  if (located?.id === s.id) meta.push(h('span', {}, formatDistance(located.meters)));
  const age = b ? now - Date.parse(b.generatedAt) : 0;
  const expired = b && age > EXPIRE_MS;
  const stale = b && (s.failed || rateLimited() || age > STALE_MS);
  if (b && !stale) meta.push(h('span', { class: b.rtStale ? 'notlive' : 'live' }, liveText(b)));
  head.push(h('div', { class: 'meta' }, meta), searchBox('Cambiar de estación'));

  const body = [];
  if (!b) {
    if (s.loading) body.push(h('div', { class: 'spinner', 'aria-label': 'Cargando' }));
    else if (s.failed === 'ratelimited') body.push(banner('Mucha gente ahora mismo. Volvemos a probar en unos minutos.'));
    else body.push(banner('No se pudieron cargar los trenes', () => refresh(true)));
    put(head, body, footer());
    return;
  }
  const updated = `Actualizado ${hhmm(b.generatedAt)}`;
  if (rateLimited()) body.push(banner('Mucha gente ahora mismo. Volvemos a probar en unos minutos.'));
  if (stale && !rateLimited()) body.push(banner(updated, () => refresh(true)));
  if (!b.feedCoversToday || b.feedStale) body.push(banner('El horario puede estar desactualizado'));
  if (!expired) {
    const shown = b.departures.filter((d) => Date.parse(d.estimated) >= now - 60_000);
    if (shown.length === 0) body.push(h('div', { class: 'empty' }, 'No hay más trenes hoy desde esta estación'));
    else body.push(h('div', { class: 'board' }, shown.map((d) => trainRow(d, now))));
  }
  put(head, body, footer());
}

window.addEventListener('popstate', route);
route();
