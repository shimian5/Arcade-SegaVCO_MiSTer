// Decodes the ioctl_download address stream (MRA-concatenated ROM blob) into
// per-region write strobes + region-relative addresses. See docs/PLAN.md,
// "ROM loading" table, for the fixed offset map (kept in sync with
// tools/gen_mra.py's REGIONS dict -- update both together).
module rom_download
(
    input  wire        clk,
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [24:0] ioctl_addr,
    input  wire [7:0]  ioctl_dout,

    output wire         maincpu_we,
    output wire [14:0]  maincpu_addr,   // 0x8000 (32KB)
    output wire         subcpu_we,
    output wire [12:0]  subcpu_addr,    // 0x2000 (8KB)
    output wire         fgtiles_we,
    output wire [11:0]  fgtiles_addr,   // 0x1000 (4KB)
    output wire         proms_we,
    output wire [12:0]  proms_addr,     // 0x2000 (8KB)
    output wire         road_we,
    output wire [14:0]  road_addr,      // 0x8000 (32KB, Turbo road / Buck Rogers bgcolor share this slot)
    output wire         sprites_we,
    output wire [17:0]  sprites_addr,   // 0x40000 (256KB)

    output wire [7:0]   dout
);

    localparam MAINCPU_BASE  = 25'h000000, MAINCPU_SIZE  = 25'h008000;
    localparam SUBCPU_BASE   = 25'h008000, SUBCPU_SIZE   = 25'h002000;
    localparam FGTILES_BASE  = 25'h00A000, FGTILES_SIZE  = 25'h001000;
    localparam PROMS_BASE    = 25'h00C000, PROMS_SIZE    = 25'h002000;
    localparam ROAD_BASE     = 25'h00E000, ROAD_SIZE     = 25'h008000;
    localparam SPRITES_BASE  = 25'h016000, SPRITES_SIZE  = 25'h040000;

    wire wr = ioctl_download && ioctl_wr;

    wire in_maincpu = (ioctl_addr >= MAINCPU_BASE) && (ioctl_addr < MAINCPU_BASE + MAINCPU_SIZE);
    wire in_subcpu  = (ioctl_addr >= SUBCPU_BASE)  && (ioctl_addr < SUBCPU_BASE  + SUBCPU_SIZE);
    wire in_fgtiles = (ioctl_addr >= FGTILES_BASE) && (ioctl_addr < FGTILES_BASE + FGTILES_SIZE);
    wire in_proms   = (ioctl_addr >= PROMS_BASE)   && (ioctl_addr < PROMS_BASE   + PROMS_SIZE);
    wire in_road    = (ioctl_addr >= ROAD_BASE)    && (ioctl_addr < ROAD_BASE    + ROAD_SIZE);
    wire in_sprites = (ioctl_addr >= SPRITES_BASE) && (ioctl_addr < SPRITES_BASE + SPRITES_SIZE);

    assign maincpu_we  = wr && in_maincpu;
    assign subcpu_we   = wr && in_subcpu;
    assign fgtiles_we  = wr && in_fgtiles;
    assign proms_we    = wr && in_proms;
    assign road_we     = wr && in_road;
    assign sprites_we  = wr && in_sprites;

    assign maincpu_addr  = ioctl_addr[14:0]  - MAINCPU_BASE[14:0];
    assign subcpu_addr   = ioctl_addr[12:0]  - SUBCPU_BASE[12:0];
    assign fgtiles_addr  = ioctl_addr[11:0]  - FGTILES_BASE[11:0];
    assign proms_addr    = ioctl_addr[12:0]  - PROMS_BASE[12:0];
    assign road_addr     = ioctl_addr[14:0]  - ROAD_BASE[14:0];
    assign sprites_addr  = ioctl_addr[17:0]  - SPRITES_BASE[17:0];

    assign dout = ioctl_dout;

endmodule
