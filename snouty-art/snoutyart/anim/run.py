"""Run cycle, 16 frames. Near-foot contact at 0, far-foot contact at 8; flight
at 6-7 and 14-15; planted toe travels STEP px per frame (toward -x).

Everything is in cell coordinates (96x96, origin (48,88), y down). The far leg
is the near leg's motion shifted by 8 frames and drawn behind the torso.
"""
from .. import palette
from ..cycle import Cycle, Frame
from ..limbs import arm, leg
from ..rig import Placed, ik2

N = 16
STEP = 6
MS = 40

# Vertical body offset per frame (positive = down). Lowest just after contact,
# highest in flight. Both halves identical so the loop is symmetric.
BOB_HALF = [0, 1, 2, 2, 1, 0, -2, -3]
BOB = BOB_HALF * 2

# Near-leg toe path relative to the hip's x. Frames 0-5 planted (6 px/frame),
# 6-7 push-off/lift, 8-15 swing forward through the air.
#          x rel hip, y rel ground (negative = up)
TOE_NEAR = [
    (22, 0), (16, 0), (10, 0), (4, 0), (-2, 0), (-8, 0),   # planted
    (-13, -3), (-15, -8),                                    # lift behind
    (-13, -13), (-8, -16), (-1, -17), (7, -15),              # swing
    (14, -11), (20, -7), (24, -4), (24, -2),                 # reach, drop to contact
]
# Ankle sits behind and above the toe; when the foot is swinging high it tucks.
ANKLE_OFF = [
    (-5, -3), (-5, -3), (-5, -3), (-5, -3), (-4, -3), (-3, -4),
    (-3, -5), (-3, -6),
    (-4, -5), (-5, -4), (-5, -3), (-5, -3), (-5, -3), (-5, -3), (-5, -3), (-5, -3),
]
GROUNDED_NEAR = [True] * 6 + [False] * 10

# Free (far) arm swings opposite the near leg. dx/dy applied to the hand pivot.
ARM_SWING = [(-6, 1), (-5, 0), (-3, -1), (0, -2), (3, -2), (5, -2), (6, -1), (6, 0),
             (6, 1), (5, 0), (3, -1), (0, -2), (-3, -2), (-5, -2), (-6, -1), (-6, 0)]
HEAD_ROT = [1, 0, -1, -1, 0, 1, 2, 2] * 2      # slight nod, degrees CCW
TAIL_ROT = [-4, -6, -8, -8, -6, -2, 4, 8] * 2   # tail down when body low, up in flight
NET_ROT = [1, 2, 3, 3, 2, 0, -2, -3] * 2


def _leg_points(rig, i, near: bool, bob: int):
    j = i if near else (i + 8) % N
    hx, hy = rig.joint("hip", 0 if near else 2, bob)
    # The toe point is the centre of the foot capsule; its lowest opaque pixel
    # (radius + outline) must land on the ground baseline when planted.
    ground = rig.origin[1] - (rig.limbs["leg"]["foot_width"] // 2 + 1)
    tx, ty = TOE_NEAR[j]
    toe = (hx + tx, ground + ty)
    ax, ay = ANKLE_OFF[j]
    ankle = (toe[0] + ax, toe[1] + ay)
    spec = rig.limbs["leg"]
    knee = ik2((hx, hy), ankle, spec["thigh"], spec["shin"], bend=1)
    return (hx, hy), knee, ankle, toe, GROUNDED_NEAR[j]


def build(rig) -> Cycle:
    frames = []
    for i in range(N):
        bob = BOB[i]
        lag = BOB[(i - 1) % N]  # head/net trail the body by a frame
        layers = []
        # legs
        far = _leg_points(rig, i, False, bob)
        near = _leg_points(rig, i, True, bob)
        layers.append(leg(rig, *far[:4], z=20, fill=palette.PURPLE_DARK,
                          shade=palette.PURPLE_DEEP, shade_px=2))
        layers.append(leg(rig, *near[:4], z=35))
        # free arm behind torso, hand in front
        sdx, sdy = ARM_SWING[i]
        hand = rig.anchor("free_hand", sdx, bob + sdy)
        sh = rig.joint("shoulder_far", 0, bob)
        spec = rig.limbs["arm"]
        elbow = ik2(sh, hand, spec["upper"], spec["fore"], bend=-1)
        layers.append(arm(rig, sh, elbow, hand, z=25, fill=palette.PURPLE_DARK,
                          shade=palette.PURPLE_DEEP, shade_px=1))
        # parts
        layers.append(rig.render_part(Placed("tail", 0, bob, TAIL_ROT[i])))
        layers.append(rig.render_part(Placed("torso", 0, bob)))
        layers.append(rig.render_part(Placed("head", 0, lag, HEAD_ROT[i])))
        layers.append(rig.render_part(Placed("net", 0, lag, NET_ROT[i])))
        layers.append(rig.render_part(Placed("holding_hand", 0, lag)))
        layers.append(rig.render_part(Placed("free_hand", sdx, bob + sdy)))
        img = rig.compose(layers)
        meta = {
            "near": {"grounded": near[4], "hip": near[0], "knee": [round(v, 2) for v in near[1]],
                     "ankle": near[2], "toe": near[3]},
            "far": {"grounded": far[4], "hip": far[0], "knee": [round(v, 2) for v in far[1]],
                    "ankle": far[2], "toe": far[3]},
            "body_offset": [0, bob],
        }
        label = "contact" if i in (0, 8) else ("flight" if i in (6, 7, 14, 15) else "")
        frames.append(Frame(img, label, MS, meta))
    return Cycle("snouty_run", frames, step_px=STEP,
                 notes={"gait": "near contact 0, far contact 8, flight 6-7 and 14-15",
                        "suggested_world_speed_px_s": STEP * 1000 / MS})
