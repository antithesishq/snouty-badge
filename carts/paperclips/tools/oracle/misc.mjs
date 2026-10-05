// misc.mjs: writes scripts/misc.json, a 20-minute script with a different
// seed that presses the buttons the bot rarely or never does: the cheats,
// prestige, price down, clicks on disabled buttons (they must be ignored on
// both sides), every strategy pick, the tournament hover, AutoTourney and
// WireBuyer toggles, high-risk investing and withdrawals, Xavier
// Re-initialization, then (cheating through stage 1) the HypnoDrones and the
// stage 2 machines with their +10/+100 buttons, the slider and the
// Disassemble All buttons.
//
// usage: node misc.mjs [--seed N] [--out FILE]

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Oracle } from "../js_oracle.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
let seed = "4242";
let outFile = path.join(HERE, "scripts", "misc.json");
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i] === "--seed") seed = process.argv[++i];
  else if (process.argv[i] === "--out") outFile = process.argv[++i];
  else throw new Error(`unknown arg ${process.argv[i]}`);
}

const o = new Oracle(seed);
let g = o.g;
const actions = [];
const END = 20 * 60 * 1000;

// Records the action when the page shows the button (applied or, when
// disabled, ignored: both sides must agree either way).
function press(verb, arg) {
  const why = o.check(verb, arg);
  if (why !== "" && why !== "disabled") return false;
  const ok = o.act(verb, arg);
  actions.push(arg === undefined ? [o.now, verb] : [o.now, verb, arg]);
  return ok;
}

const idx = {};
for (let i = 0; i < g.projects.length; i++) idx[g.projects[i].id.replace("projectButton", "")] = i;
const NEVER = new Set(["217", "200", "201", "147", "148", "2"]);

let xavier = false;
function buyProjects() {
  for (const p of [...g.activeProjects]) {
    const id = p.id.replace("projectButton", "");
    if (NEVER.has(id)) continue;
    if (id === "219" && xavier) continue;
    if (o.check("buy_project", idx[id])) continue;
    press("buy_project", idx[id]);
    if (id === "219") xavier = true;
    return true;
  }
  return false;
}

let pickI = 0;
for (let t = 100; t <= END; t += 100) {
  o.advanceTo(t);
  g = o.g;
  const s = t / 1000;

  // Hand clicks and prices.
  if (s < 30) press("make_paperclip");
  if (s >= 1 && s < 1.3) press("lower_price");
  if (s >= 1.3 && s < 1.8) press("raise_price");
  if (t === 2000) { press("buy_ads"); press("make_clipper"); press("invest_deposit"); }
  if (t === 3000) press("cheat_money");
  if (s >= 3.5 && s < 5) { press("buy_ads"); press("make_clipper"); press("buy_wire"); }
  if (s >= 5 && s < 9) press("cheat_trust");
  if (t === 9000) { press("cheat_ops"); press("cheat_creat"); press("cheat_yomi"); press("cheat_clips"); }
  if (t === 9500) { press("cheat_prestige_u"); press("cheat_prestige_s"); press("set_battle_number"); }
  if (t === 12000) press("cheat_hypno");
  if (t === 200000) press("reset_prestige");
  if (s >= 20 && s < 60 && t % 1000 === 0) press("lower_price");
  if (s >= 60 && s < 70) press("raise_price");

  // Trust: alternate processors and memory.
  if (!o.check("add_proc")) press(g.processors * 2 <= g.memory ? "add_proc" : "add_mem");

  if (t % 500 === 0) press("q_compute");
  if (t % 300 === 0) buyProjects();
  if (t % 2000 === 0 && s > 30) { press("make_clipper"); press("make_mega_clipper"); press("buy_ads"); press("buy_wire"); }

  // WireBuyer and AutoTourney on/off.
  if (t === 150000 || t === 170000) press("toggle_wire_buyer");
  if (t === 400000 || t === 420000) press("toggle_auto_tourney");

  // Investments: deposit, high risk, withdraw, medium, upgrade.
  if (g.investmentEngineFlag) {
    if (t % 60000 === 0) press("invest_deposit");
    if (t % 60000 === 10000) press("set_invest_strat", "hi");
    if (t % 60000 === 40000) press("invest_withdraw");
    if (t % 60000 === 45000) press("set_invest_strat", t % 120000 < 60000 ? "med" : "low");
    if (t % 30000 === 5000) press("invest_upgrade");
  }

  // Strategy: every pick in turn, the hover both ways.
  if (g.strategyEngineFlag) {
    if (t % 7000 === 0) {
      const n = g.strats.length;
      const want = pickI % (n + 1) === n ? 10 : pickI % (n + 1);
      pickI++;
      press("set_strat_pick", want);
      if (!g.tourneyInProg) { press("new_tourney"); press("run_tourney"); }
    }
    if (g.resultsFlag && t % 7000 === 3000) press("reveal_grid");
    if (g.resultsFlag && t % 7000 === 3500) press("reveal_results");
  }

  // Stage 1 out: cheat trust up to the HypnoDrones.
  if (g.humanFlag === 1 && s > 300 && g.trust < 100 && t % 200 === 0) press("cheat_trust");
  if (g.humanFlag === 1 && s > 300 && t % 1000 === 0) press("cheat_ops");
  if (g.humanFlag === 0) {
    if (t % 1000 === 0) press("cheat_ops");
    if (t % 5000 === 0) press("cheat_clips");
    if (g.factoryFlag && t % 3000 === 0) press("make_factory");
    if (g.project127.flag && t % 1000 === 0) { press("make_farm", 10); press("make_farm", 1); press("make_battery", 10); press("make_battery", 1); }
    if (g.harvesterFlag && t % 1000 === 500) { press("make_harvester", 100); press("make_harvester", 10); press("make_harvester", 1); press("make_harvester", 1000); }
    if (g.wireDroneFlag && t % 1000 === 600) { press("make_wire_drone", 100); press("make_wire_drone", 10); press("make_wire_drone", 1); press("make_wire_drone", 1000); }
    if (g.swarmFlag && t % 20000 === 0) press("set_slider", (t / 20000) % 2 ? 150 : 40);
    if (t === END - 60000) press("factory_reboot");
    if (t === END - 50000) press("harvester_reboot");
    if (t === END - 40000) press("wire_drone_reboot");
    if (t === END - 30000) press("farm_reboot");
    if (t === END - 20000) press("battery_reboot");
    if (t === END - 10000) press("zero_matter");
  }
}

const script = { name: "misc", seed, end_ms: END, checkpoint_every: 1000, note: "misc.mjs: cheats, prestige, disabled clicks, picks, hover, toggles, investing, stage 2 buttons", actions };
const body = actions.map((a) => "  " + JSON.stringify(a)).join(",\n");
const head = JSON.stringify({ ...script, actions: undefined }).slice(0, -1);
fs.writeFileSync(outFile, `${head},"actions":[\n${body}\n]}\n`);
const applied = actions.length; // (the replay reports applied flags)
console.error(`wrote ${outFile}: ${applied} actions; humanFlag ${g.humanFlag}, projects bought ${g.projects.filter((p) => p.flag).length}, errors ${o.errors.length}`);
