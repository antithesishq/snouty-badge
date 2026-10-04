// js_oracle.mjs: runs the original Universal Paperclips JS (reference/*.js,
// unchanged) headless in a Node `vm` context and replays an action script on
// it. It is the "truth" side of the oracle (PLAN.md, track O; SPEC.md
// section 5 is the determinism contract):
//
//   - Math.random is the SPEC RNG (xorshift64*, BigInt, exact).
//   - setInterval/setTimeout are a virtual millisecond clock. At each ms the
//     due timers fire in registration order; an interval fires at t0 + k*P.
//   - The DOM is a stub built from index2.html: every element with an id
//     exists (getElementById returns null for anything else, as a browser
//     would), elements created by the game and attached get registered, and
//     style/disabled/innerHTML/value are recorded so the oracle can tell
//     whether a button is visible and enabled.
//   - localStorage keeps only "savePrestige" (the badge keeps prestige for
//     the session, never a save game), so the game always starts fresh.
//   - No audio, no hover (revealGrid/revealResults are never triggered).
//
// Actions (script verbs) map to the original onclick handlers; a click
// applies only when the button is visible (no ancestor display:none, not
// visibility:hidden) and not disabled, like a real click. Select/range
// changes set the element's value (a string, as in the browser).
//
// CLI:  node js_oracle.mjs SCRIPT.json [-o OUT.json] [--every MS]
//                          [--from MS] [--to MS] [--fields FIELDS.txt]
// Library: import { Oracle, loadScript, runScript } from "./js_oracle.mjs".

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REF = path.resolve(HERE, "../reference");
const SCRIPTS = ["combat.js", "globals.js", "projects.js", "main.js"];

// ---------------------------------------------------------------- RNG ----

const MASK64 = (1n << 64n) - 1n;

export class Rng {
  constructor(seed) {
    let s = BigInt.asUintN(64, BigInt(seed));
    if (s === 0n) throw new Error("seed must be nonzero");
    this.x = s;
    this.calls = 0;
  }
  next() {
    let x = this.x;
    x ^= x >> 12n;
    x ^= (x << 25n) & MASK64;
    x ^= x >> 27n;
    this.x = x;
    this.calls++;
    const r = (x * 0x2545f4914f6cdd1dn) & MASK64;
    return Number(r >> 11n) * 2 ** -53;
  }
}

// ---------------------------------------------------------- HTML tree ----

const VOID_TAGS = new Set(["br", "hr", "input", "img", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr"]);
const CLOSES_P = new Set(["div", "p", "table", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "hr", "form", "pre", "blockquote"]);

// Minimal tolerant parser: returns [{tag, attrs, parent(index|-1)}].
function parseHtml(src) {
  const nodes = [];
  const stack = []; // indices into nodes
  const re = /<!--[\s\S]*?-->|<\/\s*([a-zA-Z0-9]+)\s*>|<([a-zA-Z0-9]+)((?:[^>"']|"[^"]*"|'[^']*')*)>/g;
  let m;
  while ((m = re.exec(src))) {
    if (m[0].startsWith("<!--")) continue;
    if (m[1]) {
      const tag = m[1].toLowerCase();
      for (let i = stack.length - 1; i >= 0; i--) {
        if (nodes[stack[i]].tag === tag) {
          stack.length = i;
          break;
        }
      }
      continue;
    }
    const tag = m[2].toLowerCase();
    if (CLOSES_P.has(tag)) {
      for (let i = stack.length - 1; i >= 0; i--) {
        const t = nodes[stack[i]].tag;
        if (t === "p") { stack.length = i; break; }
        if (t === "div" || t === "td" || t === "th" || t === "button" || t === "body") break;
      }
    }
    const attrs = {};
    const are = /([a-zA-Z_:-][a-zA-Z0-9_:.-]*)\s*(?:=\s*("[^"]*"|'[^']*'|[^\s>"']+))?/g;
    let a;
    while ((a = are.exec(m[3]))) {
      let v = a[2] === undefined ? "" : a[2];
      if (v[0] === '"' || v[0] === "'") v = v.slice(1, -1);
      attrs[a[1].toLowerCase()] = v;
    }
    const idx = nodes.length;
    nodes.push({ tag, attrs, parent: stack.length ? stack[stack.length - 1] : -1 });
    if (!VOID_TAGS.has(tag) && !m[3].trim().endsWith("/")) stack.push(idx);
  }
  return nodes;
}

// ----------------------------------------------------------- DOM stub ----

class Style {
  constructor() {
    this._display = "";
    this._visibility = "";
    this._touched = false; // display (or visibility) ever set by the game
    this.opacity = "";
    this.fontWeight = "";
    this.backgroundColor = "";
  }
  get display() { return this._display; }
  set display(v) { this._display = String(v); this._touched = true; }
  get visibility() { return this._visibility; }
  set visibility(v) { this._visibility = String(v); this._touched = true; }
}

const noop = () => {};
const CTX2D = new Proxy({}, {
  get(_t, k) { return k === "canvas" ? null : noop; },
  set() { return true; },
});

class El {
  constructor(doc, tag) {
    this._doc = doc;
    this.tagName = tag.toUpperCase();
    this.id = "";
    this.style = new Style();
    this.innerHTML = "";
    this.textContent = "";
    this.disabled = false;
    this._value = "";
    this.parentNode = null;
    this.childNodes = [];
    this.attrs = {};
    this.onclick = null;
    this.onmouseover = null;
    this.onmouseout = null;
    this.width = 300;
    this.height = 150;
    this.classList = { add: noop, remove: noop, toggle: noop, contains: () => false };
  }
  get firstChild() { return this.childNodes[0] || null; }
  get value() {
    if (this.tagName === "SELECT") return this._value;
    return this._value;
  }
  set value(v) {
    if (this.tagName === "SELECT") {
      const s = String(v);
      this._value = this.childNodes.some((o) => o.tagName === "OPTION" && String(o.value) === s) ? s : "";
    } else if (this.tagName === "INPUT") {
      this._value = String(v);
    } else {
      this._value = v;
    }
  }
  get _connected() {
    let e = this;
    while (e) {
      if (e === this._doc._root) return true;
      e = e.parentNode;
    }
    return false;
  }
  setAttribute(name, val) {
    this.attrs[name] = String(val);
    if (name === "id") this.id = String(val);
  }
  getAttribute(name) { return name in this.attrs ? this.attrs[name] : null; }
  appendChild(child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    child.parentNode = this;
    this.childNodes.push(child);
    if (this._connected) this._doc._register(child);
    return child;
  }
  insertBefore(child, ref) {
    if (child.parentNode) child.parentNode.removeChild(child);
    child.parentNode = this;
    const i = ref ? this.childNodes.indexOf(ref) : -1;
    if (i < 0) this.childNodes.push(child); else this.childNodes.splice(i, 0, child);
    if (this._connected) this._doc._register(child);
    return child;
  }
  removeChild(child) {
    const i = this.childNodes.indexOf(child);
    if (i < 0) throw new Error("removeChild: not a child");
    this.childNodes.splice(i, 1);
    child.parentNode = null;
    this._doc._unregister(child);
    return child;
  }
  getContext() { return CTX2D; }
  addEventListener() {}
  removeEventListener() {}
  // Rendered and clickable: no ancestor with display:none, no
  // visibility:hidden on the way up (the blink hides new projects).
  get _visible() {
    if (!this._connected) return false;
    let e = this;
    while (e && e !== this._doc._root) {
      if (e.style.display === "none") return false;
      if (e.style.visibility === "hidden") return false;
      e = e.parentNode;
    }
    return true;
  }
}

class TextNode {
  constructor(t) { this.textContent = String(t); this.parentNode = null; this.childNodes = []; this.tagName = "#text"; this.id = ""; }
}

class Doc {
  constructor(html) {
    this._byId = new Map();
    this._root = new El(this, "html");
    this.body = this._root;
    const nodes = parseHtml(html);
    const els = [];
    for (const n of nodes) {
      const el = new El(this, n.tag);
      for (const [k, v] of Object.entries(n.attrs)) el.attrs[k] = v;
      if (n.attrs.id !== undefined) el.id = n.attrs.id;
      if (n.attrs.onclick !== undefined) el._onclickSrc = n.attrs.onclick;
      if (n.tag === "option") el._value = n.attrs.value !== undefined ? n.attrs.value : "";
      const parent = n.parent >= 0 ? els[n.parent] : this._root;
      el.parentNode = parent;
      parent.childNodes.push(el);
      els.push(el);
    }
    for (const el of els) {
      if (el.tagName === "SELECT") {
        const opts = el.childNodes.filter((o) => o.tagName === "OPTION");
        el._value = opts.length ? opts[0]._value : "";
      } else if (el.tagName === "INPUT") {
        el._value = el.attrs.value !== undefined ? el.attrs.value : "";
      }
      if (el.id && !this._byId.has(el.id)) this._byId.set(el.id, el);
    }
    this._byOnclick = new Map();
    for (const el of els) if (el._onclickSrc) this._byOnclick.set(el._onclickSrc.replace(/\s+/g, ""), el);
  }
  _register(el) {
    if (el.id && !this._byId.has(el.id)) this._byId.set(el.id, el);
    for (const c of el.childNodes || []) if (c instanceof El) this._register(c);
  }
  _unregister(el) {
    if (el.id && this._byId.get(el.id) === el) this._byId.delete(el.id);
    for (const c of el.childNodes || []) if (c instanceof El) this._unregister(c);
  }
  getElementById(id) { return this._byId.get(String(id)) || null; }
  createElement(tag) { return new El(this, tag); }
  createTextNode(t) { return new TextNode(t); }
  getElementsByClassName() { return []; }
  getElementsByTagName() { return []; }
  querySelector() { return null; }
  addEventListener() {}
}

// ------------------------------------------------------------- clock ----

class Clock {
  constructor() {
    this.now = 0;
    this.seq = 0;
    this.timers = new Map(); // id -> {id, due, period, fn}
  }
  add(fn, delay, period) {
    if (typeof fn !== "function") throw new Error("string timers are not supported");
    let d = Math.floor(Number(delay) || 0);
    if (d < 1) d = 1; // the game never uses 0; keep time moving
    const id = ++this.seq;
    this.timers.set(id, { id, due: this.now + d, period: period ? d : 0, fn });
    return id;
  }
  clear(id) { this.timers.delete(id); }
  clearAll() { this.timers.clear(); }
  // The next timer due at or before `limit`, by (due, id).
  nextDue(limit) {
    let best = null;
    for (const t of this.timers.values()) {
      if (t.due > limit) continue;
      if (!best || t.due < best.due || (t.due === best.due && t.id < best.id)) best = t;
    }
    return best;
  }
}

// ------------------------------------------------------------ actions ----

// Script verb -> how to perform it. `click` names the original onclick
// attribute text (whitespace-insensitive) of the button in index2.html.
const PROBE_STATS = ["speed", "nav", "rep", "haz", "fac", "harv", "wire", "combat"];
const cap = (s) => s[0].toUpperCase() + s.slice(1);

export const ACTIONS = {
  make_paperclip: { click: "clipClick(1)" },
  lower_price: { click: "lowerPrice()" },
  raise_price: { click: "raisePrice()" },
  buy_ads: { click: "buyAds()" },
  toggle_wire_buyer: { click: "toggleWireBuyer()" },
  buy_wire: { click: "buyWire()" },
  make_clipper: { click: "makeClipper()" },
  make_mega_clipper: { click: "makeMegaClipper()" },
  add_proc: { click: "addProc()" },
  add_mem: { click: "addMem()" },
  q_compute: { click: "qComp()" },
  buy_project: { project: true },
  invest_deposit: { click: "investDeposit()" },
  invest_withdraw: { click: "investWithdraw()" },
  invest_upgrade: { click: "investUpgrade()" },
  set_invest_strat: { select: "investStrat", values: ["low", "med", "hi"] },
  set_strat_pick: { select: "stratPicker" },
  run_tourney: { click: "runTourney()" },
  new_tourney: { click: "newTourney()" },
  toggle_auto_tourney: { click: "toggleAutoTourney()" },
  make_factory: { click: "makeFactory()" },
  factory_reboot: { click: "factoryReboot()" },
  make_harvester: { clickN: (n) => `makeHarvester(${n})`, ns: [1, 10, 100, 1000] },
  harvester_reboot: { click: "harvesterReboot()" },
  make_wire_drone: { clickN: (n) => `makeWireDrone(${n})`, ns: [1, 10, 100, 1000] },
  wire_drone_reboot: { click: "wireDroneReboot()" },
  make_farm: { clickN: (n) => `makeFarm(${n})`, ns: [1, 10, 100] },
  farm_reboot: { click: "farmReboot()" },
  make_battery: { clickN: (n) => `makeBattery(${n})`, ns: [1, 10, 100] },
  battery_reboot: { click: "batteryReboot()" },
  entertain_swarm: { click: "entertainSwarm()" },
  synch_swarm: { click: "synchSwarm()" },
  set_slider: { range: "slider", min: 0, max: 200 },
  make_probe: { click: "makeProbe()" },
  probe_stat_up: { clickStat: (s) => `raiseProbe${cap(s)}()` },
  probe_stat_down: { clickStat: (s) => `lowerProbe${cap(s)}()` },
  increase_probe_trust: { click: "increaseProbeTrust()" },
  increase_max_trust: { click: "increaseMaxTrust()" },
  cheat_clips: { click: "cheatClips()" },
  cheat_money: { click: "cheatMoney()" },
  cheat_trust: { click: "cheatTrust()" },
  cheat_ops: { click: "cheatOps()" },
  cheat_creat: { click: "cheatCreat()" },
  cheat_yomi: { click: "cheatYomi()" },
  cheat_hypno: { click: "cheatHypno()" },
  cheat_prestige_u: { click: "cheatPrestigeU()" },
  cheat_prestige_s: { click: "cheatPrestigeS()" },
  reset_prestige: { click: "resetPrestige()" },
  set_battle_number: { click: "setB()" },
  zero_matter: { click: "zeroMatter()" },
  reset_all: { click: "reset()" },
  // Mouse over / out of the tournament box (onmouseover is set by
  // buttonUpdate every tick).
  reveal_grid: { hover: "tournamentStuff", call: "revealGrid()" },
  reveal_results: { hover: "tournamentStuff", call: "revealResults()" },
};

// --------------------------------------------------------------- page ----

const SOURCES = SCRIPTS.map((f) => new vm.Script(fs.readFileSync(path.join(REF, f), "utf8"), { filename: f }));
const HTML = fs.readFileSync(path.join(REF, "index2.html"), "utf8");

export class Oracle {
  constructor(seed, opts = {}) {
    this.rng = new Rng(seed);
    this.clock = new Clock();
    this.messages = []; // [ms, text]
    this.errors = []; // [ms, where, text]
    this.storage = new Map(); // only savePrestige survives
    this.reloads = 0;
    this.log = opts.log || null;
    this._load();
  }

  _load() {
    const self = this;
    this.clock.clearAll();
    this.doc = new Doc(HTML);
    this._reloadPending = false;
    const storage = {
      getItem: (k) => (k === "savePrestige" && self.storage.has(k) ? self.storage.get(k) : null),
      setItem: (k, v) => { if (k === "savePrestige") self.storage.set(k, String(v)); },
      removeItem: (k) => { self.storage.delete(k); },
      clear: () => self.storage.clear(),
    };
    const sandbox = {
      document: this.doc,
      localStorage: storage,
      console: { log: noop, warn: noop, error: noop, info: noop },
      setInterval: (fn, d) => self.clock.add(fn, d, true),
      setTimeout: (fn, d) => self.clock.add(fn, d, false),
      clearInterval: (id) => self.clock.clear(id),
      clearTimeout: (id) => self.clock.clear(id),
      Audio: class { constructor() { this.src = ""; } addEventListener() {} play() {} pause() {} },
      location: { reload: () => { self._reloadPending = true; } },
      confirm: () => true,
      alert: noop,
      navigator: { userAgent: "oracle" },
      __rng: () => self.rng.next(),
    };
    // An ordinary (not contextified) global object: global variable access
    // in the game is then as fast as in a browser (the combat canvas sim
    // moves 400 ships every 16 ms and is the oracle's hot loop).
    this.ctx = vm.createContext(vm.constants.DONT_CONTEXTIFY);
    Object.assign(this.ctx, sandbox);
    this.ctx.window = this.ctx;
    this.ctx.self = this.ctx;
    vm.runInContext(`
      Math.random = __rng;
      (function () {
        // en-US whatever the host locale; formatters cached (creating
        // one per call was half the oracle's run time).
        const cache = new Map();
        Number.prototype.toLocaleString = function (loc, opts) {
          const key = loc === undefined && opts === undefined ? "" :
            (loc === undefined ? "en-US" : String(loc)) + JSON.stringify(opts || {});
          let f = cache.get(key);
          if (!f) { f = new Intl.NumberFormat(loc === undefined ? "en-US" : loc, opts); cache.set(key, f); }
          return f.format(Number(this));
        };
      })();
    `, this.ctx);
    // Record every console message (displayMessage), keeping the original.
    SOURCES.forEach((s, i) => this._guard("load " + SCRIPTS[i], () => s.runInContext(this.ctx)));
    const orig = this.ctx.displayMessage;
    this.ctx.displayMessage = function (msg) {
      self.messages.push([self.clock.now, String(msg)]);
      return orig.call(this, msg);
    };
    // Option bookkeeping for the strategy picker is in the DOM stub.
  }

  _guard(where, fn) {
    try {
      return fn();
    } catch (e) {
      this.errors.push([this.clock.now, where, String(e && e.message ? e.message : e)]);
      if (this.log) this.log(`[${this.clock.now}] ${where}: ${e && e.stack ? e.stack : e}`);
      return undefined;
    }
  }

  // After each timer callback or click. A location.reload() requested in
  // it happens now: a new page (fresh globals and timers, the clock and the
  // RNG go on, prestige comes back from localStorage). Messages the task
  // printed before reloading never show (the new page's console starts
  // over), so they are dropped from the log and "<reload>" marks the spot.
  _afterTask(msgMark) {
    if (this._reloadPending) {
      this.reloads++;
      if (msgMark !== undefined) this.messages.length = msgMark;
      this.messages.push([this.clock.now, "<reload>"]);
      this._load();
    }
  }

  get now() { return this.clock.now; }
  get g() { return this.ctx; }

  // Run the clock to `ms` (inclusive): every timer due at or before it fires.
  advanceTo(ms) {
    if (ms < this.clock.now) throw new Error(`time goes backwards: ${ms} < ${this.clock.now}`);
    for (;;) {
      const t = this.clock.nextDue(ms);
      if (!t) break;
      this.clock.now = t.due;
      if (t.period) t.due += t.period; else this.clock.timers.delete(t.id);
      const mark = this.messages.length;
      this._guard("timer", () => t.fn.call(this.ctx));
      this._afterTask(mark);
    }
    this.clock.now = ms;
  }

  // The element a click verb targets, or null.
  _button(verb, arg) {
    const a = ACTIONS[verb];
    if (!a) throw new Error(`unknown action ${verb}`);
    if (a.project) {
      const p = this.ctx.projects[arg];
      if (!p) throw new Error(`no project index ${arg}`);
      return this.doc.getElementById(p.id);
    }
    let src = a.click;
    if (a.clickN) {
      if (!a.ns.includes(Number(arg))) throw new Error(`${verb}: bad amount ${arg}`);
      src = a.clickN(Number(arg));
    }
    if (a.clickStat) {
      if (!PROBE_STATS.includes(arg)) throw new Error(`${verb}: bad stat ${arg}`);
      src = a.clickStat(arg);
    }
    if (!src) return null;
    const el = this.doc._byOnclick.get(src.replace(/\s+/g, ""));
    if (!el) throw new Error(`no button for ${src}`);
    return el;
  }

  // Can the action be performed now (button visible and enabled, or the
  // select/range value valid)? Returns "" if yes, else the reason.
  check(verb, arg) {
    const a = ACTIONS[verb];
    if (!a) throw new Error(`unknown action ${verb}`);
    if (a.select) {
      const el = this.doc.getElementById(a.select);
      if (!el._visible) return "hidden";
      const s = String(arg);
      if (!el.childNodes.some((o) => o.tagName === "OPTION" && String(o.value) === s)) return "no-option";
      return "";
    }
    if (a.hover) {
      return this.doc.getElementById(a.hover)._visible ? "" : "hidden";
    }
    if (a.range) {
      const el = this.doc.getElementById(a.range);
      if (!el._visible) return "hidden";
      const n = Number(arg);
      if (!Number.isInteger(n) || n < a.min || n > a.max) return "out-of-range";
      return "";
    }
    const el = this._button(verb, arg);
    if (!el) return "absent";
    if (!el._visible) return "hidden";
    if (el.disabled) return "disabled";
    return "";
  }

  // Perform a script action. Returns true when applied.
  act(verb, arg) {
    const why = this.check(verb, arg);
    if (why) return false;
    const a = ACTIONS[verb];
    const mark = this.messages.length;
    if (a.select || a.range) {
      this.doc.getElementById(a.select || a.range).value = String(arg);
      return true;
    }
    if (a.hover) {
      this._guard(`hover ${verb}`, () => vm.runInContext(a.call, this.ctx));
      this._afterTask(mark);
      return true;
    }
    const el = this._button(verb, arg);
    if (a.project) {
      // displayProjects sets onclick = function(){project.effect()}
      this._guard(`click ${verb} ${arg}`, () => el.onclick());
    } else {
      this._guard(`click ${verb} ${arg ?? ""}`, () => vm.runInContext(el._onclickSrc, this.ctx));
    }
    this._afterTask(mark);
    return true;
  }

  // Value of a JS expression in the page (a global name or `a.b`).
  read(expr) {
    return vm.runInContext(expr, this.ctx);
  }

  activeProjects() {
    const P = this.ctx.projects;
    return this.ctx.activeProjects.map((p) => P.indexOf(p));
  }
}

// ------------------------------------------------------------ snapshots ----

// fields.txt: one JS expression per line; "#" comments; optional
// " = zig_name" override and " ~ reason" for noisy fields (compare.mjs).
export function loadFields(file) {
  const out = [];
  for (let line of fs.readFileSync(file, "utf8").split("\n")) {
    line = line.replace(/#.*/, "").trim();
    if (!line) continue;
    let noisy = null;
    const t = line.indexOf("~");
    if (t >= 0) { noisy = line.slice(t + 1).trim(); line = line.slice(0, t).trim(); }
    let zig = null;
    const e = line.indexOf("=");
    if (e >= 0) { zig = line.slice(e + 1).trim(); line = line.slice(0, e).trim(); }
    out.push({ js: line, zig: zig || snake(line), noisy });
  }
  return out;
}

// camelCase -> snake_case per identifier; "qChips[0].value" ->
// "q_chips[0].value" (compare.mjs walks the path in the Zig dump).
export function snake(js) {
  return js.replace(/[A-Za-z_][A-Za-z0-9_]*/g, (id) =>
    id
      .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
      .replace(/([A-Z])([A-Z][a-z])/g, "$1_$2")
      .toLowerCase());
}

export function encodeValue(v) {
  if (typeof v === "boolean") return v ? 1 : 0;
  if (typeof v === "number") {
    if (Number.isNaN(v)) return "NaN";
    if (v === Infinity) return "Infinity";
    if (v === -Infinity) return "-Infinity";
    return v;
  }
  if (v === undefined) return null;
  if (typeof v === "string") return v;
  if (v === null) return null;
  return String(v);
}

const fieldScripts = new WeakMap();

export function snapshot(oracle, fields) {
  let script = fieldScripts.get(fields);
  if (!script) {
    const parts = fields.map((fd) => `(() => { try { return ${fd.js}; } catch (e) { return "ERR " + e.message; } })()`);
    script = new vm.Script(`[${parts.join(",\n")}]`, { filename: "fields" });
    fieldScripts.set(fields, script);
  }
  const vals = script.runInContext(oracle.ctx);
  const f = {};
  fields.forEach((fd, i) => { f[fd.js] = encodeValue(vals[i]); });
  const g = oracle.g;
  const doc = oracle.doc;
  // Buttons' disabled state and the shown/hidden state of every element
  // the game has set display (victoryDiv: visibility) on.
  const disabled = {};
  const panels = {};
  for (const [id, el] of doc._byId) {
    if (el.tagName === "BUTTON" && id.startsWith("btn")) disabled[id] = el.disabled;
    if (el.style._touched) panels[id] = id === "victoryDiv" ? el.style.visibility !== "hidden" : el.style.display !== "none";
  }
  return {
    ms: oracle.now,
    fields: f,
    disabled,
    panels,
    project_disabled: g.projects.map((p) => { const el = doc.getElementById(p.id); return el ? el.disabled : false; }),
    active_projects: oracle.activeProjects(),
    project_flags: g.projects.map((p) => p.flag),
    project_uses: g.projects.map((p) => p.uses),
    msg_count: oracle.messages.length,
    rng_calls: oracle.rng.calls,
  };
}

// --------------------------------------------------------------- scripts ----

export function loadScript(file) {
  const s = JSON.parse(fs.readFileSync(file, "utf8"));
  s.name = s.name || path.basename(file, ".json");
  return s;
}

// Checkpoint times: every `every` ms in [from, to] plus the explicit list.
export function checkpointTimes(script, o = {}) {
  const end = script.end_ms;
  const every = o.every || script.checkpoint_every || 1000;
  const from = o.from ?? 0;
  const to = Math.min(o.to ?? end, end);
  const set = new Set();
  for (let t = Math.ceil(from / every) * every; t <= to; t += every) if (t > 0) set.add(t);
  for (const t of script.checkpoints || []) if (t >= from && t <= to) set.add(t);
  set.add(to);
  return [...set].sort((a, b) => a - b);
}

// Replay a script. At each ms: timers due fire first, then that ms's actions
// in script order, then the checkpoint snapshot (if any).
export function runScript(script, fields, o = {}) {
  const oracle = new Oracle(script.seed, o);
  const cps = checkpointTimes(script, o);
  const acts = script.actions || [];
  const out = { side: "js", name: script.name, seed: String(script.seed), end_ms: script.end_ms, checkpoints: [], actions: [], messages: null, errors: null };
  let ai = 0;
  for (const cp of cps) {
    while (ai < acts.length && acts[ai][0] <= cp) {
      const [ms, verb, arg] = acts[ai];
      oracle.advanceTo(ms);
      const ok = oracle.act(verb, arg);
      out.actions.push(ok ? 1 : 0);
      ai++;
    }
    oracle.advanceTo(cp);
    out.checkpoints.push(snapshot(oracle, fields));
  }
  out.messages = oracle.messages.map(([, t]) => t);
  out.message_ms = oracle.messages.map(([ms]) => ms);
  out.errors = oracle.errors;
  out.reloads = oracle.reloads;
  return { out, oracle };
}

// ------------------------------------------------------------------ CLI ----

function main(argv) {
  const args = { fields: path.join(HERE, "oracle/fields.txt") };
  const pos = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "-o") args.out = argv[++i];
    else if (a === "--every") args.every = Number(argv[++i]);
    else if (a === "--from") args.from = Number(argv[++i]);
    else if (a === "--to") args.to = Number(argv[++i]);
    else if (a === "--fields") args.fields = argv[++i];
    else if (a === "-v") args.verbose = true;
    else pos.push(a);
  }
  if (pos.length !== 1) {
    console.error("usage: node js_oracle.mjs SCRIPT.json [-o OUT.json] [--every MS] [--from MS] [--to MS] [--fields FILE] [-v]");
    process.exit(2);
  }
  const script = loadScript(pos[0]);
  const fields = loadFields(args.fields);
  const { out } = runScript(script, fields, { ...args, log: args.verbose ? (s) => console.error(s) : null });
  const json = JSON.stringify(out);
  if (args.out) fs.writeFileSync(args.out, json + "\n");
  else process.stdout.write(json + "\n");
  if (out.errors.length) console.error(`js_oracle: ${out.errors.length} JS errors (first: ${JSON.stringify(out.errors[0])})`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2));
}
