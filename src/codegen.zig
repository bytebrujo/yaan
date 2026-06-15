const std = @import("std");
const parser = @import("parser.zig");
const css = @import("css.zig");

pub const GeneratedComponent = struct {
    js: []u8,
    css: []u8,
    scope: []u8,
    /// Static prerendered skeleton inlined into #app for hydration.
    prerender: []u8,
};

const EmitContext = struct {
    next_id: usize = 0,
    next_cursor: usize = 0,

    fn nodeName(self: *EmitContext, allocator: std.mem.Allocator) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;
        return std.fmt.allocPrint(allocator, "n{d}", .{id});
    }

    fn cursorName(self: *EmitContext, allocator: std.mem.Allocator) ![]u8 {
        const id = self.next_cursor;
        self.next_cursor += 1;
        return std.fmt.allocPrint(allocator, "cur{d}", .{id});
    }
};

pub fn generateComponent(allocator: std.mem.Allocator, path: []const u8, component: parser.Component) !GeneratedComponent {
    const scope = try css.scopeName(allocator, path, component.source);
    const scoped_css = try css.scopeCss(allocator, component.style, scope);
    const script = try splitScriptImports(allocator, component.script);
    defer {
        allocator.free(script.imports);
        allocator.free(script.body);
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "import { $signal, $state, $memo, $derived, $resource, $effect, text, mount, clear, reconcileKeyed, reconcileIndexed, hydrateCursor, hydrateElement, hydrateText, hydrateComment, hydrateInterp } from '../runtime.js';\n");
    try out.appendSlice(allocator, "import { asset } from '../assets.js';\n");
    if (script.imports.len > 0) {
        try out.appendSlice(allocator, script.imports);
        try out.append(allocator, '\n');
    }

    // create(): build the component from scratch (no prerendered DOM).
    try out.appendSlice(allocator, "\nexport function create(target, props = {}) {\n");
    try out.appendSlice(allocator, "  const disposers = [];\n");
    if (script.body.len > 0) {
        try out.appendSlice(allocator, script.body);
        try out.append(allocator, '\n');
    }
    var ctx = EmitContext{};
    try emitNodes(allocator, &out, &ctx, component.children, "target", scope, "  ");
    try out.appendSlice(allocator,
        \\  return {
        \\    snapshot: typeof snapshot !== 'undefined' ? snapshot : null,
        \\    destroy() { for (const dispose of disposers.splice(0)) dispose(); clear(target); }
        \\  };
        \\
    );
    try out.appendSlice(allocator, "}\n");

    // hydrate(): adopt the prerendered skeleton in #app, attaching events/effects.
    try out.appendSlice(allocator, "\nexport function hydrate(target, props = {}) {\n");
    try out.appendSlice(allocator, "  const disposers = [];\n");
    if (script.body.len > 0) {
        try out.appendSlice(allocator, script.body);
        try out.append(allocator, '\n');
    }
    var hydrate_ctx = EmitContext{};
    const root_cursor = try hydrate_ctx.cursorName(allocator);
    defer allocator.free(root_cursor);
    try out.print(allocator, "  const {s} = hydrateCursor(target);\n", .{root_cursor});
    try emitHydrateNodes(allocator, &out, &hydrate_ctx, component.children, root_cursor, scope, "  ");
    try out.appendSlice(allocator,
        \\  return {
        \\    snapshot: typeof snapshot !== 'undefined' ? snapshot : null,
        \\    destroy() { for (const dispose of disposers.splice(0)) dispose(); clear(target); }
        \\  };
        \\
    );
    try out.appendSlice(allocator, "}\n");

    var prerender: std.ArrayList(u8) = .empty;
    try prerenderNodes(allocator, &prerender, component.children, scope);

    return .{
        .js = try out.toOwnedSlice(allocator),
        .css = scoped_css,
        .scope = scope,
        .prerender = try prerender.toOwnedSlice(allocator),
    };
}

const ScriptParts = struct {
    imports: []u8,
    body: []u8,
};

fn splitScriptImports(allocator: std.mem.Allocator, script: []const u8) !ScriptParts {
    var imports: std.ArrayList(u8) = .empty;
    var body: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |line| {
        const trimmed = trimLeft(line, " \t");
        const target = if (std.mem.startsWith(u8, trimmed, "import ")) &imports else &body;
        try target.appendSlice(allocator, line);
        try target.append(allocator, '\n');
    }
    return .{
        .imports = try imports.toOwnedSlice(allocator),
        .body = try body.toOwnedSlice(allocator),
    };
}

fn trimLeft(value: []const u8, chars: []const u8) []const u8 {
    var i: usize = 0;
    while (i < value.len and std.mem.indexOfScalar(u8, chars, value[i]) != null) i += 1;
    return value[i..];
}

pub fn runtimeSource() []const u8 {
    return
    \\let activeObserver = null;
    \\
    \\function track(dep) {
    \\  if (!activeObserver) return;
    \\  dep.subscribers.add(activeObserver);
    \\  activeObserver.deps.add(dep);
    \\}
    \\
    \\function cleanupObserver(observer) {
    \\  for (const dep of observer.deps) dep.subscribers.delete(observer);
    \\  observer.deps.clear();
    \\}
    \\
    \\function notify(dep) {
    \\  for (const observer of [...dep.subscribers]) observer.run();
    \\}
    \\
    \\export function $signal(initial) {
    \\  const dep = { value: initial, subscribers: new Set() };
    \\  function signal() { return signal.read(); }
    \\  signal.read = () => { track(dep); return dep.value; };
    \\  signal.peek = () => dep.value;
    \\  signal.set = (next) => {
    \\    if (Object.is(dep.value, next)) return next;
    \\    dep.value = next;
    \\    notify(dep);
    \\    return next;
    \\  };
    \\  signal.update = (fn) => signal.set(fn(dep.value));
    \\  signal.write = (fn) => {
    \\    const current = dep.value;
    \\    const next = fn(current);
    \\    dep.value = next === undefined ? current : next;
    \\    notify(dep);
    \\    return dep.value;
    \\  };
    \\  signal.subscribe = (fn) => {
    \\    const observer = { deps: new Set(), run: () => fn(dep.value) };
    \\    dep.subscribers.add(observer);
    \\    fn(dep.value);
    \\    return () => dep.subscribers.delete(observer);
    \\  };
    \\  return signal;
    \\}
    \\
    \\export const $state = $signal;
    \\
    \\export function $memo(fn) {
    \\  const value = $signal(undefined);
    \\  const dispose = $effect(() => value.set(fn()));
    \\  value.dispose = dispose;
    \\  return value;
    \\}
    \\
    \\export const $derived = $memo;
    \\
    \\export function $resource(loader, options = {}) {
    \\  const state = $signal({ status: 'pending', value: options.initial, error: null });
    \\  let version = 0;
    \\  function load() {
    \\    const run = ++version;
    \\    const previous = state.peek();
    \\    state.set({ status: 'pending', value: previous.value, error: null });
    \\    let loaded;
    \\    try {
    \\      loaded = loader();
    \\    } catch (error) {
    \\      state.set({ status: 'error', value: state.peek().value, error });
    \\      return;
    \\    }
    \\    Promise.resolve(loaded)
    \\      .then(value => {
    \\        if (run === version) state.set({ status: 'ready', value, error: null });
    \\      })
    \\      .catch(error => {
    \\        if (run === version) state.set({ status: 'error', value: state.peek().value, error });
    \\      });
    \\  }
    \\  const dispose = $effect(load);
    \\  return {
    \\    read: state.read,
    \\    peek: state.peek,
    \\    value() { return state.read().value; },
    \\    error() { return state.read().error; },
    \\    pending() { return state.read().status === 'pending'; },
    \\    ready() { return state.read().status === 'ready'; },
    \\    failed() { return state.read().status === 'error'; },
    \\    reload: load,
    \\    dispose,
    \\  };
    \\}
    \\
    \\export function $effect(fn) {
    \\  const observer = {
    \\    deps: new Set(),
    \\    cleanup: null,
    \\    stopped: false,
    \\    run() {
    \\      if (observer.stopped) return;
    \\      cleanupObserver(observer);
    \\      if (observer.cleanup) observer.cleanup();
    \\      const previous = activeObserver;
    \\      activeObserver = observer;
    \\      try {
    \\        const cleanup = fn();
    \\        observer.cleanup = typeof cleanup === 'function' ? cleanup : null;
    \\      } finally {
    \\        activeObserver = previous;
    \\      }
    \\    },
    \\  };
    \\  observer.run();
    \\  return () => {
    \\    observer.stopped = true;
    \\    cleanupObserver(observer);
    \\    if (observer.cleanup) observer.cleanup();
    \\    observer.cleanup = null;
    \\  };
    \\}
    \\export function text(target, value) {
    \\  const node = document.createTextNode(value ?? "");
    \\  target.appendChild(node);
    \\  return { update(next) { node.data = next ?? ""; }, destroy() { node.remove(); } };
    \\}
    \\export function mount(target, node) { target.appendChild(node); return node; }
    \\export function clear(target) { while (target.firstChild) target.firstChild.remove(); }
    \\export function hydrateCursor(parent) { return { parent, next: parent.firstChild }; }
    \\export function hydrateElement(cur, tag) {
    \\  let node = cur.next;
    \\  if (node && node.nodeType === 1 && node.tagName.toLowerCase() === tag) {
    \\    cur.next = node.nextSibling;
    \\  } else {
    \\    node = document.createElement(tag);
    \\    cur.parent.insertBefore(node, cur.next);
    \\  }
    \\  return node;
    \\}
    \\export function hydrateText(cur, value) {
    \\  let node = cur.next;
    \\  if (node && node.nodeType === 3) {
    \\    node.data = value ?? "";
    \\    cur.next = node.nextSibling;
    \\  } else {
    \\    node = document.createTextNode(value ?? "");
    \\    cur.parent.insertBefore(node, cur.next);
    \\  }
    \\  return node;
    \\}
    \\export function hydrateComment(cur, label) {
    \\  let node = cur.next;
    \\  if (node && node.nodeType === 8) {
    \\    cur.next = node.nextSibling;
    \\  } else {
    \\    node = document.createComment(label);
    \\    cur.parent.insertBefore(node, cur.next);
    \\  }
    \\  return node;
    \\}
    \\export function hydrateInterp(cur, value) {
    \\  // Interpolations are never prerendered; always insert a fresh text node at the cursor.
    \\  const node = document.createTextNode(value ?? "");
    \\  cur.parent.insertBefore(node, cur.next);
    \\  return { update(next) { node.data = next ?? ""; }, destroy() { node.remove(); } };
    \\}
    \\export function reconcileKeyed(anchor, state, list, keyFn, render) {
    \\  const next = new Map();
    \\  for (let i = 0; i < list.length; i++) {
    \\    const item = list[i], key = keyFn(item, i);
    \\    let block = state.blocks.get(key);
    \\    if (!block) block = render(item, i);
    \\    next.set(key, block);
    \\    anchor.parentNode.insertBefore(block.fragment, anchor);
    \\  }
    \\  for (const [key, block] of state.blocks) if (!next.has(key)) block.destroy();
    \\  state.blocks = next;
    \\}
    \\export function reconcileIndexed(anchor, state, list, render) {
    \\  while (state.blocks.length > list.length) state.blocks.pop().destroy();
    \\  for (let i = 0; i < list.length; i++) {
    \\    if (!state.blocks[i]) state.blocks[i] = render(list[i], i);
    \\    anchor.parentNode.insertBefore(state.blocks[i].fragment, anchor);
    \\  }
    \\}
    ;
}

pub fn appSource(allocator: std.mem.Allocator, routes_json: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\import { routes } from './routes.js';
        \\
        \\const outlet = document.getElementById('app');
        \\const live = document.getElementById('yaan-live');
        \\let current = null;
        \\let formResult = null;
        \\let activeHistoryKey = null;
        \\let canHydrate = outlet ? outlet.dataset.yaanPrerendered === 'true' : false;
        \\if ('scrollRestoration' in history) history.scrollRestoration = 'manual';
        \\
        \\function newHistoryKey() {
        \\  if (globalThis.crypto?.randomUUID) return crypto.randomUUID();
        \\  return Date.now().toString(36) + Math.random().toString(36).slice(2);
        \\}
        \\
        \\function historyKey() {
        \\  const state = history.state;
        \\  return state && typeof state.ynKey === 'string' ? state.ynKey : null;
        \\}
        \\
        \\function ensureHistoryKey() {
        \\  const existing = historyKey();
        \\  if (existing) return existing;
        \\  const key = newHistoryKey();
        \\  const state = { ...(history.state || {}), ynKey: key };
        \\  history.replaceState(state, '', location.href);
        \\  return key;
        \\}
        \\
        \\function storageKey(key) {
        \\  return key ? 'yaan:snapshot:' + key : null;
        \\}
        \\
        \\function writeSnapshot(key, value) {
        \\  const name = storageKey(key);
        \\  if (!name) return;
        \\  try {
        \\    if (value === undefined) sessionStorage.removeItem(name);
        \\    else sessionStorage.setItem(name, JSON.stringify(value));
        \\  } catch (error) {
        \\    console.warn('Yaan snapshot capture failed', error);
        \\  }
        \\}
        \\
        \\function readSnapshot(key) {
        \\  const name = storageKey(key);
        \\  if (!name) return undefined;
        \\  try {
        \\    const raw = sessionStorage.getItem(name);
        \\    return raw == null ? undefined : JSON.parse(raw);
        \\  } catch (error) {
        \\    console.warn('Yaan snapshot restore failed', error);
        \\    return undefined;
        \\  }
        \\}
        \\
        \\function captureSnapshot(key = activeHistoryKey) {
        \\  writeScroll(key);
        \\  const snapshot = current?.snapshot;
        \\  if (!snapshot || typeof snapshot.capture !== 'function') return;
        \\  try {
        \\    writeSnapshot(key, snapshot.capture());
        \\  } catch (error) {
        \\    console.warn('Yaan snapshot capture failed', error);
        \\  }
        \\}
        \\
        \\function restoreSnapshot(key = activeHistoryKey) {
        \\  const snapshot = current?.snapshot;
        \\  if (!snapshot || typeof snapshot.restore !== 'function') return;
        \\  const value = readSnapshot(key);
        \\  if (value === undefined) return;
        \\  try {
        \\    snapshot.restore(value);
        \\  } catch (error) {
        \\    console.warn('Yaan snapshot restore failed', error);
        \\  }
        \\}
        \\
        \\function writeScroll(key) {
        \\  const name = key ? 'yaan:scroll:' + key : null;
        \\  if (!name) return;
        \\  try { sessionStorage.setItem(name, JSON.stringify({ x: scrollX, y: scrollY })); } catch (error) {}
        \\}
        \\function readScroll(key) {
        \\  const name = key ? 'yaan:scroll:' + key : null;
        \\  if (!name) return null;
        \\  try { const raw = sessionStorage.getItem(name); return raw == null ? null : JSON.parse(raw); } catch (error) { return null; }
        \\}
        \\function announce(message) {
        \\  if (!live) return;
        \\  live.textContent = '';
        \\  // Re-set on the next frame so repeated identical titles are still announced.
        \\  requestAnimationFrame(() => { live.textContent = message; });
        \\}
        \\function applyTitle(route, data) {
        \\  const title = (route && route.options && route.options.title)
        \\    || (data && typeof data === 'object' && typeof data.title === 'string' ? data.title : null)
        \\    || document.title;
        \\  if (document.title !== title) document.title = title;
        \\  announce(title);
        \\}
        \\function focusOutlet() {
        \\  if (outlet && typeof outlet.focus === 'function') outlet.focus({ preventScroll: true });
        \\}
        \\function swap(mutate, animate) {
        \\  if (animate && typeof document.startViewTransition === 'function') {
        \\    return document.startViewTransition(mutate).finished.catch(() => {});
        \\  }
        \\  return Promise.resolve().then(mutate);
        \\}
        \\const prefetched = new Set();
        \\function prefetchRoute(pathname) {
        \\  const found = match(pathname);
        \\  if (!found || prefetched.has(found.route.module)) return;
        \\  prefetched.add(found.route.module);
        \\  import(found.route.module).catch(() => prefetched.delete(found.route.module));
        \\}
        \\function escapeRe(value) {
        \\  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        \\}
        \\function routeRegex(route) {
        \\  if (route.path === '/') return { re: /^\/$/, names: [] };
        \\  const names = [];
        \\  let pattern = '';
        \\  for (const part of route.path.split('/').filter(Boolean)) {
        \\    if (part.startsWith(':') && part.endsWith('*')) {
        \\      names.push({ name: part.slice(1, -1), rest: true });
        \\      pattern += '(?:/(.*))?';
        \\    } else if (part.startsWith(':')) {
        \\      names.push({ name: part.slice(1), rest: false });
        \\      pattern += '/([^/]+)';
        \\    } else {
        \\      pattern += '/' + escapeRe(part);
        \\    }
        \\  }
        \\  const trailing = route.options?.trailingSlash ?? 'ignore';
        \\  const suffix = trailing === 'always' ? '/' : trailing === 'ignore' ? '/?' : '';
        \\  return { re: new RegExp('^' + pattern + suffix + '$'), names };
        \\}
        \\function match(pathname) {
        \\  for (const route of routes) {
        \\    const { re, names } = routeRegex(route);
        \\    const m = pathname.match(re);
        \\    if (m) {
        \\      const params = Object.fromEntries(names.map((entry, i) => [entry.name, decodeURIComponent(m[i + 1] || '')]));
        \\      return { route, params };
        \\    }
        \\  }
        \\  return null;
        \\}
        \\async function render(options = {}) {
        \\  const restore = options.restoreSnapshot !== false;
        \\  const animate = options.animate === true;
        \\  activeHistoryKey = ensureHistoryKey();
        \\  const found = match(location.pathname);
        \\  if (!found) {
        \\    await swap(() => {
        \\      if (current) current.destroy();
        \\      current = null;
        \\      outlet.replaceChildren();
        \\      outlet.textContent = '404';
        \\    }, animate);
        \\    canHydrate = false;
        \\    document.title = 'Not found';
        \\    announce('Not found');
        \\    focusOutlet();
        \\    return;
        \\  }
        \\  const [data, mod] = await Promise.all([
        \\    fetch('/_yaan/load?path=' + encodeURIComponent(location.pathname)).then(r => r.json()).catch(() => found.params),
        \\    import(found.route.module),
        \\  ]);
        \\  const props = { params: found.params, data, form: formResult };
        \\  const hydrateNow = canHydrate && typeof mod.hydrate === 'function' && outlet.childNodes.length > 0;
        \\  canHydrate = false;
        \\  await swap(() => {
        \\    if (hydrateNow) {
        \\      current = mod.hydrate(outlet, props);
        \\    } else {
        \\      if (current) current.destroy();
        \\      current = null;
        \\      outlet.replaceChildren();
        \\      current = mod.create(outlet, props);
        \\    }
        \\  }, animate && !hydrateNow);
        \\  applyTitle(found.route, data);
        \\  if (options.focus !== false) focusOutlet();
        \\  if (options.scroll === 'restore') {
        \\    const pos = readScroll(activeHistoryKey);
        \\    window.scrollTo(pos ? pos.x : 0, pos ? pos.y : 0);
        \\  } else if (options.scroll === 'top') {
        \\    window.scrollTo(0, 0);
        \\  }
        \\  if (restore) restoreSnapshot(activeHistoryKey);
        \\}
        \\async function submitForm(form) {
        \\  const url = new URL(form.getAttribute('action') || location.pathname, location.href);
        \\  const formData = new FormData(form);
        \\  const hasFile = Array.from(form.elements).some(el => el && el.type === 'file');
        \\  const isMultipart = hasFile || (form.enctype || '').toLowerCase() === 'multipart/form-data';
        \\  const init = { method: 'POST' };
        \\  if (isMultipart) {
        \\    init.body = formData;
        \\  } else {
        \\    init.headers = { 'content-type': 'application/x-www-form-urlencoded;charset=UTF-8' };
        \\    init.body = new URLSearchParams(formData);
        \\  }
        \\  const submitter = document.activeElement && form.contains(document.activeElement) ? document.activeElement : null;
        \\  if (submitter) submitter.disabled = true;
        \\  try {
        \\    formResult = await fetch(url.pathname + url.search, init).then(r => r.json());
        \\  } finally {
        \\    if (submitter) submitter.disabled = false;
        \\  }
        \\  await render({ restoreSnapshot: false, animate: true, scroll: 'top' });
        \\}
        \\function navigateTo(href) {
        \\  captureSnapshot();
        \\  formResult = null;
        \\  const key = newHistoryKey();
        \\  history.pushState({ ynKey: key }, '', href);
        \\  activeHistoryKey = key;
        \\  return render({ animate: true, scroll: 'top' });
        \\}
        \\document.addEventListener('submit', event => {
        \\  const form = event.target.closest && event.target.closest('form');
        \\  if (!form || (form.method || 'GET').toUpperCase() !== 'POST') return;
        \\  event.preventDefault();
        \\  submitForm(form);
        \\});
        \\document.addEventListener('pointerover', event => {
        \\  const a = event.target.closest && event.target.closest('a[href]');
        \\  if (a && a.origin === location.origin && !a.target && !a.hasAttribute('download')) prefetchRoute(new URL(a.href).pathname);
        \\});
        \\document.addEventListener('focusin', event => {
        \\  const a = event.target.closest && event.target.closest('a[href]');
        \\  if (a && a.origin === location.origin && !a.target && !a.hasAttribute('download')) prefetchRoute(new URL(a.href).pathname);
        \\});
        \\if (window.navigation && typeof window.navigation.addEventListener === 'function') {
        \\  navigation.addEventListener('navigate', event => {
        \\    if (!event.canIntercept || event.hashChange || event.downloadRequest !== null || event.formData) return;
        \\    const url = new URL(event.destination.url);
        \\    if (url.origin !== location.origin) return;
        \\    const traverse = event.navigationType === 'traverse';
        \\    event.intercept({
        \\      focusReset: 'manual',
        \\      scroll: 'manual',
        \\      handler: async () => {
        \\        if (!traverse) { captureSnapshot(); formResult = null; }
        \\        else { activeHistoryKey = ensureHistoryKey(); }
        \\        await render({ animate: true, scroll: traverse ? 'restore' : 'top' });
        \\      },
        \\    });
        \\  });
        \\} else {
        \\  document.addEventListener('click', event => {
        \\    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        \\    const a = event.target.closest && event.target.closest('a[href]');
        \\    if (!a || a.origin !== location.origin || a.target || a.hasAttribute('download')) return;
        \\    event.preventDefault();
        \\    navigateTo(a.href);
        \\  });
        \\  addEventListener('popstate', () => {
        \\    captureSnapshot();
        \\    formResult = null;
        \\    activeHistoryKey = ensureHistoryKey();
        \\    render({ animate: true, scroll: 'restore' });
        \\  });
        \\}
        \\addEventListener('pagehide', () => captureSnapshot());
        \\activeHistoryKey = ensureHistoryKey();
        \\render({ scroll: 'restore' });
        \\
        \\// routes:
    );
    try out.appendSlice(allocator, routes_json);
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

pub fn routesSource(allocator: std.mem.Allocator, routes_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "export const routes = {s};\n", .{routes_json});
}

pub const RemoteEntry = struct {
    name: []const u8,
    kind: []const u8,
};

pub fn remotesSource(allocator: std.mem.Allocator, remotes: []const RemoteEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\const queryCache = new Map();
        \\
        \\function stableKey(value) {
        \\  if (value === undefined) return 'null';
        \\  if (value === null || typeof value !== 'object') return JSON.stringify(value);
        \\  if (Array.isArray(value)) return '[' + value.map(stableKey).join(',') + ']';
        \\  return '{' + Object.keys(value).sort().map(k => JSON.stringify(k) + ':' + stableKey(value[k])).join(',') + '}';
        \\}
        \\
        \\async function callRemote(name, kind, input) {
        \\  const response = await fetch('/_yaan/remote', {
        \\    method: 'POST',
        \\    headers: { 'content-type': 'application/json;charset=UTF-8' },
        \\    body: JSON.stringify({ name, kind, input: input ?? null }),
        \\  });
        \\  const payload = await response.json();
        \\  if (!response.ok || payload.error) throw new Error(payload.message || payload.error || 'remote failed');
        \\  return payload.value;
        \\}
        \\
        \\function queryRemote(name, input) {
        \\  const key = name + ':' + stableKey(input ?? null);
        \\  let promise = queryCache.get(key);
        \\  if (!promise) {
        \\    promise = callRemote(name, 'query', input);
        \\    promise.refresh = () => {
        \\      queryCache.delete(key);
        \\      return queryRemote(name, input);
        \\    };
        \\    queryCache.set(key, promise);
        \\  }
        \\  return promise;
        \\}
        \\
        \\function commandRemote(name, input) {
        \\  return callRemote(name, 'command', input);
        \\}
        \\
    );
    for (remotes) |remote| {
        const name_lit = try jsString(allocator, remote.name);
        defer allocator.free(name_lit);
        if (std.mem.eql(u8, remote.kind, "query")) {
            try out.print(allocator,
                \\export function {s}(input) {{ return queryRemote({s}, input); }}
                \\{s}.refresh = (input) => {{
                \\  queryCache.delete({s} + ':' + stableKey(input ?? null));
                \\  return queryRemote({s}, input);
                \\}};
                \\
            , .{ remote.name, name_lit, remote.name, name_lit, name_lit });
        } else {
            try out.print(allocator,
                \\export function {s}(input) {{ return commandRemote({s}, input); }}
                \\
            , .{ remote.name, name_lit });
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const HtmlOptions = struct {
    /// Document <title>. Already-escaped plain text.
    title: []const u8 = "Yaan App",
    /// Prerendered static skeleton inlined into #app. Empty for a pure SPA shell.
    app_html: []const u8 = "",
    /// Optional meta description.
    description: []const u8 = "",
    /// Stylesheet href. Content-hashed in real builds so it can be cached immutably.
    stylesheet: []const u8 = "/style.css",
};

/// Renders the HTML document shell. When `app_html` is non-empty the page is a
/// prerendered skeleton the client hydrates in place; otherwise #app is empty
/// and the client renders from scratch. The lang attribute, modulepreload hints,
/// and the aria-live region are always present.
pub fn htmlSource(allocator: std.mem.Allocator, opts: HtmlOptions) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const title = try escapeHtml(allocator, opts.title);
    defer allocator.free(title);
    const description = try escapeHtml(allocator, opts.description);
    defer allocator.free(description);
    const stylesheet = try escapeHtml(allocator, opts.stylesheet);
    defer allocator.free(stylesheet);
    const prerendered = if (opts.app_html.len > 0) "true" else "false";
    try out.print(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <meta name="description" content="{s}">
        \\  <meta name="theme-color" content="#1f6feb">
        \\  <link rel="stylesheet" href="{s}">
        \\  <link rel="modulepreload" href="/runtime.js">
        \\  <link rel="modulepreload" href="/routes.js">
        \\  <link rel="modulepreload" href="/app.js">
        \\  <title>{s}</title>
        \\</head>
        \\<body>
        \\  <div id="app" tabindex="-1" data-yaan-prerendered="{s}">{s}</div>
        \\  <div id="yaan-live" class="yaan-sr-only" aria-live="polite" aria-atomic="true"></div>
        \\  <script type="module" src="/app.js"></script>
        \\</body>
        \\</html>
        \\
    , .{ description, stylesheet, title, prerendered, opts.app_html });
    return out.toOwnedSlice(allocator);
}

/// HTML-escapes text for safe inclusion in element content or double-quoted
/// attribute values.
pub fn escapeHtml(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |c| switch (c) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '"' => try out.appendSlice(allocator, "&quot;"),
        '\'' => try out.appendSlice(allocator, "&#39;"),
        else => try out.append(allocator, c),
    };
    return out.toOwnedSlice(allocator);
}

/// Base stylesheet prepended to every app's bundle: the visually-hidden
/// utility used by the route-change live region, plus sensible view-transition
/// defaults for SPA navigation.
pub fn baseCss() []const u8 {
    return
        \\.yaan-sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0;}
        \\@media (prefers-reduced-motion: reduce){::view-transition-group(*),::view-transition-old(*),::view-transition-new(*){animation:none !important;}}
        \\
    ;
}

fn emitNodes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ctx: *EmitContext, nodes: []const parser.Node, parent: []const u8, scope: []const u8, indent: []const u8) anyerror!void {
    for (nodes) |node| {
        const name = try ctx.nodeName(allocator);
        defer allocator.free(name);
        switch (node) {
            .text => |value| if (std.mem.trim(u8, value, " \t\r\n").len > 0) {
                const lit = try jsString(allocator, value);
                defer allocator.free(lit);
                try out.print(allocator, "{s}mount({s}, document.createTextNode({s}));\n", .{ indent, parent, lit });
            },
            .interpolation => |expr| {
                try out.print(allocator, "{s}const {s} = text({s}, ({s}));\n", .{ indent, name, parent, expr });
                try out.print(allocator, "{s}disposers.push($effect(() => {s}.update(({s}))));\n", .{ indent, name, expr });
            },
            .element => |elem| try emitElement(allocator, out, ctx, elem, parent, scope, indent, name),
            .if_block => |ifb| try emitIf(allocator, out, ctx, ifb, parent, scope, indent, name),
            .each_block => |each| try emitEach(allocator, out, ctx, each, parent, scope, indent, name),
        }
    }
}

fn emitElement(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ctx: *EmitContext, elem: parser.Element, parent: []const u8, scope: []const u8, indent: []const u8, name: []const u8) anyerror!void {
    const elem_name = try jsString(allocator, elem.name);
    defer allocator.free(elem_name);
    const scope_name = try jsString(allocator, scope);
    defer allocator.free(scope_name);
    try out.print(allocator, "{s}const {s} = document.createElement({s});\n", .{ indent, name, elem_name });
    try out.print(allocator, "{s}{s}.setAttribute({s}, '');\n", .{ indent, name, scope_name });
    try emitAttrs(allocator, out, elem, name, indent);
    try out.print(allocator, "{s}mount({s}, {s});\n", .{ indent, parent, name });
    try emitNodes(allocator, out, ctx, elem.children, name, scope, indent);
}

/// Emits attribute/event wiring shared by create() and hydrate(): event
/// listeners, expression-valued attributes, and static attributes. Setting
/// static attributes is idempotent, so it is safe on an adopted element too.
fn emitAttrs(allocator: std.mem.Allocator, out: *std.ArrayList(u8), elem: parser.Element, name: []const u8, indent: []const u8) anyerror!void {
    for (elem.attrs) |attr| {
        if (std.mem.startsWith(u8, attr.name, "on:")) {
            const event = attr.name[3..];
            const handler = attr.value orelse "";
            const event_name = try jsString(allocator, event);
            defer allocator.free(event_name);
            try out.print(allocator, "{s}{s}.addEventListener({s}, ({s}));\n", .{ indent, name, event_name, handler });
            try out.print(allocator, "{s}disposers.push(() => {s}.replaceWith({s}.cloneNode(true)));\n", .{ indent, name, name });
        } else if (attr.value) |value| {
            const attr_name = try jsString(allocator, attr.name);
            defer allocator.free(attr_name);
            if (attr.expression) {
                try out.print(allocator, "{s}{s}.setAttribute({s}, ({s}));\n", .{ indent, name, attr_name, value });
            } else {
                const attr_value = try jsString(allocator, value);
                defer allocator.free(attr_value);
                try out.print(allocator, "{s}{s}.setAttribute({s}, {s});\n", .{ indent, name, attr_name, attr_value });
            }
        } else {
            const attr_name = try jsString(allocator, attr.name);
            defer allocator.free(attr_name);
            try out.print(allocator, "{s}{s}.setAttribute({s}, '');\n", .{ indent, name, attr_name });
        }
    }
}

fn emitIf(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ctx: *EmitContext, ifb: parser.IfBlock, parent: []const u8, scope: []const u8, indent: []const u8, name: []const u8) anyerror!void {
    try out.print(allocator, "{s}const {s} = document.createComment('if'); mount({s}, {s});\n", .{ indent, name, parent, name });
    try out.print(allocator, "{s}disposers.push($effect(() => {{\n{s}  const frag = document.createDocumentFragment();\n", .{ indent, indent });
    if (ifb.then_children.len > 0) {
        try out.print(allocator, "{s}  if ({s}) {{\n", .{ indent, ifb.condition });
        try emitNodes(allocator, out, ctx, ifb.then_children, "frag", scope, "    ");
        if (ifb.else_children.len > 0) {
            try out.print(allocator, "{s}  }} else {{\n", .{indent});
            try emitNodes(allocator, out, ctx, ifb.else_children, "frag", scope, "    ");
        }
        try out.print(allocator, "{s}  }}\n", .{indent});
    }
    try out.print(allocator, "{s}  {s}.parentNode.insertBefore(frag, {s});\n{s}}}));\n", .{ indent, name, name, indent });
}

fn emitEach(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ctx: *EmitContext, each: parser.EachBlock, parent: []const u8, scope: []const u8, indent: []const u8, name: []const u8) anyerror!void {
    try out.print(allocator, "{s}const {s} = document.createComment('each'); mount({s}, {s});\n", .{ indent, name, parent, name });
    try out.print(allocator, "{s}const {s}State = {s};\n", .{ indent, name, if (each.key != null) "{ blocks: new Map() }" else "{ blocks: [] }" });
    try out.print(allocator, "{s}disposers.push($effect(() => {{\n", .{indent});
    if (each.key) |key| {
        try out.print(allocator, "{s}  reconcileKeyed({s}, {s}State, ({s}), ({s}, {s}) => ({s}), ({s}, {s}) => {{\n", .{ indent, name, name, each.expression, each.item, each.index orelse "_i", key, each.item, each.index orelse "_i" });
    } else {
        try out.print(allocator, "{s}  reconcileIndexed({s}, {s}State, ({s}), ({s}, {s}) => {{\n", .{ indent, name, name, each.expression, each.item, each.index orelse "_i" });
    }
    try out.print(allocator, "{s}    const fragment = document.createDocumentFragment();\n", .{indent});
    try emitNodes(allocator, out, ctx, each.children, "fragment", scope, "    ");
    try out.print(allocator, "{s}    return {{ fragment, destroy() {{ clear(fragment); }} }};\n{s}  }});\n{s}}}));\n", .{ indent, indent, indent });
}

// --- hydrate(): adopt prerendered DOM via a cursor instead of building fresh ---
//
// Top-level and static-element children are adopted node-by-node. Dynamic
// regions ({#if}/{#each}) are never prerendered, so their bodies fall back to
// the create()-mode emitters that build fresh into a fragment.

fn emitHydrateNodes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ctx: *EmitContext, nodes: []const parser.Node, cursor: []const u8, scope: []const u8, indent: []const u8) anyerror!void {
    for (nodes) |node| {
        const name = try ctx.nodeName(allocator);
        defer allocator.free(name);
        switch (node) {
            .text => |value| if (std.mem.trim(u8, value, " \t\r\n").len > 0) {
                const lit = try jsString(allocator, value);
                defer allocator.free(lit);
                try out.print(allocator, "{s}hydrateText({s}, {s});\n", .{ indent, cursor, lit });
            },
            .interpolation => |expr| {
                try out.print(allocator, "{s}const {s} = hydrateInterp({s}, ({s}));\n", .{ indent, name, cursor, expr });
                try out.print(allocator, "{s}disposers.push($effect(() => {s}.update(({s}))));\n", .{ indent, name, expr });
            },
            .element => |elem| try emitHydrateElement(allocator, out, ctx, elem, cursor, scope, indent, name),
            .if_block => |ifb| try emitHydrateIf(allocator, out, ctx, ifb, cursor, scope, indent, name),
            .each_block => |each| try emitHydrateEach(allocator, out, ctx, each, cursor, scope, indent, name),
        }
    }
}

fn emitHydrateElement(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ctx: *EmitContext, elem: parser.Element, cursor: []const u8, scope: []const u8, indent: []const u8, name: []const u8) anyerror!void {
    const elem_name = try jsString(allocator, elem.name);
    defer allocator.free(elem_name);
    const scope_name = try jsString(allocator, scope);
    defer allocator.free(scope_name);
    try out.print(allocator, "{s}const {s} = hydrateElement({s}, {s});\n", .{ indent, name, cursor, elem_name });
    try out.print(allocator, "{s}{s}.setAttribute({s}, '');\n", .{ indent, name, scope_name });
    try emitAttrs(allocator, out, elem, name, indent);
    if (!isVoidElement(elem.name) and elem.children.len > 0) {
        const child_cursor = try ctx.cursorName(allocator);
        defer allocator.free(child_cursor);
        try out.print(allocator, "{s}const {s} = hydrateCursor({s});\n", .{ indent, child_cursor, name });
        try emitHydrateNodes(allocator, out, ctx, elem.children, child_cursor, scope, indent);
    }
}

fn emitHydrateIf(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ctx: *EmitContext, ifb: parser.IfBlock, cursor: []const u8, scope: []const u8, indent: []const u8, name: []const u8) anyerror!void {
    try out.print(allocator, "{s}const {s} = hydrateComment({s}, 'if');\n", .{ indent, name, cursor });
    try out.print(allocator, "{s}disposers.push($effect(() => {{\n{s}  const frag = document.createDocumentFragment();\n", .{ indent, indent });
    if (ifb.then_children.len > 0) {
        try out.print(allocator, "{s}  if ({s}) {{\n", .{ indent, ifb.condition });
        try emitNodes(allocator, out, ctx, ifb.then_children, "frag", scope, "    ");
        if (ifb.else_children.len > 0) {
            try out.print(allocator, "{s}  }} else {{\n", .{indent});
            try emitNodes(allocator, out, ctx, ifb.else_children, "frag", scope, "    ");
        }
        try out.print(allocator, "{s}  }}\n", .{indent});
    }
    try out.print(allocator, "{s}  {s}.parentNode.insertBefore(frag, {s});\n{s}}}));\n", .{ indent, name, name, indent });
}

fn emitHydrateEach(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ctx: *EmitContext, each: parser.EachBlock, cursor: []const u8, scope: []const u8, indent: []const u8, name: []const u8) anyerror!void {
    try out.print(allocator, "{s}const {s} = hydrateComment({s}, 'each');\n", .{ indent, name, cursor });
    try out.print(allocator, "{s}const {s}State = {s};\n", .{ indent, name, if (each.key != null) "{ blocks: new Map() }" else "{ blocks: [] }" });
    try out.print(allocator, "{s}disposers.push($effect(() => {{\n", .{indent});
    if (each.key) |key| {
        try out.print(allocator, "{s}  reconcileKeyed({s}, {s}State, ({s}), ({s}, {s}) => ({s}), ({s}, {s}) => {{\n", .{ indent, name, name, each.expression, each.item, each.index orelse "_i", key, each.item, each.index orelse "_i" });
    } else {
        try out.print(allocator, "{s}  reconcileIndexed({s}, {s}State, ({s}), ({s}, {s}) => {{\n", .{ indent, name, name, each.expression, each.item, each.index orelse "_i" });
    }
    try out.print(allocator, "{s}    const fragment = document.createDocumentFragment();\n", .{indent});
    try emitNodes(allocator, out, ctx, each.children, "fragment", scope, "    ");
    try out.print(allocator, "{s}    return {{ fragment, destroy() {{ clear(fragment); }} }};\n{s}  }});\n{s}}}));\n", .{ indent, indent, indent });
}

// --- prerender: static HTML skeleton inlined into #app for hydration ---
//
// Emits compact HTML (no inter-element whitespace, mirroring create()/hydrate()
// which skip whitespace-only text). Interpolations emit nothing; {#if}/{#each}
// emit only their comment anchor since their content needs runtime data.

fn prerenderNodes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), nodes: []const parser.Node, scope: []const u8) anyerror!void {
    for (nodes) |node| {
        switch (node) {
            .text => |value| if (std.mem.trim(u8, value, " \t\r\n").len > 0) {
                const escaped = try escapeHtml(allocator, value);
                defer allocator.free(escaped);
                try out.appendSlice(allocator, escaped);
            },
            .interpolation => {},
            .element => |elem| try prerenderElement(allocator, out, elem, scope),
            .if_block => try out.appendSlice(allocator, "<!--if-->"),
            .each_block => try out.appendSlice(allocator, "<!--each-->"),
        }
    }
}

fn prerenderElement(allocator: std.mem.Allocator, out: *std.ArrayList(u8), elem: parser.Element, scope: []const u8) anyerror!void {
    try out.print(allocator, "<{s} {s}=\"\"", .{ elem.name, scope });
    for (elem.attrs) |attr| {
        // Only static attributes are known at build time; events and expression
        // attributes are applied during hydration.
        if (std.mem.startsWith(u8, attr.name, "on:")) continue;
        if (attr.expression) continue;
        if (attr.value) |value| {
            const escaped = try escapeHtml(allocator, value);
            defer allocator.free(escaped);
            try out.print(allocator, " {s}=\"{s}\"", .{ attr.name, escaped });
        } else {
            try out.print(allocator, " {s}=\"\"", .{attr.name});
        }
    }
    if (isVoidElement(elem.name)) {
        try out.append(allocator, '>');
        return;
    }
    try out.append(allocator, '>');
    try prerenderNodes(allocator, out, elem.children, scope);
    try out.print(allocator, "</{s}>", .{elem.name});
}

fn isVoidElement(name: []const u8) bool {
    const void_elements = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" };
    for (void_elements) |v| {
        if (std.ascii.eqlIgnoreCase(name, v)) return true;
    }
    return false;
}

fn jsString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(allocator, '\'');
    for (value) |c| switch (c) {
        '\'' => try out.appendSlice(allocator, "\\'"),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        else => try out.append(allocator, c),
    };
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

test "codegen emits events and keyed reconciliation" {
    var component = try parser.parse(std.testing.allocator,
        \\<script>const items = $signal([{id: 1}]);</script>
        \\{#each items.read() as item (item.id)}<button on:click={() => item.id}>{item.id}</button>{/each}
    );
    defer parser.deinitComponent(&component, std.testing.allocator);
    const generated = try generateComponent(std.testing.allocator, "src/routes/+page.yn", component);
    defer {
        std.testing.allocator.free(generated.js);
        std.testing.allocator.free(generated.css);
        std.testing.allocator.free(generated.scope);
        std.testing.allocator.free(generated.prerender);
    }
    try std.testing.expect(std.mem.indexOf(u8, generated.js, "addEventListener('click'") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.js, "reconcileKeyed") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.js, "snapshot: typeof snapshot !== 'undefined'") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.js, "import { asset } from '../assets.js';") != null);
}

test "component emits create, hydrate and a static prerender skeleton" {
    var component = try parser.parse(std.testing.allocator,
        \\<main><h1>Title {value.read()}</h1>{#if show.read()}<p>yes</p>{/if}<img src={asset("x.svg")} alt="logo" /></main>
    );
    defer parser.deinitComponent(&component, std.testing.allocator);
    const generated = try generateComponent(std.testing.allocator, "src/routes/+page.yn", component);
    defer {
        std.testing.allocator.free(generated.js);
        std.testing.allocator.free(generated.css);
        std.testing.allocator.free(generated.scope);
        std.testing.allocator.free(generated.prerender);
    }
    // Both entrypoints are generated.
    try std.testing.expect(std.mem.indexOf(u8, generated.js, "export function create(target") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.js, "export function hydrate(target") != null);
    // Hydrate adopts via cursor helpers rather than createElement.
    try std.testing.expect(std.mem.indexOf(u8, generated.js, "hydrateElement(") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.js, "hydrateInterp(") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.js, "hydrateComment(") != null);
    // Prerender: static text + element kept, interpolation dropped, void <img> has no closing tag,
    // expression src omitted, {#if} reduced to its anchor comment.
    try std.testing.expect(std.mem.indexOf(u8, generated.prerender, "<main ") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.prerender, "<h1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.prerender, "Title ") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.prerender, "<!--if-->") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.prerender, "alt=\"logo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.prerender, "src=") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.prerender, "</img>") == null);
}

test "runtime exposes explicit state primitives" {
    const runtime = runtimeSource();
    try std.testing.expect(std.mem.indexOf(u8, runtime, "export function $signal") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "signal.read") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "signal.write") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "export function $memo") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "export function $resource") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "export const $state = $signal") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "export const $derived = $memo") != null);
}

test "html shell carries lang, modulepreload, live region and escapes title" {
    const empty = try htmlSource(std.testing.allocator, .{});
    defer std.testing.allocator.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "<html lang=\"en\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "rel=\"modulepreload\" href=\"/app.js\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "id=\"yaan-live\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "aria-live=\"polite\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "data-yaan-prerendered=\"false\"") != null);

    const filled = try htmlSource(std.testing.allocator, .{ .title = "A & B <x>", .app_html = "<main></main>" });
    defer std.testing.allocator.free(filled);
    try std.testing.expect(std.mem.indexOf(u8, filled, "<title>A &amp; B &lt;x&gt;</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, filled, "data-yaan-prerendered=\"true\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, filled, ">    <main></main></div>") == null); // skeleton inlined verbatim
    try std.testing.expect(std.mem.indexOf(u8, filled, "<main></main>") != null);
}

test "app router emits opt-in snapshot persistence" {
    const app = try appSource(std.testing.allocator, "[]");
    defer std.testing.allocator.free(app);
    try std.testing.expect(std.mem.indexOf(u8, app, "function captureSnapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, app, "function restoreSnapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, app, "sessionStorage.setItem") != null);
    try std.testing.expect(std.mem.indexOf(u8, app, "history.pushState({ ynKey: key }") != null);
}

test "app router adopts modern navigation, a11y and performance patterns" {
    const app = try appSource(std.testing.allocator, "[]");
    defer std.testing.allocator.free(app);
    // P2.1 parallel load + import
    try std.testing.expect(std.mem.indexOf(u8, app, "Promise.all([") != null);
    // P3.1 view transitions
    try std.testing.expect(std.mem.indexOf(u8, app, "document.startViewTransition") != null);
    // P3.2 Navigation API with fallback
    try std.testing.expect(std.mem.indexOf(u8, app, "navigation.addEventListener('navigate'") != null);
    try std.testing.expect(std.mem.indexOf(u8, app, "event.intercept(") != null);
    // P1.3 focus + live-region announce
    try std.testing.expect(std.mem.indexOf(u8, app, "function announce(") != null);
    try std.testing.expect(std.mem.indexOf(u8, app, "outlet.focus(") != null);
    // P1.4 scroll restoration
    try std.testing.expect(std.mem.indexOf(u8, app, "history.scrollRestoration = 'manual'") != null);
    // P2.3 prefetch on intent
    try std.testing.expect(std.mem.indexOf(u8, app, "function prefetchRoute(") != null);
    // P2.2 hydration hook
    try std.testing.expect(std.mem.indexOf(u8, app, "mod.hydrate(outlet, props)") != null);
}
