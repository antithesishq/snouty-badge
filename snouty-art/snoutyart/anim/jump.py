"""Jump sheet, 12 frames (Study 04 semantics the badge cart relies on):

 0 stand, 1 dip, 2 crouch, 3 coil, 4 takeoff, 5 rise, 6 apex, 7 late apex,
 8 descent, 9 reach, 10 land, 11 recover.

Frames 0-4 and 10-11 are grounded (lowest foot pixel on row 88). Frames 5-9
are airborne: legs tucked or reaching inside the cell with the feet a few rows
above 88; the cart adds its own parabolic lift, and each frame's meta carries a
suggested "lift" (px up) used by the scrolling preview.

Cell coordinates (96x96, origin (48,88), y down). Per frame: body offset, part
rotations, near/far hip x, toe and ankle, and a per-frame segment length for the leg
IK (shorter than the rig's 14 px when the leg should read as straightened,
since the full 28 px leg never fits between hip and ground in this cell).
"""
from .. import palette
from ..cycle import Cycle, Frame
from ..limbs import arm, leg
from ..rig import Placed, ik2

MS = 60

LABELS = ["NEUTRAL STAND", "ANTICIPATION DIP", "DEEP CROUCH", "COILED PRE-LAUNCH",
          "TAKEOFF", "FAST RISE", "APEX HANG", "LATE APEX", "DESCENT",
          "PRE-LANDING REACH", "LAND", "RECOVER"]
GROUNDED = [True] * 5 + [False] * 5 + [True] * 2
LIFT = [0, 0, 0, 0, 0, 10, 26, 36, 34, 20, 0, 0]

# name: per-frame values, index = frame
# body (dx, dy): torso/tail. Positive dy = down.
BODY = [(0, 0), (1, 3), (1, 5), (2, 8), (1, -6), (0, -6), (0, -5), (0, -3),
        (0, -5), (0, -7), (1, 7), (1, 2)]
# head and net follow the body with an extra (dx, dy) lag/lead
HEAD_OFF = [(0, 0), (1, 1), (1, 1), (2, 2), (1, -1), (1, 0), (1, 1), (0, 1),
            (0, 0), (0, -1), (0, -1), (1, 1)]
NET_OFF = [(0, 0), (0, 1), (0, 2), (0, 2), (0, -1), (0, -1), (0, 1), (0, 2),
           (0, 1), (0, -1), (2, 3), (0, 1)]
HEAD_ROT = [0, -2, -2, -4, 2, 3, 4, 0, 0, 1, 0, -1]
TAIL_ROT = [0, -4, -7, -12, 4, 10, 12, 6, 2, -2, -12, -4]
# coil drops the net a further 4 degrees than the crouch; the land throws it
# forward/down with the bag's momentum (+12, dx +2).
NET_ROT = [0, 3, 4, 8, -4, -6, -4, -2, 4, 2, 12, 2]
# free (far) hand offset from its reference pivot, relative to the body
HAND = [(0, 0), (0, 2), (-1, 3), (-4, 3), (4, -5), (6, -8), (7, -9), (6, -7),
        (4, -4), (3, -2), (4, 1), (0, 1)]

# hip x offsets from the body (near leg, far leg). The near hip moves 1-2 px
# back where the thigh would otherwise cover the Iris emblem (moving it right
# covered more, because the knee then rises across the belly). The far hip sits
# 4 px behind the near hip in the air so the dark trailing leg shows.
NEAR_HIP_DX = [0, 0, -2, -2, 0, -2, -2, -1, 0, 0, -2, 0]
FAR_HIP_DX = [2, 2, 2, 2, 2, -6, -6, -4, -4, -1, 2, 2]

# legs: toe (x rel own hip, y rel ground where 0 = planted), ankle offset from
# toe, IK segment length (thigh = shin).
NEAR_TOE = [(9, 0), (9, 0), (8, 0), (4, 0), (2, 0), (6, -7), (8, -8), (5, -5),
            (5, -3), (12, -3), (14, 0), (9, 0)]
NEAR_ANK = [(-5, -3), (-5, -3), (-5, -3), (-5, -3), (1, -5), (1, -4), (1, -4), (0, -5),
            (-1, -5), (-4, -3), (-6, -2), (-5, -3)]
FAR_TOE = [(-3, 0), (-3, 0), (-2, 0), (-1, 0), (-5, 0), (-8, -3), (-8, -4), (-8, -3),
           (-4, -2), (-7, -3), (-7, 0), (-3, 0)]
FAR_ANK = [(-5, -3), (-5, -3), (-5, -3), (-5, -3), (2, -5), (4, -3), (4, -3), (4, -3),
           (2, -5), (-3, -3), (-4, -2), (-5, -3)]
NEAR_SEG = [6.5, 6.5, 6, 5.5, 9, 6, 6, 7, 8, 10.5, 5.5, 7]
FAR_SEG = [7.5, 7.5, 7, 6, 9, 9, 9, 9, 8, 9, 7, 7.5]


def _leg(rig, i, near):
    bx, by = BODY[i]
    hx, hy = rig.joint("hip", bx + (NEAR_HIP_DX if near else FAR_HIP_DX)[i], by)
    ground = rig.origin[1] - (rig.limbs["leg"]["foot_width"] // 2 + 1)
    tx, ty = (NEAR_TOE if near else FAR_TOE)[i]
    ax, ay = (NEAR_ANK if near else FAR_ANK)[i]
    toe = (hx + tx, ground + ty)
    ankle = (toe[0] + ax, toe[1] + ay)
    seg = (NEAR_SEG if near else FAR_SEG)[i]
    knee = ik2((hx, hy), ankle, seg, seg, bend=1)
    return (hx, hy), knee, ankle, toe


def build(rig) -> Cycle:
    assert all(len(t) == 12 for t in (BODY, HEAD_OFF, NET_OFF, HEAD_ROT, TAIL_ROT, NET_ROT,
                                      HAND, NEAR_TOE, NEAR_ANK, FAR_TOE, FAR_ANK, NEAR_SEG, FAR_SEG,
                                      NEAR_HIP_DX, FAR_HIP_DX))
    frames = []
    for i in range(12):
        bx, by = BODY[i]
        layers = []
        far = _leg(rig, i, False)
        near = _leg(rig, i, True)
        layers.append(leg(rig, *far, z=20, fill=palette.PURPLE_DARK,
                          shade=palette.PURPLE_DEEP, shade_px=2))
        layers.append(leg(rig, *near, z=35))
        hdx, hdy = HAND[i]
        hand = rig.anchor("free_hand", bx + hdx, by + hdy)
        sh = rig.joint("shoulder_far", bx, by)
        spec = rig.limbs["arm"]
        elbow = ik2(sh, hand, spec["upper"], spec["fore"], bend=-1)
        layers.append(arm(rig, sh, elbow, hand, z=25, fill=palette.PURPLE_DARK,
                          shade=palette.PURPLE_DEEP, shade_px=1))
        hx_, hy_ = HEAD_OFF[i]
        nx, ny = NET_OFF[i]
        layers.append(rig.render_part(Placed("tail", bx, by, TAIL_ROT[i])))
        layers.append(rig.render_part(Placed("torso", bx, by)))
        layers.append(rig.render_part(Placed("head", bx + hx_, by + hy_, HEAD_ROT[i])))
        layers.append(rig.render_part(Placed("net", bx + nx, by + ny, NET_ROT[i])))
        layers.append(rig.render_part(Placed("holding_hand", bx + nx, by + ny)))
        layers.append(rig.render_part(Placed("free_hand", bx + hdx, by + hdy)))
        img = rig.compose(layers)
        r = lambda p: [round(v, 2) for v in p]
        meta = {
            "grounded": GROUNDED[i],
            "lift": LIFT[i],
            "body_offset": [bx, by],
            "near": {"hip": near[0], "knee": r(near[1]), "ankle": near[2], "toe": near[3]},
            "far": {"hip": far[0], "knee": r(far[1]), "ankle": far[2], "toe": far[3]},
        }
        frames.append(Frame(img, LABELS[i], MS, meta))
    return Cycle("snouty_jump", frames, playback="forward, once per jump; hold 0 when idle",
                 step_px=None, grid_columns=6,
                 notes={"grounded_frames": [i for i, g in enumerate(GROUNDED) if g],
                        "airborne_frames": [i for i, g in enumerate(GROUNDED) if not g],
                        "lift_px": LIFT})
