"""Glean-style jump sheet, 12 frames (Study 04 semantics the badge cart relies on):

 0 stand, 1 dip, 2 crouch, 3 coil, 4 takeoff, 5 rise, 6 apex, 7 late apex,
 8 descent, 9 reach, 10 land, 11 recover.

Started from snoutyart/anim/jump.py and re-tuned for the Glean rig: big head,
short legs (thigh = shin = 10, width 7, 8 px paws), so the per-frame IK
segment lengths are shorter and the squash/stretch is carried more by the body
offset. The character is bouncier than Study 05: deeper crouch, higher apex
tuck, bigger tail and net swings, squashier land.

Frames 0-4 and 10-11 are grounded (lowest foot pixel on row 88). Frames 5-9
are airborne with the feet a few rows above 88; the cart adds its own
parabolic lift, and each frame's meta carries a suggested "lift" (px up).

The near arm is drawn from rig joint "shoulder_near" to the holding hand,
whose pivot follows the net pivot exactly (same dx, dy) so the fist never
slides on the handle. The hand is carried a few px above its reference spot
so the arm crosses the upper chest, above the Iris ring.

The torso may lean a few degrees (TORSO_ROT); hip, shoulders, neck and tail
root are rotated with it about the torso pivot so everything stays attached.
"""
import math

from snoutyart.cycle import Cycle, Frame
from snoutyart.limbs import arm, leg
from snoutyart.rig import Placed, ik2

MS = 60

LABELS = ["NEUTRAL STAND", "ANTICIPATION DIP", "DEEP CROUCH", "COILED PRE-LAUNCH",
          "TAKEOFF", "FAST RISE", "APEX HANG", "LATE APEX", "DESCENT",
          "PRE-LANDING REACH", "LAND", "RECOVER"]
GROUNDED = [True] * 5 + [False] * 5 + [True] * 2
LIFT = [0, 0, 0, 0, 0, 10, 26, 36, 34, 20, 0, 0]

# body (dx, dy): torso pivot offset. Positive dy = down.
BODY = [(0, 0), (1, 4), (0, 9), (4, 7), (3, -7), (1, -8), (0, -8), (0, -7),
        (0, -6), (0, -8), (1, 8), (1, 2)]
# torso lean in degrees (CCW positive: negative leans forward)
TORSO_ROT = [0, -2, 0, -4, -3, 3, 2, 0, -2, -3, -3, -1]
# head offset relative to the (rotated) neck
HEAD_OFF = [(0, 0), (1, 1), (0, 3), (2, 1), (1, 1), (1, 1), (1, 1), (0, 1),
            (0, 0), (0, 0), (1, 2), (1, 1)]
HEAD_ROT = [0, -2, -4, 3, 3, 4, 4, 1, 0, 1, -3, -1]
TAIL_ROT = [0, -5, -9, -14, 6, 12, 14, 4, -6, -10, 12, 4]
# net pivot offset relative to the body (the holding hand uses the same offset)
NET_OFF = [(0, -7), (0, -6), (-1, -5), (-3, -6), (1, -7), (1, -5), (0, -7), (0, -7),
           (0, -7), (1, -8), (2, -4), (0, -6)]
NET_ROT = [0, 4, 6, 12, -8, -14, -10, -4, -8, -2, 12, 4]
# free (far) hand offset from its reference pivot, relative to the body
HAND = [(0, 0), (1, 0), (4, -3), (-9, 3), (4, -6), (6, -8), (6, -9), (5, -7),
        (5, -10), (4, -4), (5, -2), (1, 0)]

# free hand z: tucked behind the tee when the arm swings back in the coil
HAND_Z = [None, None, None, 22, None, None, None, None, None, None, None, None]

# hip x offsets from the (rotated) hip joint, near and far leg
NEAR_HIP_DX = [1, 1, 1, 0, 0, -1, -1, 0, 0, 1, 1, 1]
# near leg z: behind the tee (28) when squashed so the knee tucks under the
# hem and the Iris ring stays visible; in front (35) otherwise
NEAR_Z = [28] * 12
FAR_HIP_DX = [-3, -3, -3, -3, -2, -5, -5, -4, -4, -3, -3, -3]

# legs: toe (x rel own hip, y rel ground where 0 = planted), ankle offset from
# toe, IK segment length (thigh = shin).
NEAR_TOE = [(8, 0), (9, 0), (13, 0), (7, 0), (-4, 0), (6, -6), (9, -9), (8, -7),
            (7, -5), (13, -2), (14, 0), (9, 0)]
NEAR_ANK = [(-5, -3), (-5, -3), (-5, -2), (-3, -5), (-2, -5), (-3, -4), (-4, -3), (-3, -4),
            (-3, -4), (-5, -3), (-6, -2), (-5, -3)]
FAR_TOE = [(-1, 0), (-1, 0), (0, 0), (-1, 0), (-10, 0), (-8, -3), (-3, -9), (-5, -6),
           (-7, -4), (-6, -2), (-8, 0), (-2, 0)]
FAR_ANK = [(-5, -3), (-5, -3), (-5, -2), (-4, -4), (-2, -5), (2, -4), (-2, -3), (0, -4),
           (0, -4), (-3, -3), (-5, -2), (-5, -3)]
NEAR_SEG = [7, 6.5, 5.5, 5.5, 8.5, 7, 6, 6.5, 7, 9.5, 6, 6.5]
FAR_SEG = [7, 6.5, 6, 6, 8.5, 8, 6, 7, 8, 8.5, 6, 6.5]

TABLES = (BODY, TORSO_ROT, HEAD_OFF, HEAD_ROT, TAIL_ROT, NET_OFF, NET_ROT, HAND, HAND_Z,
          NEAR_HIP_DX, FAR_HIP_DX, NEAR_Z, NEAR_TOE, NEAR_ANK, FAR_TOE, FAR_ANK, NEAR_SEG, FAR_SEG)


def _rot_about(pt, piv, deg):
    """Rotate pt about piv by deg, CCW positive on screen (y down)."""
    a = math.radians(deg)
    x, y = pt[0] - piv[0], pt[1] - piv[1]
    return (piv[0] + x * math.cos(a) + y * math.sin(a),
            piv[1] - x * math.sin(a) + y * math.cos(a))


def _body_joint(rig, i, name_or_pt):
    """Cell position of a body-attached point (joint name or cell point at rest)
    after the frame's torso lean and body offset."""
    bx, by = BODY[i]
    piv = rig.anchor("torso")
    pt = rig.joint(name_or_pt) if isinstance(name_or_pt, str) else name_or_pt
    x, y = _rot_about(pt, piv, TORSO_ROT[i])
    return (x + bx, y + by)


def _ioff(rig, i, rest_pt):
    """Integer offset that moves a rest point to where the leaning body carries it."""
    x, y = _body_joint(rig, i, rest_pt)
    return (round(x - rest_pt[0]), round(y - rest_pt[1]))


def _leg(rig, i, near):
    hx, hy = _body_joint(rig, i, "hip")
    hx = round(hx) + (NEAR_HIP_DX if near else FAR_HIP_DX)[i]
    hy = round(hy)
    ground = rig.origin[1] - (rig.limbs["leg"]["foot_width"] // 2 + 1)
    tx, ty = (NEAR_TOE if near else FAR_TOE)[i]
    ax, ay = (NEAR_ANK if near else FAR_ANK)[i]
    toe = (hx + tx, ground + ty)
    ankle = (toe[0] + ax, toe[1] + ay)
    seg = (NEAR_SEG if near else FAR_SEG)[i]
    knee = ik2((hx, hy), ankle, seg, seg, bend=1)
    return (hx, hy), knee, ankle, toe


def build(rig) -> Cycle:
    assert all(len(t) == 12 for t in TABLES)
    frames = []
    for i in range(12):
        layers = []
        far = _leg(rig, i, False)
        near = _leg(rig, i, True)
        layers.append(leg(rig, *far, z=20, fill=rig.pal.FUR_DARK,
                          shade=rig.pal.FUR_DEEP, shade_px=2))
        layers.append(leg(rig, *near, z=NEAR_Z[i]))

        # parts carried by the leaning body
        tdx, tdy = _ioff(rig, i, rig.anchor("tail"))
        ndx, ndy = _ioff(rig, i, rig.joint("neck"))
        sdx, sdy = _ioff(rig, i, rig.anchor("holding_hand"))
        fdx, fdy = _ioff(rig, i, rig.anchor("free_hand"))
        bx, by = BODY[i]

        # far arm (behind the torso) to the free hand
        hdx, hdy = HAND[i]
        fh = (fdx + hdx, fdy + hdy)
        hand = rig.anchor("free_hand", *fh)
        sh = _body_joint(rig, i, "shoulder_far")
        spec = rig.limbs["arm"]
        elbow = ik2(sh, hand, spec["upper"], spec["fore"], bend=-1)
        layers.append(arm(rig, sh, elbow, hand, z=25, fill=rig.pal.FUR_DARK,
                          shade=rig.pal.FUR_DEEP, shade_px=1))

        # near arm to the holding hand; hand pivot == net pivot offset
        nx, ny = NET_OFF[i]
        net = (sdx + nx, sdy + ny)
        hold = rig.anchor("holding_hand", *net)
        shn = _body_joint(rig, i, "shoulder_near")
        elbow_n = ik2(shn, hold, spec["upper"], spec["fore"], bend=1)
        layers.append(arm(rig, shn, elbow_n, hold, z=45, fill=rig.pal.FUR))

        hx_, hy_ = HEAD_OFF[i]
        layers.append(rig.render_part(Placed("tail", tdx, tdy, TAIL_ROT[i])))
        layers.append(rig.render_part(Placed("torso", bx, by, TORSO_ROT[i])))
        layers.append(rig.render_part(Placed("head", ndx + hx_, ndy + hy_, HEAD_ROT[i])))
        layers.append(rig.render_part(Placed("net", *net, NET_ROT[i])))
        layers.append(rig.render_part(Placed("holding_hand", *net)))
        layers.append(rig.render_part(Placed("free_hand", *fh, z=HAND_Z[i])))
        img = rig.compose(layers)
        r = lambda p: [round(v, 2) for v in p]
        meta = {
            "grounded": GROUNDED[i],
            "lift": LIFT[i],
            "body_offset": [bx, by],
            "torso_rot": TORSO_ROT[i],
            "net_offset": list(net),
            "near": {"hip": near[0], "knee": r(near[1]), "ankle": near[2], "toe": near[3]},
            "far": {"hip": far[0], "knee": r(far[1]), "ankle": far[2], "toe": far[3]},
            "near_arm": {"shoulder": r(shn), "elbow": r(elbow_n), "hand": list(hold)},
        }
        frames.append(Frame(img, LABELS[i], MS, meta))
    return Cycle("snouty_jump", frames, playback="forward, once per jump; hold 0 when idle",
                 step_px=None, grid_columns=6,
                 notes={"grounded_frames": [i for i, g in enumerate(GROUNDED) if g],
                        "airborne_frames": [i for i, g in enumerate(GROUNDED) if not g],
                        "lift_px": LIFT})
