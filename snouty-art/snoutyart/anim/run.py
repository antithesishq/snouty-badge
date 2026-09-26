"""Run cycle, 16 frames. Near-foot contact at 0, far-foot contact at 8; flight
at 6-7 and 14-15; planted toe travels STEP px per frame (toward -x).

Everything is in cell coordinates (96x96, origin (48,88), y down). The far leg
is the near leg's motion shifted by 8 frames and drawn behind the torso.

Each leg frame is a toe point plus a foot angle; the ankle hangs off the toe
and the knee comes from 2-bone IK, so the feet stay flat on the ground through
mid-stance, roll onto the toe at push-off and kick the heel up in recovery.
"""
import math

import numpy as np

from .. import palette
from ..cycle import Cycle, Frame
from ..limbs import arm, leg
from ..rig import Placed, ik2

N = 16
STEP = 6
MS = 40

# Leg proportions for this cycle (shorter than the rig default so the stance
# leg is only slightly bent under the hip and can straighten at push-off).
LEG = {"thigh": 11, "shin": 11, "width": 7, "foot_width": 7,
       "foot_height": 6, "heel": 0.5}
FOOT_LEN = 7

# Vertical body offset per frame (positive = down). Lowest just after contact,
# highest in flight; 3 px total, never more than 1 px between frames.
BOB_HALF = [0, 1, 1, 0, -1, -2, -2, -1]
BOB = BOB_HALF * 2
# Forward lean of torso/head during the drive (px toward +x).
LEAN_HALF = [1, 1, 1, 2, 2, 2, 2, 1]
LEAN = LEAN_HALF * 2
# Whole body sits higher and a little further back than the rest pose so the
# legs get a longer, more athletic stride (matches Study 05 body height).
BODY_DX, BODY_DY = -2, -4

# Near leg: toe x relative to the hip's rest x, toe y relative to the ground
# line (negative = up), foot angle in degrees (0 = flat, + = heel up/toe down).
X0 = 21
TOE_NEAR = [
    (X0, 0, -4), (X0 - 6, 0, 0), (X0 - 12, 0, 0), (X0 - 18, 0, 0),
    (X0 - 24, 0, 16), (X0 - 30, 0, 45),                     # planted, roll off
    (-14, -3, 65), (-18, -6, 85),                            # push-off, trail
    (-18, -10, 105), (-13, -14, 105),                        # heel kick
    (-5, -16, 85), (4, -15, 55), (12, -12, 28),              # knee drive
    (19, -8, 8), (23, -5, -6), (23, -2, -8),                 # reach, drop
]
GROUNDED_NEAR = [True] * 6 + [False] * 10

# Free (far) arm: swings with the near leg (contralateral to the far leg), so
# its fist is forward when the near foot reaches and back at near push-off.
def _arm_swing(i):
    s = math.cos(2 * math.pi * (i + 0.5) / N)
    dx = round(7 * s)
    dy = round(-3 * max(s, 0) + 1.5 * max(-s, 0))
    return dx, dy, s

HEAD_ROT = [0, -1, -1, 0, 1, 1, 1, 0] * 2           # slight nod, degrees CCW
TAIL_ROT = [6, 9, 8, 4, -1, -6, -9, -3] * 2         # + = tip down (whip on contact)
NET_ROT = [1, 3, 4, 3, 1, -1, -2, -1] * 2           # + = bag down, lags the body


def _points(rig, i, near, bob, lean, dy_fix=0.0):
    j = i if near else (i + 8) % N
    hx0, hy0 = rig.joint("hip", 0 if near else 1, 0)
    hip = (hx0 + lean, hy0 + bob)
    hx0 += BODY_DX  # toe path is relative to the body's mean position
    ground = rig.origin[1] - (LEG["foot_height"] / 2 + 1)
    tx, ty, a = TOE_NEAR[j]
    toe = (hx0 + tx, ground + ty + dy_fix)
    r = math.radians(a)
    ankle = (toe[0] - FOOT_LEN * math.cos(r), toe[1] - FOOT_LEN * math.sin(r))
    knee = ik2(hip, ankle, LEG["thigh"], LEG["shin"], bend=1)
    return hip, knee, ankle, toe, GROUNDED_NEAR[j]


def _leg_layer(rig, pts, z, far):
    kw = dict(foot="flat", toe_bump=0, spec=LEG)
    if far:
        return leg(rig, *pts[:4], z=z, fill=palette.PURPLE_DARK,
                   shade=palette.PURPLE_DEEP, shade_px=2, sole=palette.PURPLE_DEEP, **kw)
    return leg(rig, *pts[:4], z=z, shade_px=2, sole=palette.PURPLE_DEEP,
               light=palette.PURPLE_LIGHT, **kw)


def _lowest(layer):
    a = np.array(layer.image)[:, :, 3]
    return int(np.nonzero(a)[0].max())


def _leg(rig, i, near, bob, lean, z):
    pts = _points(rig, i, near, bob, lean)
    lay = _leg_layer(rig, pts, z, not near)
    if pts[4]:  # planted: put the lowest pixel exactly on the baseline
        fix = rig.origin[1] - _lowest(lay)
        if fix:
            pts = _points(rig, i, near, bob, lean, fix)
            lay = _leg_layer(rig, pts, z, not near)
    return pts, lay


def build(rig) -> Cycle:
    frames = []
    for i in range(N):
        bob, lean = BOB[i] + BODY_DY, LEAN[i] + BODY_DX
        lag = BOB[(i - 1) % N] + BODY_DY      # head/net trail the body by a frame
        llag = LEAN[(i - 1) % N] + BODY_DX
        layers = []
        far, far_l = _leg(rig, i, False, bob, lean, 20)
        near, near_l = _leg(rig, i, True, bob, lean, 28)
        layers += [far_l, near_l]
        # free arm: always behind the torso; the fist is in front of the
        # torso on the forward swing and tucked behind it on the back swing
        sdx, sdy, s = _arm_swing(i)
        hdx, hdy = lean + sdx, bob + sdy
        hand = rig.anchor("free_hand", hdx, hdy)
        sh = rig.joint("shoulder_far", lean, bob)
        spec = rig.limbs["arm"]
        elbow = ik2(sh, hand, spec["upper"], spec["fore"], bend=-1)
        layers.append(arm(rig, sh, elbow, hand, z=25, fill=palette.PURPLE_DARK,
                          shade=palette.PURPLE_DEEP, shade_px=1))
        hand_z = 40 if s > -0.2 else 24
        # parts
        layers.append(rig.render_part(Placed("tail", lean, bob, TAIL_ROT[i])))
        layers.append(rig.render_part(Placed("torso", lean, bob)))
        layers.append(rig.render_part(Placed("head", llag, lag, HEAD_ROT[i])))
        layers.append(rig.render_part(Placed("net", llag, lag, NET_ROT[i])))
        layers.append(rig.render_part(Placed("holding_hand", llag, lag)))
        layers.append(rig.render_part(Placed("free_hand", hdx, hdy, z=hand_z)))
        img = rig.compose(layers)
        rnd = lambda p: [round(v, 2) for v in p]
        meta = {
            "near": {"grounded": near[4], "hip": rnd(near[0]), "knee": rnd(near[1]),
                     "ankle": rnd(near[2]), "toe": rnd(near[3])},
            "far": {"grounded": far[4], "hip": rnd(far[0]), "knee": rnd(far[1]),
                    "ankle": rnd(far[2]), "toe": rnd(far[3])},
            "body_offset": [lean, bob],
        }
        label = "contact" if i in (0, 8) else ("flight" if i in (6, 7, 14, 15) else "")
        frames.append(Frame(img, label, MS, meta))
    return Cycle("snouty_run", frames, step_px=STEP,
                 notes={"gait": "near contact 0, far contact 8, flight 6-7 and 14-15",
                        "suggested_world_speed_px_s": STEP * 1000 / MS})
