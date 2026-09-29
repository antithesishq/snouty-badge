/* Snouty test ROM: the 68000 program (README.md describes the screen and
   sound frame by frame).

   VRAM layout (H40, 64x32-cell planes):
     0x0000 tiles        0xC000 plane A     0xD000 window (unused)
     0xD800 sprite table 0xDC00 H scroll    0xE000 plane B (blank)
   All VDP writes go through the data port (no DMA), so the ROM also runs on
   an emulator whose DMA is not written yet. */

#include <stdint.h>

#define VDP_DATA   (*(volatile uint16_t *)0xC00000)
#define VDP_CTRL   (*(volatile uint16_t *)0xC00004)
#define VDP_CTRL_L (*(volatile uint32_t *)0xC00004)
#define PSG        (*(volatile uint8_t *)0xC00011)
#define PAD1_DATA  (*(volatile uint8_t *)0xA10003)
#define PAD1_CTRL  (*(volatile uint8_t *)0xA10009)
#define Z80_BUSREQ (*(volatile uint16_t *)0xA11100)
#define Z80_RESET  (*(volatile uint16_t *)0xA11200)
#define Z80_RAM    ((volatile uint8_t *)0xA00000)

#define PLANE_A    0xC000
#define SPRITES    0xD800
#define HSCROLL    0xDC00

/* Tile indices. */
#define T_BLANK    0
#define T_GRID     1
#define T_VSTRIPE  2
#define T_HSTRIPE  3
#define T_DIAG     4
#define T_SOLID    5   /* 5..19: solid colour 1..15 */
#define T_DIGIT    32  /* 32..47: hex digits 0..F   */
#define T_SPRITE   48  /* 48..51: the 16x16 sprite  */

/* Backdrop (palette 0 entry 0) above and below the H-int line. */
#define COLOUR_TOP    0x0800  /* dark blue */
#define COLOUR_RASTER 0x0008  /* dark red  */
#define HINT_LINE     111     /* register 10: H-int after line 111 (and 223) */

#define SPRITE_X0  152        /* screen coordinates of the sprite at boot */
#define SPRITE_Y0  104

/* Pad bits as main() keeps them (1 = pressed). */
#define PAD_UP     0x01
#define PAD_DOWN   0x02
#define PAD_LEFT   0x04
#define PAD_RIGHT  0x08
#define PAD_B      0x10
#define PAD_C      0x20
#define PAD_A      0x40
#define PAD_START  0x80

extern const uint8_t z80_driver[], z80_driver_end[];

static volatile uint16_t frame;      /* V-ints since the display went on */
static volatile uint8_t vblank;      /* set by V-int, cleared by main */
static volatile uint8_t hints;       /* H-ints in the current frame */

static const uint16_t palette0[16] = {
    COLOUR_TOP, 0x0EEE, 0x000E, 0x00E0, 0x0E00, 0x00EE, 0x0E0E, 0x0EE0,
    0x0888, 0x006E, 0x0060, 0x0806, 0x0E86, 0x088E, 0x0246, 0x0000,
};
static const uint16_t palette1[16] = {
    0x0000, 0x00EE, 0x0000, 0x004E, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

/* 1bpp hex digit glyphs, bit 7 = leftmost pixel. */
static const uint8_t font[16][8] = {
    {0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00},
    {0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00},
    {0x3C, 0x66, 0x06, 0x0C, 0x30, 0x60, 0x7E, 0x00},
    {0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00},
    {0x0C, 0x1C, 0x3C, 0x6C, 0x7E, 0x0C, 0x0C, 0x00},
    {0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00},
    {0x3C, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x3C, 0x00},
    {0x7E, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00},
    {0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00},
    {0x3C, 0x66, 0x66, 0x3E, 0x06, 0x0C, 0x38, 0x00},
    {0x18, 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x00},
    {0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00},
    {0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00},
    {0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00},
    {0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00},
    {0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00},
};

/* GCC may emit calls to these for struct copies; none are expected. */
void *memset(void *d, int c, unsigned long n);
void *memset(void *d, int c, unsigned long n)
{
    uint8_t *p = d;
    while (n--) *p++ = (uint8_t)c;
    return d;
}
void *memcpy(void *d, const void *s, unsigned long n);
void *memcpy(void *d, const void *s, unsigned long n)
{
    uint8_t *p = d;
    const uint8_t *q = s;
    while (n--) *p++ = *q++;
    return d;
}

static void vdp_reg(uint8_t r, uint8_t v)
{
    VDP_CTRL = (uint16_t)(0x8000 | ((uint16_t)r << 8) | v);
}

/* Command words: CD1-0 in bits 31-30, A13-0 in 29-16, CD5-2 in 7-4, A15-14
   in 1-0. VRAM write CD=0001, CRAM write CD=0011, VSRAM write CD=0101. */
static void vram_write_at(uint16_t addr)
{
    VDP_CTRL_L = 0x40000000UL | ((uint32_t)(addr & 0x3FFF) << 16) | (addr >> 14);
}
static void cram_write_at(uint16_t addr)
{
    VDP_CTRL_L = 0xC0000000UL | ((uint32_t)(addr & 0x3FFF) << 16);
}
static void vsram_write_at(uint16_t addr)
{
    VDP_CTRL_L = 0x40000010UL | ((uint32_t)(addr & 0x3FFF) << 16);
}

static void set_backdrop(uint16_t colour)
{
    cram_write_at(0);
    VDP_DATA = colour;
}

void on_vint(void);
void on_vint(void)
{
    frame++;
    vblank = 1;
    hints = 0;
    set_backdrop(COLOUR_TOP);
}

void on_hint(void);
void on_hint(void)
{
    if (hints++ == 0) set_backdrop(COLOUR_RASTER);
}

/* Pixel colour of the procedural tiles at (x, y), 0 = transparent. */
static uint8_t tile_pixel(uint8_t tile, uint8_t x, uint8_t y)
{
    switch (tile) {
    case T_GRID:    return (x == 0 || y == 0) ? 8 : 0;
    case T_VSTRIPE: return (x & 1) ? 3 : 2;
    case T_HSTRIPE: return (y & 1) ? 5 : 4;
    case T_DIAG:    return x == y ? 1 : 0;
    default:
        if (tile >= T_SOLID && tile < T_SOLID + 15) return tile - T_SOLID + 1;
        if (tile >= T_DIGIT && tile < T_DIGIT + 16)
            return (font[tile - T_DIGIT][y] & (0x80 >> x)) ? 1 : 15;
        if (tile >= T_SPRITE && tile < T_SPRITE + 4) {
            /* 16x16 sprite; VRAM order is column-major (TL, BL, TR, BR). */
            uint8_t n = tile - T_SPRITE;
            uint8_t sx = x + ((n & 2) ? 8 : 0), sy = y + ((n & 1) ? 8 : 0);
            if (sx == 0 || sx == 15 || sy == 0 || sy == 15) return 2;
            if (sx >= 6 && sx <= 9 && sy >= 6 && sy <= 9) return 3;
            return 1;
        }
        return 0;
    }
}

static void load_tile(uint8_t tile)
{
    vram_write_at((uint16_t)tile << 5);
    for (uint8_t y = 0; y < 8; y++)
        for (uint8_t x = 0; x < 8; x += 4)
            VDP_DATA = (uint16_t)((tile_pixel(tile, x, y) << 12) |
                                  (tile_pixel(tile, x + 1, y) << 8) |
                                  (tile_pixel(tile, x + 2, y) << 4) |
                                  tile_pixel(tile, x + 3, y));
}

/* Plane A cell for (col, row) of the visible 40x28 area. */
static uint16_t layout(uint8_t col, uint8_t row)
{
    if (row >= 4 && row <= 7) return T_VSTRIPE;
    if (row >= 10 && row <= 13) return T_HSTRIPE;
    if (row >= 16 && row <= 17) {
        uint8_t c = col;
        while (c >= 15) c -= 15;
        return T_SOLID + c;
    }
    if (row >= 20 && row <= 23) return T_DIAG;
    return T_GRID;
}

static void put_hex(uint8_t col, uint8_t row, uint16_t v, uint8_t digits)
{
    vram_write_at((uint16_t)(PLANE_A + (((uint16_t)row << 6) + col) * 2));
    for (int8_t i = (int8_t)(digits - 1); i >= 0; i--)
        VDP_DATA = T_DIGIT + ((v >> (i * 4)) & 0xF);
}

static void vdp_init(void)
{
    (void)VDP_CTRL;              /* clear a pending command half */
    vdp_reg(0, 0x14);            /* H-int enable, normal colour */
    vdp_reg(1, 0x04);            /* mode 5, display off, V-int off */
    vdp_reg(2, PLANE_A >> 10);   /* 0x30 */
    vdp_reg(3, 0xD000 >> 10);    /* 0x34 window */
    vdp_reg(4, 0xE000 >> 13);    /* 0x07 plane B */
    vdp_reg(5, SPRITES >> 9);    /* 0x6C */
    vdp_reg(6, 0x00);
    vdp_reg(7, 0x00);            /* backdrop = palette 0 entry 0 */
    vdp_reg(8, 0x00);
    vdp_reg(9, 0x00);
    vdp_reg(10, HINT_LINE);
    vdp_reg(11, 0x00);           /* full-screen H and V scroll */
    vdp_reg(12, 0x81);           /* H40, no interlace, no shadow/highlight */
    vdp_reg(13, HSCROLL >> 10);  /* 0x37 */
    vdp_reg(14, 0x00);
    vdp_reg(15, 0x02);           /* auto-increment 2 */
    vdp_reg(16, 0x01);           /* planes 64x32 cells */
    vdp_reg(17, 0x00);           /* no window */
    vdp_reg(18, 0x00);

    vram_write_at(0);            /* clear all 64 KB of VRAM */
    for (uint16_t i = 0; i < 0x8000; i++) VDP_DATA = 0;
    vsram_write_at(0);
    for (uint8_t i = 0; i < 40; i++) VDP_DATA = 0;
    cram_write_at(0);
    for (uint8_t i = 0; i < 16; i++) VDP_DATA = palette0[i];
    for (uint8_t i = 0; i < 16; i++) VDP_DATA = palette1[i];
    for (uint8_t i = 0; i < 32; i++) VDP_DATA = 0;
}

static void load_tiles(void)
{
    load_tile(T_GRID);
    load_tile(T_VSTRIPE);
    load_tile(T_HSTRIPE);
    load_tile(T_DIAG);
    for (uint8_t t = T_SOLID; t < T_SOLID + 15; t++) load_tile(t);
    for (uint8_t t = T_DIGIT; t < T_DIGIT + 16; t++) load_tile(t);
    for (uint8_t t = T_SPRITE; t < T_SPRITE + 4; t++) load_tile(t);
    for (uint8_t row = 0; row < 28; row++) {
        vram_write_at((uint16_t)(PLANE_A + ((uint16_t)row << 7)));
        for (uint8_t col = 0; col < 40; col++) VDP_DATA = layout(col, row);
    }
}

static void psg_init(void)
{
    PSG = 0x9F; PSG = 0xBF; PSG = 0xDF; PSG = 0xFF;  /* all four silent */
    PSG = 0x8C; PSG = 0x1F;  /* tone 0 period 0x1FC: 3579545/32/508 = 220.2 Hz */
    PSG = 0x94;              /* tone 0 attenuation 4 (8 dB) */
}

static void z80_load(void)
{
    Z80_BUSREQ = 0x0100;                   /* request the Z80 bus */
    Z80_RESET = 0x0100;                    /* out of reset so the grant happens */
    while (Z80_BUSREQ & 0x0100) {}         /* bit 0 of A11100 = 0: granted */
    const uint8_t *s = z80_driver;
    volatile uint8_t *d = Z80_RAM;
    while (s < z80_driver_end) *d++ = *s++;
    Z80_RESET = 0x0000;                    /* hold reset (Z80 and YM2612) */
    for (volatile uint8_t i = 0; i < 20; i++) {}
    Z80_BUSREQ = 0x0000;                   /* give the bus back */
    Z80_RESET = 0x0100;                    /* release: the driver starts at 0 */
}

/* 3-button pad on port 1: TH high gives C B R L D U, TH low gives Start A. */
static uint8_t read_pad(void)
{
    PAD1_DATA = 0x40;
    __asm__ volatile("nop\n\tnop");
    uint8_t hi = PAD1_DATA;
    PAD1_DATA = 0x00;
    __asm__ volatile("nop\n\tnop");
    uint8_t lo = PAD1_DATA;
    PAD1_DATA = 0x40;
    return (uint8_t)~((hi & 0x3F) | ((lo & 0x30) << 2));
}

static void put_sprite(uint16_t x, uint16_t y)
{
    vram_write_at(SPRITES);
    VDP_DATA = y + 128;
    VDP_DATA = 0x0500;                     /* 2x2 cells, link 0 (last) */
    VDP_DATA = 0x2000 | T_SPRITE;          /* palette 1, low priority */
    VDP_DATA = x + 128;
}

int main(void);
int main(void)
{
    uint16_t x = SPRITE_X0, y = SPRITE_Y0;
    uint8_t muted = 0;

    vdp_init();
    load_tiles();
    put_sprite(x, y);
    put_hex(1, 1, 0, 4);
    put_hex(7, 1, 0, 2);
    psg_init();
    PAD1_CTRL = 0x40;                      /* TH is an output */
    PAD1_DATA = 0x40;
    z80_load();

    vdp_reg(1, 0x64);                      /* display on, V-int on, mode 5 */
    __asm__ volatile("move.w #0x2300, %%sr" ::: "memory");  /* levels 4, 6 */

    for (;;) {
        while (!vblank) {}
        vblank = 0;
        uint8_t pad = read_pad();
        uint8_t speed = (pad & PAD_B) ? 2 : 1;
        if (pad & PAD_START) { x = SPRITE_X0; y = SPRITE_Y0; }
        if ((pad & PAD_LEFT) && x >= speed) x -= speed;
        if ((pad & PAD_RIGHT) && x + speed <= 320 - 16) x += speed;
        if ((pad & PAD_UP) && y >= speed) y -= speed;
        if ((pad & PAD_DOWN) && y + speed <= 224 - 16) y += speed;
        put_sprite(x, y);
        put_hex(1, 1, frame, 4);
        put_hex(7, 1, pad, 2);
        uint8_t want = (pad & PAD_A) ? 1 : 0;
        if (want != muted) {
            muted = want;
            PSG = muted ? 0x9F : 0x94;
        }
    }
}
