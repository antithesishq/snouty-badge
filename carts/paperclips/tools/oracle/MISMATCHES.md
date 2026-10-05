# Oracle mismatches (track O -> lead -> track L)

`tools/oracle/run.sh` runs every script in `scripts/` through the original
JS and the port and diffs them (`tools/compare.mjs`). This file lists what
the comparison found that the port should change, newest first. Each entry:
script, virtual ms, field, JS value vs Zig value, the JS line responsible.

## Open

None that fail the comparison.

- Minor, not compared: `g.panels.victory_div` stays `true` for the whole
  game while `g.victory_visible` follows `victoryDiv.style.visibility`
  (combat.js `checkForBattleEnd` / `endBattle`). compare.mjs checks
  `victoryDiv` against `victory_visible`; drop the panel field or keep it
  in step so the UI cannot read the stale one.

## Status by script (2026-10-04: committed ad5d3c80 and the working tree after it; full run.sh 4.3 min)

| script | seed | virtual time | reaches | result |
|---|---|---|---|---|
| short | 20171009 | 5:00 | stage 1, first projects | MATCH |
| stage1 | 20171009 | 2:28:58 | Release the HypnoDrones (2:27:58) + 60 s | MATCH |
| deep | 20171009 | 10:13:03 | the end: Reject, all disassembly, 100 final clips, credits (milestoneFlag 20) | MATCH |
| stage1b | 31337 | 2:29:55 | Release the HypnoDrones + 60 s (another seed) | MATCH |
| prestige | 20171009 | 10:23:54 | the whole game, Accept, The Universe Next Door (reload, prestigeU 1), 5 min of the next universe | MATCH |
| misc | 4242 | 20:00 | cheats, prestige, ~10k disabled clicks, hover, stage 2 buttons and reboots | MATCH |

## Fixed

(none yet)
