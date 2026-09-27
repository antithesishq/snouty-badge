"""Glean-style run cycle, 16 frames (override of snoutyart/anim/run.py).

Same gait contract as the shared cycle: near-foot contact at 0, far-foot
contact at 8, flight at 6-7 and 14-15, planted toe travels STEP px per frame
toward -x, planted feet's lowest pixel on the baseline (row 88).

Tuned for the chunky lavender Snouty: big head on short legs, so a bigger bob
(4 px), more head lag, a wider tail swing, a bouncing net bag and a near arm
drawn across the chest from the near shoulder to the fist on the handle.
Everything is in cell coordinates (96x96, origin (48,88), y down).
"""
import math

import numpy as np
from PIL import Image

from snoutyart.cycle import Cycle, Frame
from snoutyart.limbs import arm, capsule_layer, leg
from snoutyart.rig import Placed, ik2

N = 16
STEP = 6
MS = 40

FOOT_LEN = 6


def _leg_spec(rig):
    s = dict(rig.limbs["leg"])
    return s


# Vertical body offset per frame (positive = down). Lowest just after contact,
# highest in flight; 4 px total, never more than 1 px between frames.
BOB_HALF = [0, 1, 2, 1, 0, -1, -2, -1]
BOB = BOB_HALF * 2
# Forward lean of torso/head during the drive (px toward +x).
LEAN_HALF = [1, 1, 1, 2, 2, 2, 2, 1]
LEAN = LEAN_HALF * 2
BODY_DX, BODY_DY = -2, -4
NEAR_ARM = {"upper": 8, "fore": 9, "width": 6}
SLEEVE_C, SLEEVE_W = (34, 40), 10   # ref coords of the torso's sleeve bump
HEAD_LAG = 2   # frames the head trails the body's bob
NET_LAG = 1    # frames the net (and the fist holding it) trail the body

X0 = 19
TOE_NEAR = [
    (X0, 0, -4), (X0 - 6, 0, 0), (X0 - 12, 0, 0), (X0 - 18, 0, 0),
    (X0 - 24, 0, 16), (X0 - 30, 0, 45),                     # planted, roll off
    (-15, -3, 65), (-18, -6, 85),                            # push-off, trail
    (-17, -10, 105), (-12, -13, 105),                        # heel kick
    (-5, -15, 85), (3, -14, 55), (10, -11, 28),              # knee drive
    (16, -8, 8), (20, -5, -6), (20, -2, -8),                 # reach, drop
]
GROUNDED_NEAR = [True] * 6 + [False] * 10


def _arm_swing(i):
    """Free (far) arm: contralateral to the far leg, i.e. forward when the near
    foot reaches (frame 0) and back at near push-off."""
    s = math.cos(2 * math.pi * (i + 0.5) / N)
    dx = round(9 * s)
    # pendulum: lowest mid-swing, rising at both ends, a little higher in front
    dy = round(3 - 3 * abs(s) + (1.5 if s < 0 else 0))
    return dx, dy, s


HEAD_ROT = [0, -1, -1, 0, 1, 1, 1, 0] * 2           # slight nod, degrees CCW
TAIL_ROT = [8, 12, 10, 5, -2, -8, -12, -6] * 2      # + = tip down (whip on contact)
NET_ROT = [2, 5, 6, 4, 1, -2, -4, -2] * 2           # + = bag down, lags the body


def _points(rig, spec, i, near, bob, lean, dy_fix=0.0):
    j = i if near else (i + 8) % N
    hx0, hy0 = rig.joint("hip", 1 if near else 3, 0)
    hip = (hx0 + lean, hy0 + bob)
    hx0 += BODY_DX
    ground = rig.origin[1] - (spec["foot_height"] / 2 + 1)
    tx, ty, a = TOE_NEAR[j]
    toe = (hx0 + tx, ground + ty + dy_fix)
    r = math.radians(a)
    ankle = (toe[0] - FOOT_LEN * math.cos(r), toe[1] - FOOT_LEN * math.sin(r))
    knee = ik2(hip, ankle, spec["thigh"], spec["shin"], bend=1)
    return hip, knee, ankle, toe, GROUNDED_NEAR[j]


def _leg_layer(rig, spec, pts, z, far):
    kw = dict(foot="flat", toe_bump=0, spec=spec)
    if far:
        return leg(rig, *pts[:4], z=z, fill=rig.pal.FUR_DARK,
                   shade=rig.pal.FUR_DEEP, shade_px=2, sole=rig.pal.FUR_DEEP, **kw)
    return leg(rig, *pts[:4], z=z, shade_px=2, sole=rig.pal.FUR_DEEP,
               light=rig.pal.FUR_LIGHT, **kw)


def _lowest(layer):
    a = np.array(layer.image)[:, :, 3]
    return int(np.nonzero(a)[0].max())


def _leg(rig, spec, i, near, bob, lean, z):
    pts = _points(rig, spec, i, near, bob, lean)
    lay = _leg_layer(rig, spec, pts, z, not near)
    if pts[4]:  # planted: put the lowest pixel exactly on the baseline
        fix = rig.origin[1] - _lowest(lay)
        if fix:
            pts = _points(rig, spec, i, near, bob, lean, fix)
            lay = _leg_layer(rig, spec, pts, z, not near)
    return pts, lay


def build(rig) -> Cycle:
    spec = _leg_spec(rig)
    aspec = rig.limbs["arm"]
    frames = []
    for i in range(N):
        bob, lean = BOB[i] + BODY_DY, LEAN[i] + BODY_DX
        hbob = BOB[(i - HEAD_LAG) % N] + BODY_DY
        hlean = LEAN[(i - HEAD_LAG) % N] + BODY_DX
        nbob = BOB[(i - NET_LAG) % N] + BODY_DY
        nlean = LEAN[(i - NET_LAG) % N] + BODY_DX
        layers = []
        far, far_l = _leg(rig, spec, i, False, bob, lean, 20)
        near, near_l = _leg(rig, spec, i, True, bob, lean, 28)
        layers += [far_l, near_l]

        # free (far) arm behind the torso; its fist comes in front of the
        # torso on the forward swing and tucks behind on the back swing
        sdx, sdy, s = _arm_swing(i)
        hdx, hdy = lean + sdx, bob + sdy
        hand = rig.anchor("free_hand", hdx, hdy)
        sh = rig.joint("shoulder_far", lean, bob)
        elbow = ik2(sh, hand, aspec["upper"], aspec["fore"], bend=-1)
        layers.append(arm(rig, sh, elbow, hand, z=25, fill=rig.pal.FUR_DARK,
                          shade=rig.pal.FUR_DEEP, shade_px=1))
        hand_z = 40 if s > 0.7 else 24

        # near arm: from the near shoulder across the chest to the fist on
        # the handle; elbow sags below the line
        nsh = rig.joint("shoulder_near", lean, bob + 1)
        fx, fy = rig.anchor("holding_hand", nlean, nbob)
        wrist = (fx - 2, fy)
        nel = ik2(nsh, wrist, NEAR_ARM["upper"], NEAR_ARM["fore"], bend=-1)
        arm_l = arm(rig, nsh, nel, wrist, z=45, spec=NEAR_ARM, shade_px=1,
                    light=rig.pal.FUR_LIGHT)
        layers.append(arm_l)
        # the arm comes out from under the tee's sleeve bump: redraw that bump
        # (same circle as the torso part's) over the arm, clipped to the arm,
        # so only a cuff line shows where the sleeve crosses it
        cx, cy = rig.ref_to_cell(SLEEVE_C)
        c = (cx + lean, cy + bob)
        slv = capsule_layer(rig.cell, [[c]], [SLEEVE_W], 46,
                            fill=rig.pal.SHIRT, shade=rig.pal.SHIRT_DARK,
                            shade_px=0, outline=rig.pal.OUTLINE)
        sa = np.array(slv.image)
        sa[np.array(arm_l.image)[:, :, 3] == 0] = 0
        slv.image = Image.fromarray(sa, "RGBA")
        layers.append(slv)
        layers.append(rig.render_part(Placed("tail", lean, bob, TAIL_ROT[i])))
        layers.append(rig.render_part(Placed("torso", lean, bob)))
        layers.append(rig.render_part(Placed("head", hlean, hbob, HEAD_ROT[i])))
        layers.append(rig.render_part(Placed("net", nlean, nbob, NET_ROT[i])))
        layers.append(rig.render_part(Placed("holding_hand", nlean, nbob)))
        layers.append(rig.render_part(Placed("free_hand", hdx, hdy, z=hand_z)))
        img = rig.compose(layers)
        rnd = lambda p: [round(v, 2) for v in p]
        meta = {
            "near": {"grounded": near[4], "hip": rnd(near[0]), "knee": rnd(near[1]),
                     "ankle": rnd(near[2]), "toe": rnd(near[3])},
            "far": {"grounded": far[4], "hip": rnd(far[0]), "knee": rnd(far[1]),
                    "ankle": rnd(far[2]), "toe": rnd(far[3])},
            "near_arm": {"shoulder": rnd(nsh), "elbow": rnd(nel), "wrist": rnd(wrist)},
            "body_offset": [lean, bob],
            "head_offset": [hlean, hbob],
            "net_offset": [nlean, nbob],
        }
        label = "contact" if i in (0, 8) else ("flight" if i in (6, 7, 14, 15) else "")
        frames.append(Frame(img, label, MS, meta))
    return Cycle("snouty_run", frames, step_px=STEP,
                 notes={"gait": "near contact 0, far contact 8, flight 6-7 and 14-15",
                        "suggested_world_speed_px_s": STEP * 1000 / MS})
