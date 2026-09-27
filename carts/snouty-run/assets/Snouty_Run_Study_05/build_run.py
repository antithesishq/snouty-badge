#!/usr/bin/env python3
"""Build the Snouty run study. Requires Python 3.10+, Pillow and NumPy.

Artwork is derived from the supplied Snouty reference. Motion is a new,
16-frame, two-foot cycle, not a reordering of the original eight images.
All final sprite drawing is at native resolution without antialiasing.
"""
from __future__ import annotations
import json
import math
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent
ASSETS = ROOT / 'assets'
FRAMES = ROOT / 'frames'
ASSETS.mkdir(exist_ok=True)
FRAMES.mkdir(exist_ok=True)
W = H = 96
N = 16
DURATION_MS = 40
GROUND_Y = 88
SCROLL = 6
ORIGIN = np.array([6.0, 3.0])
PALETTE_HEX = ['17121e','29232f','42364b','462174','662bb8','8e42de',
               'be7af3','f4efdf','958d9d','ee453c','91322f','60391f',
               '99622f','cd934b','f0c37c']
COLORS = [tuple(bytes.fromhex(c)) + (255,) for c in PALETTE_HEX]
INK, CLOTH, CLOTH_LIGHT, PURPLE_DARK, PURPLE_MID, PURPLE, PURPLE_LIGHT, WHITE, GRAY, RED, RED_DARK, WOOD_DARK, WOOD, TAN, TAN_LIGHT = COLORS

def blank(size=(W,H)):
    return Image.new('RGBA', size, (0,0,0,0))

def ir(p):
    return tuple(int(round(float(v))) for v in p)

def cut_polygon(im, points):
    mask=Image.new('L', im.size)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    arr=np.array(im)
    arr[:,:,3]=np.minimum(arr[:,:,3],np.array(mask))
    arr[arr[:,:,3]==0]=0
    return Image.fromarray(arr)

def prep_reference(source):
    src=Image.open(source).convert('RGBA').resize((80,86),Image.Resampling.BOX)
    a=np.array(src)
    pal=np.array(COLORS,dtype=np.float32)[:,:3]
    distances=((a[:,:,:3].astype(np.float32)[:,:,None,:]-pal[None,None,:,:])**2).sum(axis=-1)
    a[:,:,:3]=pal[distances.argmin(axis=-1)].astype(np.uint8)
    a[:,:,3]=np.where(a[:,:,3]>144,255,0)
    a[a[:,:,3]==0]=0
    base=Image.fromarray(a)
    head=cut_polygon(base,[(38,13),(66,13),(66,29),(80,29),(80,47),
                           (55,48),(45,48),(38,42),(35,36),(38,26)])
    # Eye cleanup: deliberate pixel clusters, rather than blended source edges.
    d=ImageDraw.Draw(head)
    d.polygon([(52,25),(56,25),(58,27),(58,32),(56,34),(52,34),(50,32),(50,27)],fill=INK)
    d.polygon([(52,26),(55,26),(57,28),(57,31),(55,33),(52,33),(51,31),(51,28)],fill=WHITE)
    d.line([(52,33),(55,33),(57,31)],fill=GRAY,width=1)
    d.rectangle((54,28,56,31),fill=INK)
    d.point((54,28),fill=WHITE)
    basket=cut_polygon(base,[(0,0),(36,0),(36,25),(32,29),(29,32),(0,34)])
    # Remove source-shirt fragments from the prop; redraw one continuous shaft.
    net=blank((80,86));nd=ImageDraw.Draw(net)
    nd.polygon([(26,28),(29,28),(37,44),(34,46)],fill=INK)
    nd.polygon([(27,29),(28,29),(35,43),(35,44),(34,43)],fill=WOOD)
    nd.line([(27,30),(33,41)],fill=TAN,width=1)
    net.alpha_composite(basket)
    tail=cut_polygon(base,[(0,45),(15,47),(19,51),(28,51),(28,59),(26,65),
                           (18,67),(0,64)])
    holding_hand=cut_polygon(base,[(34,40),(38,40),(41,43),(41,48),
                                   (38,51),(34,50),(31,46),(31,43)]).crop((30,39,43,52))
    free_hand=cut_polygon(base,[(59,49),(63,49),(66,52),(66,55),
                                (63,58),(59,57),(57,54),(57,51)]).crop((56,48,68,60))
    for name,im in [('head',head),('net',net),('tail',tail),
                    ('holding_hand',holding_hand),('free_hand',free_hand)]:
        im.save(ASSETS/f'{name}.png')
    base.save(ASSETS/'reference_on_grid.png')

# Only the first build needs the uploaded input; subsequent builds use assets/.
if not (ASSETS/'head.png').exists():
    original=Path('/mnt/data/snouty_work/snouty_run_v4/frames/frame_00.png')
    if not original.exists():
        raise FileNotFoundError('Extract reference frame_00.png first, or keep the supplied assets/ folder.')
    prep_reference(original)
head=Image.open(ASSETS/'head.png').convert('RGBA')
net=Image.open(ASSETS/'net.png').convert('RGBA')
tail=Image.open(ASSETS/'tail.png').convert('RGBA')
holding_hand=Image.open(ASSETS/'holding_hand.png').convert('RGBA')
free_hand=Image.open(ASSETS/'free_hand.png').convert('RGBA')

# Pixel offsets for the torso. Second step is intentionally not a duplicate.
BOB=[0,2,2,1,0,-1,-3,-2,0,1,2,1,-1,-2,-3,-1]
LEAN_X=[0,0,0,0,1,1,1,0,0,0,0,1,1,1,1,0]
NET_ANGLE=[-2,-1,0,2,3,2,0,-2,-3,-1,1,2,2,1,-1,-2]
HAND_X=[60,61,62,64,65,66,66,65,64,63,62,61,60,59,59,60]
HAND_Y=[54,54,53,52,51,50,50,51,52,53,54,55,55,55,54,54]
# Flight path of the ankle: the heel folds back, passes through, then reaches.
RECOVERY_NEAR=[(35,76,1.05),(36,71,1.25),(40,72,1.15),(45,75,.85),
               (50,77,.5),(56,77,.10),(62,77,-.2),(67,79,-.22),
               (68,81,-.12),(67,83,-.05)]
RECOVERY_FAR=[(36,77,1.0),(38,73,1.12),(42,74,1.02),(47,76,.73),
              (51,78,.43),(57,78,.12),(62,78,-.12),(66,79,-.17),
              (67,81,-.09),(66,83,-.02)]
STANCE_ANGLE=[0,0,0,.06,.30,.75]


def rot(p, angle):
    c,s=math.cos(angle),math.sin(angle)
    return np.array([p[0]*c-p[1]*s,p[0]*s+p[1]*c])

def foot_pose(i, far=False):
    q=(i-8)%N if far else i
    if q<=5:
        # The toe is fixed in world space: in the camera-relative frames it
        # travels left at exactly the same rate as the preview ground.
        theta=STANCE_ANGLE[q]
        toe=np.array([(69 if far else 70)-SCROLL*q, GROUND_Y],dtype=float)
        ankle=toe-rot((5,3),theta)
        return ankle,theta,True,q,toe
    x,y,theta=(RECOVERY_FAR if far else RECOVERY_NEAR)[q-6]
    ankle=np.array([x,y],dtype=float)
    return ankle,theta,False,q,ankle+rot((5,3),theta)

def knee_for(hip,ankle,upper=12.5,lower=12.5):
    delta=ankle-hip
    length=float(np.linalg.norm(delta))
    if length>upper+lower+0.001:
        raise ValueError(f'Unreachable ankle: distance {length:.3f}')
    unit=delta/max(length,1e-6)
    a=(upper*upper-lower*lower+length*length)/(2*max(length,1e-6))
    height=math.sqrt(max(0,upper*upper-a*a))
    normal=np.array([unit[1],-unit[0]])
    return hip+unit*a+normal*height

def thick_path(draw,points,radii,fill):
    # Polygon segments and integer circular caps, never antialiased.
    for j in range(len(points)-1):
        p,q=np.asarray(points[j],float),np.asarray(points[j+1],float)
        v=q-p; length=float(np.linalg.norm(v))
        if length<.01: continue
        n=np.array([-v[1],v[0]])/length
        polygon=[p+n*radii[j],q+n*radii[j+1],q-n*radii[j+1],p-n*radii[j]]
        draw.polygon([ir(v) for v in polygon],fill=fill)
    for p,r in zip(points,radii):
        x,y=p
        draw.ellipse((round(x-r),round(y-r),round(x+r),round(y+r)),fill=fill)

def leg(i,far=False):
    hip=np.array([52.0 if far else 50.0,67.0])+np.array([LEAN_X[i],BOB[i]])
    ankle,theta,contact,q,toe=foot_pose(i,far)
    knee=knee_for(hip,ankle)
    mask=Image.new('L',(W,H))
    d=ImageDraw.Draw(mask)
    thick_path(d,[hip,knee,ankle],[4.2 if not far else 3.8,3.0,2.0],255)
    foot_points=[(-3,-1),(-1,-3),(2,-2),(3,0),(6,1),(6,2),(5,3),(-2,3),(-3,2)]
    d.polygon([ir(ankle+rot(p,theta)) for p in foot_points],fill=255)
    # Dilate by one pixel to give a stable, single-pixel silhouette outline.
    outline=mask.filter(ImageFilter.MaxFilter(3))
    layer=blank(); layer.paste(INK,(0,0,W,H),outline)
    shade=PURPLE_DARK if far else PURPLE_MID
    light=PURPLE_MID if far else PURPLE
    layer.paste(shade,(0,0,W,H),mask)
    paint=blank(); pd=ImageDraw.Draw(paint)
    thick_path(pd,[hip+(-.7,-1),knee+(-.8,-1.2),ankle+(-.5,-1)], [2.7,1.9,.8],light)
    pd.polygon([ir(ankle+rot(p,theta)) for p in [(-1,-2),(2,-1),(3,1),(5,1),(5,2),(0,2),(-1,1)]],fill=light)
    if not far:
        # Sparse highlight, no smooth gradient and no shading on the outline.
        h1=hip*.62+knee*.38+np.array([-1.2,-1.4])
        h2=hip*.24+knee*.76+np.array([-1.2,-1.4])
        pd.line([ir(h1),ir(h2)],fill=PURPLE_LIGHT,width=1)
    pa=np.array(paint); ma=np.array(mask)
    pa[:,:,3]=np.minimum(pa[:,:,3],ma)
    layer.alpha_composite(Image.fromarray(pa))
    # Short toe crease rotates with the foot, helping each foot read as a foot.
    ld=ImageDraw.Draw(layer)
    c1=ankle+rot((3,1),theta);c2=ankle+rot((3,2),theta)
    ld.line([ir(c1),ir(c2)],fill=PURPLE_DARK if far else INK,width=1)
    # Floor is the bottom pixel, not the geometric center of an outline.
    arr=np.array(layer);arr[GROUND_Y+1:]=0
    if contact:
        px=int(round(toe[0]));arr[GROUND_Y,px]=INK
    layer=Image.fromarray(arr)
    metadata={'phase':q,'grounded':contact,'hip':[round(v,3) for v in hip],
              'knee':[round(v,3) for v in knee],'ankle':[round(v,3) for v in ankle],
              'toe':[round(v,3) for v in toe]}
    return layer,metadata


def tail_for(i):
    arr=np.array(tail);result=np.zeros_like(arr)
    phase=2*math.pi*i/N
    amplitude=2.0*math.sin(2*phase-1.25)+.65*math.sin(phase+.3)
    # Shift the visible tail forward so it reads as attaching at the pelvis
    # tucked under the sweatshirt, while preserving clearance in stride.
    x_shift=3
    y_bias=0
    for x in range(arr.shape[1]):
        influence=max(0,min(1,(28-x)/24))**1.2
        shift=round(amplitude*influence)+y_bias
        ys=np.where(arr[:,x,3]>0)[0]
        for y in ys:
            xx=x+x_shift
            yy=y+shift
            if 0<=xx<arr.shape[1] and 0<=yy<arr.shape[0]:result[yy,xx]=arr[y,x]
    return Image.fromarray(result)


def torso():
    im=blank((80,86));d=ImageDraw.Draw(im)
    outline=[(37,30),(44,33),(51,38),(56,41),(59,46),(61,51),(61,56),
             (59,62),(56,65),(50,67),(39,67),(33,65),(29,63),(27,60),
             (28,56),(28,52),(25,50),(24,47),(26,42),(29,38),(33,34)]
    d.polygon(outline,fill=INK)
    inside=[(37,32),(43,35),(50,40),(54,42),(57,47),(59,51),(59,57),
            (57,62),(54,64),(49,65),(39,65),(33,63),(30,61),(29,57),
            (31,51),(27,49),(26,46),(28,42),(30,38),(34,35)]
    d.polygon(inside,fill=CLOTH)
    d.polygon([(37,33),(43,36),(48,40),(50,44),(47,44),(42,41),(36,37),
               (31,40),(27,44),(26,43),(30,38),(34,35)],fill=CLOTH_LIGHT)
    d.polygon([(31,51),(33,48),(38,50),(35,55),(35,61),(41,65),
               (33,63),(29,61),(29,57)],fill=INK)
    d.polygon([(56,49),(59,51),(59,57),(57,62),(54,64),(48,65),
               (49,63),(54,61),(56,56)],fill=INK)
    d.line([(36,63),(42,64),(48,64)],fill=CLOTH_LIGHT,width=1)
    # Pixel-art chest logo updated to better match the supplied Antithesis mark.
    logo_rows=[
        '..######...',
        '.#######...',
        '###........',
        '##..###..##',
        '##.#####.##',
        '##.#####.##',
        '##.#####.##',
        '##..###..##',
        '........###',
        '...#######.',
        '...######..',
    ]
    ox,oy=43,51
    for yy,row in enumerate(logo_rows):
        for xx,ch in enumerate(row):
            if ch=='#':
                d.point((ox+xx,oy+yy),fill=RED)
    # A dark fold/cuff separates the hand and the net handle from the tunic.
    d.polygon([(30,41),(31,40),(35,43),(39,45),(38,50),(34,52),
               (31,49),(29,46)],fill=INK)
    d.polygon([(31,42),(31,41),(34,44),(37,46),(36,49),(33,50),
               (31,48),(31,45)],fill=CLOTH)
    return im
TORSO=torso()
TORSO.save(ASSETS/'torso.png')


def render_frame(i):
    result=blank()
    offset=ORIGIN+np.array([LEAN_X[i],BOB[i]])
    rear,rear_meta=leg(i,True)
    front,front_meta=leg(i,False)
    result.alpha_composite(rear)
    result.alpha_composite(tail_for(i),ir(offset))
    result.alpha_composite(front)
    # Prop rotates about the grip. Local lag is independent of torso bob.
    prop=net.rotate(NET_ANGLE[i],resample=Image.Resampling.NEAREST,
                    expand=False,center=(36,45))
    lag=max(-1,min(1,BOB[(i-1)%N]-BOB[i]))
    result.alpha_composite(TORSO,ir(offset))
    # The shaft crosses the front of the sleeve and finishes under the grip.
    result.alpha_composite(prop,ir(offset+np.array([0,lag])))
    # The free arm counter-swings while the other arm holds the net.
    arm=blank((80,86));ad=ImageDraw.Draw(arm)
    hand=np.array([HAND_X[i],HAND_Y[i]],float)
    shoulder=np.array([54.0,44.0])
    elbow=np.array([58.0+(HAND_X[i]-62)*.28,49.0])
    thick_path(ad,[shoulder,elbow,hand],[3.4,2.8,2.3],INK)
    thick_path(ad,[shoulder+(-.5,-.5),elbow+(-.5,-.5),hand],[2.0,1.4,1.3],CLOTH)
    arm.alpha_composite(free_hand,ir(hand-np.array([6,6])))
    result.alpha_composite(arm,ir(offset))
    # Small delayed head settle; neck stays well overlapped with the collar.
    head_dy=[0,-1,0,0,0,0,1,1,0,0,0,0,0,1,1,0][i]
    result.alpha_composite(head,ir(offset+np.array([0,head_dy])))
    result.alpha_composite(holding_hand,ir(offset+np.array([30,39])))
    a=np.array(result)
    # Canonical transparent pixels and binary alpha are part of the asset spec.
    a[:,:,3]=np.where(a[:,:,3]>127,255,0)
    a[a[:,:,3]==0]=0
    result=Image.fromarray(a)
    return result,{'near':front_meta,'far':rear_meta,
                  'body_offset':[LEAN_X[i],BOB[i]],'net_degrees':NET_ANGLE[i]}


def font(size):
    for p in ['/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
              '/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf']:
        if Path(p).exists():return ImageFont.truetype(p,size)
    return ImageFont.load_default()

def gif_palette(extra):
    entries=[(0,0,0)]+[c[:3] for c in COLORS]+list(extra)
    return [v for c in entries for v in c]+[0]*(768-len(entries)*3)

def save_gif(images,path,duration=DURATION_MS,extra=(),transparent=False):
    palette=gif_palette(extra)
    # A single global palette eliminates temporal palette/shading fluctuations.
    lookup=Image.new('P',(1,1));lookup.putpalette(palette)
    converted=[]
    for im in images:
        alpha=np.array(im.convert('RGBA'))[:,:,3]
        p=im.convert('RGB').quantize(palette=lookup,dither=Image.Dither.NONE)
        if transparent:
            a=np.array(p);a[alpha==0]=0;p=Image.fromarray(a,'P');p.putpalette(palette)
        converted.append(p)
    kwargs=dict(save_all=True,append_images=converted[1:],duration=duration,
                loop=0,disposal=2,optimize=False)
    if transparent:kwargs['transparency']=0
    converted[0].save(path,**kwargs)


def build_previews(frames):
    bg=(225,230,220);floor=(160,175,158);dark=(121,144,123);light=(243,246,236)
    preview=[];isolated=[];diagnostic=[]
    for i,im in enumerate(frames):
        scene=Image.new('RGBA',(144,108),bg+(255,))
        sd=ImageDraw.Draw(scene)
        ground=GROUND_Y+4
        sd.line((0,ground+1,143,ground+1),fill=floor+(255,),width=1)
        # Ground is periodic every 32 px; 16*6=96 wraps it exactly.
        for start in range(-64,208,32):
            x=start-SCROLL*i%32
            sd.rectangle((x,ground+6,x+8,ground+6),fill=floor+(255,))
            sd.point((x+18,ground+10),fill=dark+(255,))
            sd.rectangle((x+26,ground+4,x+28,ground+4),fill=light+(255,))
        scene.alpha_composite(im,(24,4))
        preview.append(scene.resize((576,432),Image.Resampling.NEAREST))
        flat=Image.new('RGBA',(112,104),bg+(255,));flat.alpha_composite(im,(8,4))
        isolated.append(flat.resize((448,416),Image.Resampling.NEAREST))
    save_gif(preview,ROOT/'snouty_run_preview.gif',extra=[bg,floor,dark,light])
    save_gif(isolated,ROOT/'snouty_run_isolated.gif',extra=[bg])
    save_gif(frames,ROOT/'snouty_run_native_transparent.gif',transparent=True)
    save_gif(preview,ROOT/'snouty_run_slow.gif',duration=100,extra=[bg,floor,dark,light])
    # Native-resolution APNG preserves exact RGBA rather than relying on GIF.
    frames[0].save(ROOT/'snouty_run.png',save_all=True,append_images=frames[1:],
                   duration=DURATION_MS,loop=0,disposal=0,blend=0)


def contact_sheet(frames,meta):
    cw,ch=248,242
    out=Image.new('RGB',(4*cw+48,4*ch+105),(243,241,231))
    d=ImageDraw.Draw(out)
    d.text((24,17),'SNOUTY / RUN STUDY 05',font=font(25),fill=(32,26,43))
    d.text((24,52),'16 frames | 96 x 96 px | 40 ms per frame | full two-step cycle',font=font(14),fill=(92,83,100))
    stages=['NEAR CONTACT','NEAR COMPRESSION','NEAR SUPPORT','NEAR PUSH',
            'NEAR PUSH','NEAR TOE-OFF','FLIGHT / RECOVERY','FLIGHT / REACH',
            'FAR CONTACT','FAR COMPRESSION','FAR SUPPORT','FAR PUSH',
            'FAR PUSH','FAR TOE-OFF','FLIGHT / RECOVERY','FLIGHT / REACH']
    for i,im in enumerate(frames):
        col,row=i%4,i//4
        x,y=24+col*cw,88+row*ch
        d.rounded_rectangle((x,y,x+cw-10,y+ch-10),radius=5,fill=(227,230,219))
        origin=(x+22,y+4)
        sprite=im.resize((192,192),Image.Resampling.NEAREST)
        out.paste(sprite,origin,sprite)
        gy=origin[1]+GROUND_Y*2+2
        d.line((x+13,gy,x+cw-24,gy),fill=(167,179,162),width=1)
        d.text((x+14,y+200),f'{i:02d}  {stages[i]}',font=font(13),fill=(45,35,58))
        side='NEAR FOOT' if meta[i]['near']['grounded'] else ('FAR FOOT' if meta[i]['far']['grounded'] else 'BOTH FEET CLEAR')
        d.text((x+14,y+219),side,font=font(10),fill=(105,96,110))
    out.save(ROOT/'snouty_run_contact_sheet.png')


def main():
    frames=[];metadata=[]
    for i in range(N):
        im,m=render_frame(i);frames.append(im);metadata.append(m)
        im.save(FRAMES/f'snouty_run_{i:02d}.png')
    strip=blank((W*N,H))
    grid=blank((W*8,H*2))
    for i,im in enumerate(frames):
        strip.alpha_composite(im,(i*W,0))
        grid.alpha_composite(im,((i%8)*W,(i//8)*H))
    strip.save(ROOT/'snouty_run_strip.png')
    grid.save(ROOT/'snouty_run_sheet.png')
    # Optional 4-bit indexed strip: index 0 transparent, indices 1..15 opaque.
    pixels=np.array(strip);indices=np.zeros(pixels.shape[:2],dtype=np.uint8)
    for color_index,col in enumerate(COLORS,1):
        match=(pixels[:,:,3]>0)&(pixels[:,:,:3]==col[:3]).all(axis=2)
        indices[match]=color_index
    indexed=Image.fromarray(indices,'P')
    indexed.putpalette([0,0,0]+[v for c in COLORS for v in c[:3]])
    indexed.save(ROOT/'snouty_run_indexed.png',bits=4,transparency=0)
    gpl=['GIMP Palette','Name: Snouty Run Study 05','Columns: 5',
         '# 15 opaque colors; transparency is index 0 in the indexed PNG.']
    for c,h in zip(COLORS,PALETTE_HEX):
        gpl.append(f'{c[0]:3d} {c[1]:3d} {c[2]:3d}  #{h}')
    (ROOT/'snouty_palette.gpl').write_text('\n'.join(gpl)+'\n')
    build_previews(frames)
    contact_sheet(frames,metadata)
    manifest={'name':'snouty_run_study_05','direction':'right','frame_size':[W,H],
              'frame_count':N,'duration_ms':DURATION_MS,'cycle_duration_ms':N*DURATION_MS,
              'fps':1000/DURATION_MS,'playback':'forward, loop; never ping-pong',
              'origin_px':[48,GROUND_Y],'coordinate_system':'top-left, x right, y down',
              'ground_baseline_y':GROUND_Y,'suggested_world_speed_px_s':SCROLL*1000/DURATION_MS,
              'visible_palette':['#'+v for v in PALETTE_HEX],'transparent_index':0,
              'strip':{'file':'snouty_run_strip.png','columns':N,'rows':1,'margin':0,'spacing':0},
              'grid':{'file':'snouty_run_sheet.png','columns':8,'rows':2,'margin':0,'spacing':0},
              'indexed_strip':{'file':'snouty_run_indexed.png','columns':16,'rows':1,
                               'indexed_bits_per_pixel':4,'transparent_palette_index':0},
              'loop_order':list(range(N)),
              'frames':[{'index':i,'file':f'frames/snouty_run_{i:02d}.png',
                         'duration_ms':DURATION_MS,'strip_rect':[i*W,0,W,H],
                         'grid_rect':[(i%8)*W,(i//8)*H,W,H],**metadata[i]} for i in range(N)]}
    (ROOT/'snouty_run.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('Built',len(frames),'frames')
    for i,im in enumerate(frames):
        print(i,im.getbbox(),'near',metadata[i]['near']['phase'],metadata[i]['near']['grounded'],
              'far',metadata[i]['far']['phase'],metadata[i]['far']['grounded'])

if __name__=='__main__':
    main()
