#!/usr/bin/env python3
"""Check native pixels, frame order, timing, palette, bounds and loop seam."""
from pathlib import Path
import hashlib
import json
import numpy as np
from PIL import Image,ImageSequence

ROOT=Path(__file__).resolve().parent
m=json.loads((ROOT/'snouty_run.json').read_text())
paths=sorted((ROOT/'frames').glob('snouty_run_*.png'))
frames=[Image.open(p).convert('RGBA') for p in paths]
a=[np.array(f) for f in frames]
assert len(frames)==16
assert all(f.size==(96,96) for f in frames)
assert all(set(np.unique(v[:,:,3]))<={0,255} for v in a)
assert len({hashlib.sha256(v.tobytes()).hexdigest() for v in a})==16
colors=set()
for v in a:
    colors.update(tuple(c) for c in v[:,:,:3][v[:,:,3]==255])
allowed={tuple(bytes.fromhex(c[1:])) for c in m['visible_palette']}
assert colors<=allowed
for im in frames:
    x0,y0,x1,y1=im.getbbox()
    assert x0>0 and y0>0 and x1<96 and y1<96

# Strip and grid cells must exactly match their respective individual frames.
strip=Image.open(ROOT/'snouty_run_strip.png').convert('RGBA')
grid=Image.open(ROOT/'snouty_run_sheet.png').convert('RGBA')
indexed=Image.open(ROOT/'snouty_run_indexed.png')
assert indexed.mode=='P'
assert np.array_equal(np.array(indexed.convert('RGBA')),np.array(strip))
apng=Image.open(ROOT/'snouty_run.png')
assert apng.n_frames==16
for i in range(16):
    apng.seek(i)
    assert apng.info['duration']==40
    assert np.array_equal(np.array(apng.convert('RGBA')),a[i])
for i,expected in enumerate(a):
    assert np.array_equal(np.array(strip.crop((i*96,0,(i+1)*96,96))),expected)
    x,y=(i%8)*96,(i//8)*96
    assert np.array_equal(np.array(grid.crop((x,y,x+96,y+96))),expected)

# Verify actual GIF data, rather than trusting the writer's arguments.
gif_data={}
for name in ['snouty_run_preview.gif','snouty_run_isolated.gif',
             'snouty_run_native_transparent.gif','snouty_run_slow.gif']:
    g=Image.open(ROOT/name)
    assert g.n_frames==16
    durations=[]
    for i in range(g.n_frames):
        g.seek(i);durations.append(g.info.get('duration'))
        if name=='snouty_run_native_transparent.gif':
            decoded=np.array(g.convert('RGBA'))
            decoded[decoded[:,:,3]==0]=0
            assert np.array_equal(decoded,a[i]),f'GIF pixel mismatch: frame {i}'
    expected=100 if 'slow' in name else 40
    assert durations==[expected]*16
    assert g.info.get('loop')==0
    gif_data[name]={'frames':g.n_frames,'duration_ms':durations,'loop':'infinite'}

# A planted toe moves left 6 px per animation tick, with no vertical motion.
for side in ['near','far']:
    planted=[f for f in m['frames'] if f[side]['grounded']]
    planted.sort(key=lambda f:f[side]['phase'])
    for prev,cur in zip(planted,planted[1:]):
        x0,y0=prev[side]['toe'];x1,y1=cur[side]['toe']
        assert abs(x1-x0+6)<1e-6 and y0==y1==88

changed=[int(np.any(a[(i+1)%16]!=a[i],axis=2).sum()) for i in range(16)]
report={'status':'passed','frame_count':16,'distinct_frame_count':16,
        'native_frame_size':[96,96],'visible_color_count':len(colors),
        'alpha_values':[0,255],'all_sprites_inside_cell':True,
        'all_atlas_cells_match_individual_frames':True,
        'native_transparent_gif_matches_png_pixels_exactly':True,
        'normal_cycle_duration_ms':640,'duplicate_terminal_frame':False,
        'grounded_toe_travel_px_per_frame':-6,
        'changed_pixels_per_adjacent_pair_including_loop':changed,
        'last_to_first_changed_pixels':changed[-1],
        'largest_adjacent_change_pixels':max(changed),
        'note':'Pixel-difference checks describe the seam; they do not certify subjective motion quality.',
        'gifs':gif_data}
(ROOT/'validation.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='gifs'},indent=2))
