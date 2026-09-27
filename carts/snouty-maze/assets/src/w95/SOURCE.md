# Windows 95 3D Maze assets (source files)

Copied unchanged on 2026-09-27 from
<https://github.com/ibid-11962/Windows-95-3D-Maze-Screensaver> (a WebGL
recreation, Spring 2019). Its README says the wall, floor, ceiling and
picture textures were extracted from the original Microsoft screensaver,
and the 2D sprites (OpenGL word, Start button, smiley, rat) from a Unity
clone. The repository carries no licence for these files; they are
Microsoft's original artwork and are used here for fidelity in a
non-commercial conference badge demo.

`python3 tools/prepare_assets.py --from-w95 assets/src/w95 [--rat]`
turns them into the 32x32 4-bit sheets in `assets/gen/`:

| Source         | Size    | Becomes            | Note                                          |
|----------------|---------|--------------------|-----------------------------------------------|
| `wall.bmp`     | 128x128 | `wall.png`         | red brick, one cell                           |
| `floor.bmp`    | 64x64   | `floor.png`        | wood grain, one cell                          |
| `ceiling.bmp`  | 33x33   | (unused)           | 3-colour pebble tile, tiled 3x3 per cell      |
| `ceiling2.bmp` | 128x128 | `ceiling.png`      | the 3x3 tiling above as one cell (from README)|
| `pic.bmp`      | 256x256 | `wall_pic.png`     | the OpenGL room render hung on odd panels     |
| `gl.png`       | 256x256 | `logo.png`         | "OpenGL" word, split "Open"/"GL" and stacked  |
| `fin.png`      | 128x128 | `smiley.png`       | finish smiley                                 |
| `start2.png`   | 512x512 | `start.png`        | Start button (floats in the first cell)       |
| `rat.png`      | 256x256 | `snouty.png` (opt) | `--rat` only; default keeps Snouty            |
