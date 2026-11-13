// vellum.js --- the viewer: pdf.js, driven from Emacs
//
// Emacs calls the functions on `window.vellum`; the viewer answers with
// `post`, which reaches Emacs as one line of JSON.  The viewer has no
// keyboard handling of its own, since it never has the keyboard.

import * as pdfjsLib from './pdfjs/build/pdf.min.mjs';

globalThis.pdfjsLib = pdfjsLib;
pdfjsLib.GlobalWorkerOptions.workerSrc = new URL('pdfjs/build/pdf.worker.min.mjs', location.href).href;

const { EventBus, PDFViewer, PDFLinkService, PDFFindController, LinkTarget, FindState } =
  await import('./pdfjs/web/pdf_viewer.mjs');

const ASSET = (path) => new URL(`pdfjs/${path}/`, location.href).href;

function post(type, data = {}) {
  window.webkit?.messageHandlers?.vellum?.postMessage({ type, ...data });
}

window.addEventListener('error', (e) => post('error', { message: String(e.message) }));
window.addEventListener('unhandledrejection', (e) =>
  post('error', { message: String(e.reason?.message ?? e.reason) }));


// --- Stages ---------------------------------------------------------------

class Stage {
  constructor(element) {
    this.container = element;
    this.bus = new EventBus();
    this.links = new PDFLinkService({ eventBus: this.bus, externalLinkTarget: LinkTarget.TOP });
    this.finder = new PDFFindController({ eventBus: this.bus, linkService: this.links });
    this.viewer = new PDFViewer({
      container: element,
      viewer: element.firstElementChild,
      eventBus: this.bus,
      linkService: this.links,
      findController: this.finder,
      removePageBorders: true,
      textLayerMode: 1,
      annotationMode: pdfjsLib.AnnotationMode.ENABLE,
      enableAutoLinking: true,   // a web address in plain text is a link too
      supportsPinchToZoom: false,
      maxCanvasPixels: 2 ** 25,
    });
    this.links.setViewer(this.viewer);
    this.doc = null;

    // A followed link is a jump, and the place it left is remembered.
    for (const name of ['goToDestination', 'goToPage', 'setHash', 'executeNamedAction']) {
      const follow = this.links[name].bind(this.links);
      this.links[name] = (...args) => {
        if (this === front) remember();
        return follow(...args);
      };
    }

    this.bus.on('pagechanging', (e) => { if (this === front) reportPlace(); });
    this.bus.on('scalechanging', () => { if (this === front) reportPlace(); });
    this.bus.on('updatefindcontrolstate', (e) => { if (this === front) reportFind(e); });
    this.bus.on('updatefindmatchescount', (e) => {
      if (this === front) post('find', { state: 'count', ...e.matchesCount });
    });
    element.addEventListener('scroll', () => { if (this === front) reportPlaceSoon(); },
                             { passive: true });
  }

  // Where the reader is, in terms that survive a rebuild of the document:
  // a page, and how far down and across it the top left of the view sits.
  get place() {
    const v = this.viewer;
    if (!v.pagesCount) return null;
    const c = this.container;
    let number = v.currentPageNumber;
    // The current page by pdf.js's reckoning is the most visible one; the
    // anchor is the page under the top edge of the view.
    for (let n = 1; n <= v.pagesCount; n++) {
      const div = v.getPageView(n - 1).div;
      if (div.offsetTop + div.offsetHeight > c.scrollTop) { number = n; break; }
    }
    const div = v.getPageView(number - 1).div;
    return {
      page: number,
      current: v.currentPageNumber,
      pages: v.pagesCount,
      top: (c.scrollTop - div.offsetTop) / div.offsetHeight,
      left: c.scrollWidth > c.clientWidth ? c.scrollLeft / c.scrollWidth : 0,
      scale: v.currentScaleValue,
      zoom: v.currentScale,
    };
  }

  set place(p) {
    const v = this.viewer;
    if (!p || !v.pagesCount) return;
    if (p.scale != null) v.currentScaleValue = String(p.scale);
    const number = Math.min(Math.max(1, p.page | 0), v.pagesCount);
    const div = v.getPageView(number - 1).div;
    const c = this.container;
    c.scrollTop = div.offsetTop + (p.top ?? 0) * div.offsetHeight;
    c.scrollLeft = (p.left ?? 0) * c.scrollWidth;
    v.update();
  }

  // Resolves when the pages now in view have been painted (or soon enough).
  painted(timeout = 2500) {
    const v = this.viewer;
    return new Promise((resolve) => {
      const check = () => {
        const views = v._getVisiblePages().views;
        if (views.length && views.every((x) => x.view.renderingState === 3)) {
          this.bus.off('pagerendered', check);
          resolve();
          return true;
        }
        return false;
      };
      if (check()) return;
      this.bus.on('pagerendered', check);
      setTimeout(() => { this.bus.off('pagerendered', check); resolve(); }, timeout);
    });
  }

  async close() {
    const doc = this.doc;
    this.doc = null;
    this.viewer.setDocument(null);
    this.links.setDocument(null);
    this.finder.setDocument(null);
    if (doc) await doc.loadingTask.destroy().catch(() => {});
  }
}

let front = new Stage(document.getElementById('stage-a'));
let back = new Stage(document.getElementById('stage-b'));
front.container.classList.add('front');

const notice = document.getElementById('notice');
function say(text) {
  notice.textContent = text || '';
  notice.classList.toggle('shown', !!text);
}


// --- Reporting to Emacs ----------------------------------------------------

let placeTimer = null;
function reportPlace() {
  const p = front.place;
  if (p) post('place', p);
}
function reportPlaceSoon() {
  if (placeTimer) return;
  placeTimer = setTimeout(() => { placeTimer = null; reportPlace(); }, 150);
}

function reportFind(e) {
  const names = { [FindState.FOUND]: 'found', [FindState.NOT_FOUND]: 'missing',
                  [FindState.WRAPPED]: 'wrapped', [FindState.PENDING]: 'pending' };
  post('find', { state: names[e.state], ...e.matchesCount });
}


// --- Loading -----------------------------------------------------------------

let loadSerial = 0;
let currentFile = null;
let defaultScale = 'page-width';

async function load(file, place) {
  const serial = ++loadSerial;
  const again = file === currentFile && front.doc;
  const keep = place ?? (again ? front.place : null);
  let doc;
  try {
    const task = pdfjsLib.getDocument({
      url: 'vellum://file' + encodeURI(file).replace(/[?#]/g, encodeURIComponent)
        + '?' + Date.now(),
      cMapUrl: ASSET('cmaps'),
      cMapPacked: true,
      standardFontDataUrl: ASSET('standard_fonts'),
      wasmUrl: ASSET('wasm'),
      iccUrl: ASSET('iccs'),
      disableRange: true,
      disableStream: true,
      disableAutoFetch: true,
    });
    doc = await task.promise;
  } catch (error) {
    // A PDF caught half written by the compiler: the one on screen stays.
    if (serial === loadSerial) {
      if (!front.doc) say(`${file}\n${error.message}`);
      post('failed', { file, message: String(error.message) });
    }
    return;
  }
  if (serial !== loadSerial) { doc.loadingTask.destroy(); return; }

  const stage = back;
  await stage.close();
  stage.doc = doc;
  stage.viewer.setDocument(doc);
  stage.links.setDocument(doc);
  stage.finder.setDocument(doc);
  await stage.viewer.firstPagePromise;
  if (serial !== loadSerial) return;

  stage.viewer.currentScaleValue = String(keep?.scale ?? defaultScale);
  if (keep) stage.place = keep;
  await stage.painted();
  if (serial !== loadSerial) return;

  const old = front;
  front = stage;
  back = old;
  front.container.classList.add('front');
  back.container.classList.remove('front');
  back.close();
  currentFile = file;
  say('');

  const meta = await doc.getMetadata().catch(() => null);
  post('loaded', { file, pages: doc.numPages, title: meta?.info?.Title || '', again: !!again });
  reportPlace();
}


// --- Moving about ------------------------------------------------------------

function scroll(unit, amount, smooth = true) {
  const c = front.container;
  const sizes = {
    line: [40, 40],
    screen: [c.clientWidth * 0.9, c.clientHeight * 0.9],
    half: [c.clientWidth * 0.5, c.clientHeight * 0.5],
  };
  if (unit === 'left' || unit === 'right') {
    c.scrollBy({ left: (unit === 'left' ? -1 : 1) * amount * 40,
                 behavior: smooth ? 'smooth' : 'instant' });
    return;
  }
  const [, dy] = sizes[unit] ?? sizes.line;
  c.scrollBy({ top: amount * dy, behavior: smooth ? 'smooth' : 'instant' });
}

function page(n, relative = false) {
  const v = front.viewer;
  if (!v.pagesCount) return;
  if (!relative) remember();
  const target = Math.min(Math.max(1, relative ? v.currentPageNumber + n : n), v.pagesCount);
  const div = v.getPageView(target - 1).div;
  front.container.scrollTo({ top: div.offsetTop, behavior: 'instant' });
}

function edge(which) {
  remember();
  const c = front.container;
  c.scrollTo({ top: which === 'end' ? c.scrollHeight : 0, behavior: 'instant' });
}

// Places left by jumps (links, a page by number, the ends), to go back to;
// and those gone back from, to go forward to again.  They are kept apart
// from the stages, so they survive a rebuild of the document.
const behind = [], ahead = [];

function remember() {
  const here = front.place;
  if (!here) return;
  const last = behind.at(-1);
  if (last && last.page === here.page && Math.abs(last.top - here.top) < 0.01) return;
  behind.push(here);
  if (behind.length > 100) behind.shift();
  ahead.length = 0;
}

// STEP is -1 to go back, 1 to go forward.  The zoom stays as it is now.
function history(step) {
  const [from, to] = step < 0 ? [behind, ahead] : [ahead, behind];
  const there = from.pop();
  if (!there) {
    post('history', { empty: step < 0 ? 'back' : 'forward' });
    return;
  }
  const here = front.place;
  if (here) to.push(here);
  front.place = { ...there, scale: null };
  reportPlace();
}

function zoom(how) {
  const v = front.viewer;
  if (!v.pagesCount) return;
  if (how === 'in') v.updateScale({ steps: 1 });
  else if (how === 'out') v.updateScale({ steps: -1 });
  else v.currentScaleValue = String(how);
  if (typeof how === 'string' && !/^(in|out)$/.test(how)) defaultScale = how;
}

// A named destination or outline item.
function goto(dest) {
  front.links.goToDestination(dest);
}


// --- A floor under zooming out ------------------------------------------------

// Nothing is gained by a page smaller than the window: once a whole page
// fits, zooming out stops there.
function fitScale(stage) {
  const v = stage.viewer;
  const view = v.pagesCount && v.getPageView(v.currentPageNumber - 1);
  if (!view || !v.currentScale) return 0;
  const c = stage.container;
  const width = view.viewport.width / v.currentScale;
  const height = view.viewport.height / v.currentScale;
  return Math.min(c.clientWidth / width, c.clientHeight / height);
}

for (const stage of [front, back]) {
  stage.bus.on('scalechanging', (e) => {
    const floor = fitScale(stage);
    if (floor && e.scale < floor * 0.995) {
      requestAnimationFrame(() => { stage.viewer.currentScaleValue = 'page-fit'; });
    }
  });
}


// --- Zooming by hand ---------------------------------------------------------

// Trackpad pinch arrives as WebKit gesture events; pdf.js scales what is
// painted at once and repaints sharply when the fingers rest.
let gestureScale = 1;
document.addEventListener('gesturestart', (e) => { e.preventDefault(); gestureScale = 1; });
document.addEventListener('gesturechange', (e) => {
  e.preventDefault();
  const factor = e.scale / gestureScale;
  gestureScale = e.scale;
  front.viewer.updateScale({ drawingDelay: 300, scaleFactor: factor,
                             origin: [e.clientX, e.clientY] });
});
document.addEventListener('gestureend', (e) => e.preventDefault());

document.addEventListener('wheel', (e) => {
  if (!(e.ctrlKey || e.metaKey)) return;
  e.preventDefault();
  front.viewer.updateScale({ drawingDelay: 300, scaleFactor: Math.exp(-e.deltaY / 200),
                             origin: [e.clientX, e.clientY] });
}, { passive: false });

// Named scales follow the window as Emacs resizes it.  Only a change that
// matters to the scale lays the pages out again: the minibuffer growing by a
// line must not disturb a page fitted to the window's width.
let lastWidth = innerWidth, lastHeight = innerHeight;
addEventListener('resize', () => {
  const wider = innerWidth !== lastWidth, taller = innerHeight !== lastHeight;
  lastWidth = innerWidth;
  lastHeight = innerHeight;
  for (const stage of [front, back]) {
    const v = stage.viewer;
    if (!v.pagesCount) continue;
    const value = v.currentScaleValue;
    const refit = (value === 'page-width' && wider)
      || ((value === 'page-fit' || value === 'auto') && (wider || taller));
    if (refit) {
      const place = stage.place;
      v.currentScaleValue = value;
      stage.place = { ...place, scale: null };
    } else {
      v.update();
    }
  }
});


// --- SyncTeX -----------------------------------------------------------------

// Coordinates here are SyncTeX's: big points from the top left of the page.
function pagePoint(event) {
  const pageDiv = event.target.closest?.('.page');
  if (!pageDiv) return null;
  const number = Number(pageDiv.dataset.pageNumber);
  const view = front.viewer.getPageView(number - 1);
  const rect = pageDiv.getBoundingClientRect();
  const [px, py] = view.viewport.convertToPdfPoint(event.clientX - rect.left - pageDiv.clientLeft,
                                                    event.clientY - rect.top - pageDiv.clientTop);
  const [x0, , , y1] = view.viewport.viewBox;
  return { page: number, x: px - x0, y: y1 - py };
}

function wordAt(event) {
  const range = document.caretRangeFromPoint?.(event.clientX, event.clientY);
  const node = range?.startContainer;
  if (!node || node.nodeType !== Node.TEXT_NODE) return '';
  const text = node.textContent;
  let a = range.startOffset, b = range.startOffset;
  while (a > 0 && /[\p{L}\p{N}]/u.test(text[a - 1])) a--;
  while (b < text.length && /[\p{L}\p{N}]/u.test(text[b])) b++;
  return text.slice(a, b);
}

function inverse(event) {
  const point = pagePoint(event);
  if (!point) return;
  event.preventDefault();
  getSelection().removeAllRanges();
  post('inverse', { ...point, word: wordAt(event) });
}

document.addEventListener('mousedown', (e) => {
  post('focus');
  if (e.metaKey) inverse(e);
}, true);
document.addEventListener('dblclick', inverse, true);
document.addEventListener('contextmenu', (e) => e.preventDefault());

// Show where a source line landed.  BOXES are {page, h, v, W, H}: the left
// end of the baseline, and the width and height of the line above it.
function sync(boxes) {
  const v = front.viewer;
  if (!boxes?.length || !v.pagesCount) return;
  const first = boxes[0];
  const view = v.getPageView(first.page - 1);
  if (!view) return;
  const [x0, y0, x1, y1] = view.viewport.viewBox;
  const width = x1 - x0, height = y1 - y0;
  const div = view.div;
  const c = front.container;

  // Bring the line a third of the way down the view, unless it is already
  // comfortably in sight: the eye should not have to chase the page.
  const y = div.offsetTop + div.clientTop + (first.v / height) * div.clientHeight;
  const margin = c.clientHeight * 0.15;
  if (y < c.scrollTop + margin || y > c.scrollTop + c.clientHeight - margin) {
    const target = y - c.clientHeight / 3;
    const far = Math.abs(target - c.scrollTop) > c.clientHeight * 3;
    c.scrollTo({ top: target, behavior: far ? 'instant' : 'smooth' });
  }

  for (const old of document.querySelectorAll('.sync-band, .sync-tick')) old.remove();
  // SyncTeX may answer with every box a line had a hand in; the first is
  // the line itself, and its neighbours are the rest of a wrapped sentence.
  const near = boxes.filter((b) => b.page === first.page && Math.abs(b.v - first.v) < 3 * Math.max(first.H, 8));
  for (const box of near.slice(0, 3)) {
    const band = document.createElement('div');
    band.className = 'sync-band';
    const pad = 2;
    band.style.left = `calc(${(box.h / width) * 100}% - ${pad}px)`;
    band.style.top = `calc(${((box.v - box.H) / height) * 100}% - ${pad}px)`;
    band.style.width = `calc(${(box.W / width) * 100}% + ${2 * pad}px)`;
    band.style.height = `calc(${(Math.max(box.H, 6) / height) * 100}% + ${2 * pad}px)`;
    div.append(band);
    band.addEventListener('animationend', () => band.remove());
  }
  const tick = document.createElement('div');
  tick.className = 'sync-tick';
  tick.style.left = `calc(${(first.h / width) * 100}% - 12px)`;
  tick.style.top = `${((first.v - first.H) / height) * 100}%`;
  tick.style.width = '2px';
  tick.style.height = `${(Math.max(first.H, 6) / height) * 100}%`;
  div.append(tick);
  tick.addEventListener('animationend', () => tick.remove());
}


// --- Search, outline, selection -------------------------------------------------

let lastQuery = '';
function find(query, backward = false) {
  const again = query === lastQuery;
  lastQuery = query;
  front.bus.dispatch('find', {
    source: window, type: again ? 'again' : '', query,
    caseSensitive: /\p{Lu}/u.test(query), entireWord: false, highlightAll: true,
    findPrevious: backward, matchDiacritics: false,
  });
}

function findClose() {
  lastQuery = '';
  front.bus.dispatch('findbarclose', { source: window });
}

async function outline() {
  const doc = front.doc;
  if (!doc) return;
  const items = [];
  const walk = async (nodes, depth) => {
    for (const node of nodes ?? []) {
      let number = null;
      try {
        const dest = typeof node.dest === 'string' ? await doc.getDestination(node.dest) : node.dest;
        if (dest?.[0]) number = (await doc.getPageIndex(dest[0])) + 1;
      } catch {}
      items.push({ title: node.title, depth, page: number, dest: node.dest });
      await walk(node.items, depth + 1);
    }
  };
  await walk(await doc.getOutline(), 0);
  post('outline', { items });
}

function selection() {
  post('selection', { text: String(getSelection()) });
}


// --- Paper ---------------------------------------------------------------------

function theme(colours) {
  const style = document.documentElement.style;
  for (const [name, value] of Object.entries(colours)) style.setProperty(`--${name}`, value);
}

window.vellum = {
  load, scroll, page, edge, history, zoom, goto, sync, find, findClose, outline, selection, theme,
  place: (p) => { front.place = p; reportPlace(); },
};

post('ready');
