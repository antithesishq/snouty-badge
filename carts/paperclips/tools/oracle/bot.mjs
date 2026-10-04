// bot.mjs: plays the original Universal Paperclips headless (through
// js_oracle.mjs) and records what it does as oracle action scripts.
//
// The bot looks at the game's globals every 100 ms of virtual time and
// issues only actions the page accepts at that moment (button visible and
// enabled), so replaying the recorded script through js_oracle.mjs gives the
// same game, and the Zig port must accept every action too. It never calls
// Math.random (that is the game's RNG stream).
//
// usage: node bot.mjs [--seed N] [--max-ms MS] [--out-dir DIR] [--stage N]
//   --stage 1  stop 60 s after "Release the HypnoDrones"
//   --stage 3  play on to the end (default)
// Writes short.json (first 5 minutes), stage1.json (to the HypnoDrones +
// 60 s) and deep.json (everything) into --out-dir.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Oracle } from "../js_oracle.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));

const args = { seed: "20171009", maxMs: 6 * 3600 * 1000, outDir: path.join(HERE, "scripts"), stage: 3, quiet: false };
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === "--seed") args.seed = process.argv[++i];
  else if (a === "--max-ms") args.maxMs = Number(process.argv[++i]);
  else if (a === "--out-dir") args.outDir = process.argv[++i];
  else if (a === "--stage") args.stage = Number(process.argv[++i]);
  else if (a === "-q") args.quiet = true;
  else if (a === "--report") args.report = Number(process.argv[++i]);
  else if (a === "--accept") args.accept = true;
  else throw new Error(`unknown arg ${a}`);
}

const STEP = 100;
const o = new Oracle(args.seed);
let g = o.g;
const actions = [];
const events = {}; // name -> ms (first time)

function note(name) {
  if (!(name in events)) {
    events[name] = o.now;
    if (!args.quiet) console.error(`[${fmtTime(o.now)}] ${name}`);
  }
}

function fmtTime(ms) {
  const s = Math.floor(ms / 1000);
  return `${Math.floor(s / 3600)}:${String(Math.floor((s % 3600) / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

// Try an action; record it when the page accepts it.
function tryAct(verb, arg) {
  if (o.check(verb, arg)) return false;
  const ok = o.act(verb, arg);
  if (ok) actions.push(arg === undefined ? [o.now, verb] : [o.now, verb, arg]);
  return ok;
}

const pIndex = (name) => g.projects.indexOf(g[name]);
const idx = {};
for (let i = 0; i < g.projects.length; i++) idx[g.projects[i].id.replace("projectButton", "")] = i;

function opsCost(p) {
  const m = /([\d,]+) ops/.exec(p.priceTag);
  return m ? Number(m[1].replace(/,/g, "")) : 0;
}

// Projects never bought by the bot.
// --accept takes the Drift King's offer (Accept, then The Universe Next
// Door: prestige and a page reload) instead of Reject (the ending).
const SKIP = new Set(args.accept ? ["219", "217", "201", "148"] : ["219", "217", "200", "201", "147"]);

let step = 0;
let lastPrice = 0;
let hypnoAt = -1;
let lastTourney = 0;

function stage() {
  if (g.humanFlag === 1) return 1;
  if (g.spaceFlag === 0) return 2;
  return 3;
}

// ------------------------------------------------------------- stage 1 ----

function productionPerSec() {
  return g.clipmakerLevel * g.clipperBoost + g.megaClipperLevel * 5 * g.megaClipperBoost * 100;
}

// Expected clips sold per second at margin m (the 100 ms sales loop).
function salesPerSec(m) {
  let d = (0.8 / m) * Math.pow(1.1, g.marketingLvl - 1) * g.marketingEffectiveness * g.demandBoost;
  d = d + (d / 10) * g.prestigeU;
  return 10 * Math.min(1, d / 100) * Math.floor(0.7 * Math.pow(d, 1.15));
}

// The highest price that still sells what we make (plus a stock drain).
function targetMargin(prod) {
  const want = prod * 1.05 + g.unsoldClips / 20;
  let best = 0.01;
  for (let c = 1; c <= 500; c++) {
    const m = c / 100;
    if (salesPerSec(m) >= want) best = m;
    else break;
  }
  return best;
}

let clicking = true;
function stage1() {
  const rate = productionPerSec();

  // Hand-make clips while the machines are few.
  if (clicking && rate >= 150) clicking = false;
  if (clicking && g.wire >= 1) tryAct("make_paperclip");

  // Price: step toward the margin that sells exactly what we make.
  if (o.now - lastPrice >= 200) {
    lastPrice = o.now;
    const t = targetMargin(rate + (clicking ? 10 : 0));
    if (g.margin > t + 0.005 && g.margin > 0.01) tryAct("lower_price");
    else if (g.margin < t - 0.005) tryAct("raise_price");
  }

  // Wire: buy cheap, or when running out.
  const wireNeed = Math.max(1500, rate * 30);
  if (g.wire < wireNeed && (g.wireCost <= g.wireBasePrice + 1 || g.wire < Math.max(300, rate * 5))) tryAct("buy_wire");

  const reserve = g.wireBuyerFlag ? g.wireCost : g.wireCost * 2;
  const spare = g.funds - reserve;
  const bigBuy = wantedFundsProject();
  // Saving for a goodwill token or takeover: stop buying machines once
  // the clip engine is big.
  const saving = bigBuy && g.megaClipperLevel >= 60;

  if (!saving) {
    const machine = g.megaClipperFlag ? g.megaClipperCost : g.clipperCost;
    // Demand-limited (we make more than sells at 5 cents): marketing first.
    const demandLimited = salesPerSec(0.05) < rate;
    if (spare >= g.adCost && (demandLimited || g.adCost <= machine * (g.megaClipperFlag ? 4 : 25))) tryAct("buy_ads");
    if (!demandLimited || machine * 20 < g.adCost) {
      if (g.megaClipperFlag && spare >= g.megaClipperCost) tryAct("make_mega_clipper");
      else if (spare >= g.clipperCost && (g.clipmakerLevel < 75 || g.clipperCost < g.megaClipperCost / 20)) tryAct("make_clipper");
    }
  }

  investments(bigBuy);
  strategy();
  trustAlloc();
  quantum();
  buyProjects();
}

// The $ project the bot is saving for (cost), or 0.
function wantedFundsProject() {
  let best = 0;
  for (const p of g.activeProjects) {
    const id = p.id.replace("projectButton", "");
    let c = 0;
    if (id === "40") c = 500000;
    else if (id === "40b") c = g.bribe;
    else if (id === "37") c = 1000000;
    else if (id === "38") c = 10000000;
    if (c && (!best || c < best)) best = c;
  }
  return best;
}

let lastInvest = 0;
function investments(bigBuy) {
  if (!g.investmentEngineFlag) return;
  if (g.investLevel < 8 && g.yomi >= g.investUpgradeCost * 2 && g.yomi > 6000) tryAct("invest_upgrade");
  if (o.now - lastInvest < 5000) return;
  lastInvest = o.now;
  const want = bigBuy;
  if (want && g.funds < want && g.funds + g.bankroll >= want) {
    tryAct("invest_withdraw");
    return;
  }
  if (want && g.funds + g.bankroll < want && g.funds + g.portTotal >= want && g.riskiness !== 7) {
    // Let stocks be sold off by keeping low risk.
  }
  if (g.document.getElementById("investStrat").value !== "low" && g.stockGainThreshold < 0.55) tryAct("set_invest_strat", "low");
  if (g.stockGainThreshold >= 0.55 && g.document.getElementById("investStrat").value !== "med") tryAct("set_invest_strat", "med");
  // Deposit spare money now and then.
  const keep = Math.max(g.megaClipperFlag ? g.megaClipperCost * 3 : g.adCost * 2, 2000);
  if (g.funds > keep * 2 && g.funds > 20000 && (!want || g.funds + g.bankroll < want * 0.5)) tryAct("invest_deposit");
}

function stratChoice() {
  // GREEDY if we have it, else the newest strategy.
  const n = g.strats.length;
  if (n > 3) return 3;
  return n - 1;
}

function strategy() {
  if (!g.strategyEngineFlag) return;
  const want = String(stratChoice());
  if (g.document.getElementById("stratPicker").value !== want) tryAct("set_strat_pick", Number(want));
  if (g.tourneyInProg) {
    tryAct("run_tourney");
    return;
  }
  if (g.autoTourneyFlag && g.autoTourneyStatus === 1) return;
  // Tournaments cost ops: run them when operations sit at the cap.
  if (g.operations >= g.memory * 1000 * 0.95 && g.operations >= g.tourneyCost && o.now - lastTourney > 2000) {
    if (tryAct("new_tourney")) {
      lastTourney = o.now;
      tryAct("run_tourney");
    }
  }
}

function trustAlloc() {
  // Both buttons share one enabled state.
  if (o.check("add_proc")) return;
  // Memory for the cheapest project that does not fit, else keep
  // processors level with memory (ops and creativity speed).
  let blocked = 0;
  for (const p of g.activeProjects) {
    const id = p.id.replace("projectButton", "");
    if (SKIP.has(id)) continue;
    const c = opsCost(p);
    if (c > g.memory * 1000 && (!blocked || c < blocked)) blocked = c;
  }
  if (g.humanFlag === 0 && g.project46.flag === 0 && g.memory < 120 && g.processors >= 30) blocked = 120000;
  if (g.processors * 2 < g.memory) tryAct("add_proc");
  else if (blocked) tryAct("add_mem");
  else if (g.processors <= g.memory) tryAct("add_proc");
  else tryAct("add_mem");
}

let lastQ = 0;
function quantum() {
  if (!g.qFlag || g.qChips[0].active === 0) return;
  if (o.now - lastQ < 300) return;
  let q = 0;
  for (const c of g.qChips) q += c.value;
  if (q > 0.5 && g.operations < g.memory * 1000 * 1.5) {
    if (tryAct("q_compute")) lastQ = o.now;
  }
}

function buyProjects() {
  for (const p of [...g.activeProjects]) {
    const id = p.id.replace("projectButton", "");
    if (SKIP.has(id)) continue;
    if (id === "35" && args.stage < 2 && hypnoAt >= 0) continue;
    if (id === "2" && !(g.wire < 1 && g.funds < g.wireCost && g.unsoldClips < 1)) continue;
    if (tryAct("buy_project", idx[id])) {
      note(`project ${id} ${p.title.trim()}`);
      if (id === "35") hypnoAt = o.now;
      return;
    }
  }
}

// ------------------------------------------------------------- stage 2 ----

// Per 10 ms tick, as the main loop computes them.
function harvestPerTick() {
  const db = g.droneBoost > 1 ? g.droneBoost * Math.floor(g.harvesterLevel) : 1;
  return Math.max(g.powMod, 0.0001) * db * Math.floor(g.harvesterLevel) * g.harvesterRate * ((200 - Number(g.sliderPos)) / 100);
}
function wirePerTick() {
  const db = g.droneBoost > 1 ? g.droneBoost * Math.floor(g.wireDroneLevel) : 1;
  return Math.max(g.powMod, 0.0001) * db * Math.floor(g.wireDroneLevel) * g.wireDroneRate * ((200 - Number(g.sliderPos)) / 100);
}
function factoryPerTick() {
  const fb = g.factoryBoost > 1 ? g.factoryBoost * g.factoryLevel : 1;
  return Math.max(g.powMod, 0.0001) * fb * Math.floor(g.factoryLevel) * g.factoryRate;
}
function powerSupply() { return g.farmLevel * g.farmRate / 100; }
function powerDemand(extraFactories = 0, extraDrones = 0) {
  return ((g.harvesterLevel + g.wireDroneLevel + extraDrones) * g.dronePowerRate) / 100 + ((g.factoryLevel + extraFactories) * g.factoryPowerRate) / 100;
}

// The biggest affordable batch (button enabled) of a buy verb.
function buyBatch(verb, ns, maxN = Infinity) {
  for (const n of ns) {
    if (n > maxN) continue;
    if (tryAct(verb, n)) return n;
  }
  return 0;
}

let lastSlider = -1;
function stage2() {
  buyProjects();
  trustAlloc();
  quantum();
  strategy();
  swarmCare();

  // Bootstrap: one factory, one harvester, one wire drone, even on a
  // power deficit (everything then runs at supply/demand).
  // (Clips come only from factories: none until the first is up.)
  if (g.factoryLevel === 0) { if (g.factoryFlag) tryAct("make_factory"); return; }
  if (g.harvesterFlag && g.harvesterLevel === 0) { tryAct("make_harvester", 1); return; }
  if (g.wireDroneFlag && g.wireDroneLevel === 0) { tryAct("make_wire_drone", 1); return; }
  if (!g.project127.flag) return;

  // Farms make 0.5, a factory takes 2, a drone 0.01. On a deficit only a
  // farm raises output, so save for one.
  const farms = (needSupply) => {
    const need = Math.max(1, Math.ceil((needSupply - powerSupply()) / 0.5));
    return buyBatch("make_farm", [100, 10, 1], need * 2);
  };
  if (powerSupply() < powerDemand()) { farms(powerDemand()); return; }

  // Storage for Space Exploration (10M MW-s): batteries and spare farms
  // once the matter runs low or clips are plentiful.
  const late = g.availableMatter < 6e27 * 0.05 || g.unusedClips > 1e26;
  if (late) {
    if (g.batteryLevel * g.batterySize < 1.2e7) buyBatch("make_battery", [100, 10, 1]);
    if (powerSupply() - powerDemand() < 2000 && g.farmLevel < 6000) farms(powerDemand() + 2000);
  }
  if (g.availableMatter <= 0) {
    // All matter is wire and all wire is clips: take the machines apart
    // for their clips if Space Exploration still needs some.
    if (g.acquiredMatter <= 0 && g.wire < 1 && g.unusedClips < 5e27) {
      if (g.factoryLevel > 0) tryAct("factory_reboot");
      else if (g.harvesterLevel > 0) tryAct("harvester_reboot");
      else if (g.wireDroneLevel > 0) tryAct("wire_drone_reboot");
    }
    return;
  }

  // Factories keep up with the wire; drones keep up with each other.
  const w = wirePerTick();
  const f = factoryPerTick();
  if (g.factoryFlag && (f < w * 1.2 || g.wire > f * 200)) {
    if (powerSupply() >= powerDemand(1, 0)) tryAct("make_factory");
    else farms(powerDemand(1, 0));
    return;
  }
  const room = Math.floor((powerSupply() - powerDemand()) / 0.01);
  if (room < 1) { farms(powerDemand(0, 100)); return; }
  if (g.harvesterLevel <= g.wireDroneLevel) buyBatch("make_harvester", [1000, 100, 10, 1], room);
  else buyBatch("make_wire_drone", [1000, 100, 10, 1], room);
}

// Swarm: work/think slider, boredom and disorganization.
function swarmCare() {
  if (!g.swarmFlag) return;
  // Think (gifts: processors and memory) until memory covers the big
  // projects, then mostly work.
  const want = g.memory < 150 ? 100 : 20;
  if (want !== lastSlider && !o.check("set_slider", want)) {
    if (tryAct("set_slider", want)) lastSlider = want;
  }
  if (g.swarmStatus === 5) tryAct("synch_swarm");
  if (g.swarmStatus === 3) tryAct("entertain_swarm");
}

// ------------------------------------------------------------- stage 3 ----

const STATS = ["speed", "nav", "rep", "haz", "fac", "harv", "wire", "combat"];
const statVar = { speed: "probeSpeed", nav: "probeNav", rep: "probeRep", haz: "probeHaz", fac: "probeFac", harv: "probeHarv", wire: "probeWire", combat: "probeCombat" };

function probeTargets(T) {
  const t = { speed: 0, nav: 0, rep: 0, haz: 0, fac: 0, harv: 0, wire: 0, combat: 0 };
  // Hazards kill 1% of the probes per tick at haz 0, replication adds
  // 0.005% per rep point: haz and rep first, then one each of the rest.
  const order = ["rep", "haz", "haz", "fac", "harv", "wire", "speed", "nav", "rep"];
  let left = T;
  for (const k of order) if (left > 0) { t[k]++; left--; }
  if (left > 0) {
    const fight = g.drifterCount > 0 ? Math.min(Math.round(left * 0.25), 12) : 0;
    const haz = Math.min(Math.round(left * 0.35), 6);
    const sp = Math.floor(left / 12);
    t.combat += fight;
    t.haz += haz;
    t.speed += sp;
    t.nav += sp;
    t.rep += left - fight - haz - 2 * sp;
  }
  return t;
}

let probesLaunched = 0;
function stage3() {
  buyProjects();
  trustAlloc();
  quantum();
  strategy();
  swarmCare();

  if (g.dismantle >= 4) {
    // The last clips are made by hand.
    if (g.wire >= 1) tryAct("make_paperclip");
    return;
  }
  if (!o.check("increase_max_trust")) tryAct("increase_max_trust");
  if (!o.check("increase_probe_trust")) tryAct("increase_probe_trust");

  const tgt = probeTargets(g.probeTrust);
  let moved = false;
  for (const k of STATS) {
    if (g[statVar[k]] > tgt[k]) { if (tryAct("probe_stat_down", k)) { moved = true; break; } }
  }
  if (!moved) {
    for (const k of STATS) {
      if (g[statVar[k]] < tgt[k]) { if (tryAct("probe_stat_up", k)) { moved = true; break; } }
    }
  }
  // Launch once the design uses all the trust it has.
  if (!moved && g.probeTrust >= 9 && g.probeUsedTrust === g.probeTrust && g.probeCount < 1000) {
    if (tryAct("make_probe")) probesLaunched++;
  }
}

// ------------------------------------------------------------------ main ----

let lastReport = 0;
let doneAt = -1;
const end = args.maxMs;
let reloadAt = -1;
for (;;) {
  o.advanceTo(o.now + STEP);
  step++;
  g = o.g;
  if (o.reloads > 0 && reloadAt < 0) {
    // A new universe: the stage 1 policy starts over.
    reloadAt = o.now;
    note("reload");
    clicking = true;
    lastPrice = 0;
    lastInvest = 0;
    lastTourney = 0;
    lastQ = 0;
    lastSlider = -1;
  }
  if (reloadAt >= 0 && o.now >= reloadAt + 300000) break;
  const st = stage();
  note(`stage ${st}`);
  if (st === 1) stage1();
  else if (st === 2) stage2();
  else if (args.stage >= 3) stage3();
  else break;
  if (g.milestoneFlag >= 20 && doneAt < 0) doneAt = o.now;
  if (doneAt >= 0 && o.now >= doneAt + 60000) break;
  if (hypnoAt >= 0 && args.stage < 2 && o.now >= hypnoAt + 60000) break;
  if (o.now >= end) break;
  if (!args.quiet && o.now - lastReport >= (args.report || (stage() > 1 ? 300000 : 600000))) {
    lastReport = o.now;
    if (stage() > 1) console.error(`[${fmtTime(o.now)}] S${stage()} clips ${g.clips.toExponential(3)} unused ${g.unusedClips.toExponential(3)} wire ${g.wire.toExponential(2)} matter ${g.availableMatter.toExponential(3)} acq ${g.acquiredMatter.toExponential(2)} fac ${g.factoryLevel} harv ${g.harvesterLevel} wd ${g.wireDroneLevel} farm ${g.farmLevel} bat ${g.batteryLevel} pow ${g.powMod.toFixed(3)} stored ${Math.round(g.storedPower)} proc ${g.processors} mem ${g.memory} ops ${g.operations} creat ${Math.round(g.creativity)} yomi ${g.yomi} gifts ${g.swarmGifts} slider ${g.sliderPos} swarm ${g.swarmStatus} probes ${g.probeCount.toExponential(2)} ptrust ${g.probeTrust}/${g.maxTrust} [${STATS.map((k) => g[statVar[k]]).join(' ')}] lostH ${g.probesLostHaz.toExponential(2)} lostC ${g.probesLostCombat.toExponential(2)} battles ${g.battles.length} drift ${g.drifterCount.toExponential(2)} honor ${Math.round(g.honor)} found ${(g.foundMatter / g.totalMatter).toExponential(2)} actions ${actions.length}`);
    else console.error(`[${fmtTime(o.now)}] clips ${Math.round(g.clips)} funds ${g.funds.toFixed(2)} trust ${g.trust} proc ${g.processors} mem ${g.memory} ops ${g.operations} creat ${Math.round(g.creativity)} yomi ${g.yomi} mkt ${g.marketingLvl} mega ${g.megaClipperLevel} auto ${g.clipmakerLevel} margin ${g.margin} bank ${g.bankroll} port ${g.portTotal} actions ${actions.length}`);
  }
}

if (o.errors.length) console.error("JS errors:", o.errors.slice(0, 5));
if (!args.quiet) {
  console.error("active:", g.activeProjects.map((p) => `${p.id.replace("projectButton", "")}:${o.check("buy_project", g.projects.indexOf(p)) || "ok"}`).join(" "));
  console.error("withdraw:", o.check("invest_withdraw") || "ok", "deposit:", o.check("invest_deposit") || "ok", "bigBuy", wantedFundsProject());
}

// ---------------------------------------------------------------- output ----

function write(name, endMs, every, note) {
  const acts = actions.filter((a) => a[0] <= endMs);
  const script = { name, seed: String(args.seed), end_ms: endMs, checkpoint_every: every, note, actions: acts };
  fs.mkdirSync(args.outDir, { recursive: true });
  const file = path.join(args.outDir, `${name}.json`);
  // One action per line keeps diffs readable.
  const body = acts.map((a) => "  " + JSON.stringify(a)).join(",\n");
  const head = JSON.stringify({ ...script, actions: undefined }).slice(0, -1);
  fs.writeFileSync(file, `${head},"actions":[\n${body}\n]}\n`);
  console.error(`wrote ${file}: ${acts.length} actions, ${fmtTime(endMs)}`);
}

console.error("events:", JSON.stringify(events));
console.error("final:", JSON.stringify({ ms: o.now, stage: stage(), milestoneFlag: g.milestoneFlag, dismantle: g.dismantle, finalClips: g.finalClips, clips: g.clips, probes: probesLaunched }));
if (!args.accept) write("short", Math.min(300000, o.now), 1000, "bot: the first five minutes");
if (hypnoAt >= 0 && !args.accept) write("stage1", Math.min(o.now, hypnoAt + 60000), 5000, `bot: stage 1 to Release the HypnoDrones at ${hypnoAt} ms, plus 60 s`);
if (args.accept) write("prestige", o.now, 10000, "bot: the whole game, Accept and The Universe Next Door, then 5 minutes of the next universe");
else if (args.stage >= 2) write("deep", o.now, 10000, "bot: as deep as it gets");
