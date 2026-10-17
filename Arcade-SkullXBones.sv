//============================================================================
//
//  Skull & Crossbones (Atari Games, 1989) MiSTer FPGA core: top-level glue.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  Structure inherited from the
//  Badlands, Vindicators, Xybots and Blasteroids MiSTer cores (GPL-3.0, same
//  author).
//
//  Connects skullxbo_core (the game logic: one clk_sys domain with integer
//  clock enables) to the MiSTer framework: the PLL, hps_io (ROM download,
//  NVRAM save/restore and controls), the CRT Adjust stage,
//  arcade_video, audio and the SDRAM pins.
//
//  Skull & Crossbones runs on a horizontal monitor (MAME ROT0): no rotation.
//
//  Clocking: clk_sys = 57.272727 MHz = 4 x the 14.318181 MHz crystal.
//  ce_14m = clk_sys/4 is the pixel rate; ce_7m = /8 is the 68000 clock.
//
//  Controls: each player has an 8-way joystick, a SWORD button
//  (FF5800/FF5802 D8), a TURN button (D9) and a START bit (D10, JAMMA start,
//  marked "development only" in the manual).  D11 (JAMMA button 3) is held
//  released: the game never reads it.  The four coin inputs are on the JSA
//  sound board's /RDIO port, not on the game PCB.  The self-test switch is on
//  the JSA board too and also reaches the game PCB's FF5803 D7, so `service`
//  feeds both boards.  All polarities are formed inside the core; "1" here
//  means "pressed".
//
//  NVRAM: the 28C16 EEPROM is saved and restored on ioctl index 2, 2048
//  bytes.  It is not part of the ROM download; the game writes its own
//  defaults on first boot.
//
//============================================================================

`timescale 1ns/1ps

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1        = 0;
assign VGA_SCALER    = 0;
assign VGA_DISABLE   = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT= 0;
assign FB_FORCE_BLANK= 0;

assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

// Horizontal cabinet: the native raster is 672 x 240 on a 4:3 monitor.
wire  [1:0] ar  = status[122:121];
wire [11:0] arx = (ar == 2'd0) ? 12'd4 : 12'(ar - 1'd1);
wire [11:0] ary = (ar == 2'd0) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"SkullXBones;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[4],Orientation,Original,Flip;",
	"O[22:20],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer;",
	"-;",
	// CRT Adjust: rmonic79's MiSTer-CRT-Adjust, core-side variant.  Three
	// amounts plus an On/Off.  H-Position is built as a content shift (the
	// engine can also build it as a sync shift; which one is compiled in is set
	// by crt_adjust's HPOS_MODE, and the reasoning for this raster is in
	// rtl/video/skullxbo_analog_adjust.sv).
	//
	// Every amount is plain two's complement, so the list is 0,+1..+max then
	// -min..-1 and the decode is a $signed().  None of these touch the core's
	// timing; the stage sits between skullxbo_core and arcade_video.  Off is a
	// bit-exact bypass, so HDMI is untouched unless the user turns it On.
	//
	// H1 hides the three amounts while the stage is inactive, which includes the
	// case where the framework has forced the scandoubler and the stage gates
	// itself off (see `crt_enable`).
	"P1,CRT Adjust;",
	"P1-;",
	"P1O[23],CRT Adjust,Off,On;",
	"H1P1O[28:24],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[35:29],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,+49,+50,+51,+52,+53,+54,+55,+56,+57,+58,+59,+60,+61,+62,+63,-64,-63,-62,-61,-60,-59,-58,-57,-56,-55,-54,-53,-52,-51,-50,-49,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[41:36],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	// The self-test switch SW1 on the JSA board.  One net: it reaches the
	// 6502's /RDIO D7/D4 and, over J1-29, the game PCB's FF5803 D7.
	"O[6],Service,Off,On;",
	"-;",
	// The J1 button list is the pad order: Sword (D8), Turn (D9), Start (D10),
	// Coin.  Aux 1 (D11, "AUX #1", JAMMA button 3) is not offered: the game
	// never reads it.
	"T[0],Reset;",
	"J1,Sword,Turn,Start,Coin;",
	"jn,A,B,Start,Select;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire        direct_video;
wire [21:0] gamma_bus;

wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;
wire        ioctl_wait;
wire        ioctl_upload, ioctl_upload_req;
wire  [7:0] ioctl_upload_index, ioctl_din;

wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3;

// CRT Adjust master enable.  Declared here because status_menumask below reads
// it; what it means is documented at the stage itself (VIDEO section).  The
// forced-scandoubler term is upstream's own integration rule: the read-rate
// base assumes the native 15 kHz pixel-CE ratio, and once the framework has
// doubled the line rate there is no analog CRT geometry left to fit anyway.
wire crt_enable = status[23] & ~forced_scandoubler;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),

	.buttons(buttons),
	.status(status),
	// H1 = "hide while set": hide the three CRT Adjust amounts whenever the
	// stage is not actually doing anything.  `crt_enable` is the same signal
	// the stage itself runs on, so the menu never offers a control that is
	// being ignored.
	.status_menumask({14'd0, ~crt_enable, 1'b0}),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	// NVRAM: the 28C16 image, index 2, 2048 bytes.
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(ioctl_upload_index),
	.ioctl_din(ioctl_din),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.joystick_3(joystick_3),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;               // 57.272727 MHz
wire clk_sdram;             // same rate, phase-shifted for the SDRAM_CLK pin
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);

// SDRAM clock pin from the phase-shifted PLL output (rtl/pll/pll_0002.v).  The
// read-capture phase can only be checked on hardware; see the README.
assign SDRAM_CLK = clk_sdram;

// `reset` is the OSD / system reset and reaches the game through the core's
// reset input.  `~pll_locked` alone is init_reset, the only reset the SDRAM
// controller may ever see.
wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

///////////////////////   CONTROLS   /////////////////////////////

// MiSTer joystick bits: [0]=Right [1]=Left [2]=Down [3]=Up, then the J1 list:
// [4]=Sword [5]=Turn [6]=Start [7]=Coin.
//
// skullxbo_core takes the joystick as {up, down, left, right}, which is the
// FF5800 D15:12 order.  Aux 1 (btn3) is not in the OSD list and is held
// released.
wire [3:0] p1_joy   = {joystick_0[3], joystick_0[2], joystick_0[1], joystick_0[0]};
wire [3:0] p2_joy   = {joystick_1[3], joystick_1[2], joystick_1[1], joystick_1[0]};
wire       p1_sword = joystick_0[4];
wire       p1_turn  = joystick_0[5];
wire       p1_btn3  = 1'b0;
wire       p1_start = joystick_0[6];
wire       p2_sword = joystick_1[4];
wire       p2_turn  = joystick_1[5];
wire       p2_btn3  = 1'b0;
wire       p2_start = joystick_1[6];

// Coins are read by the JSA 6502 on /RDIO, not by the game PCB.  There are
// four coin inputs; pads 1-4 each drive one.  The manual does not say which
// JAMMA pin carries which.
//
// skullxbo_core's coin1..coin4 land on /RDIO D3..D0 ({J1-33, J1-31, J1-35,
// J1-36}).  Pad n's coin goes to D(n-1): D0 is MAME's COIN1 and D1 its COIN2,
// the two the default "separate mechs" setting credits.  (D3, which MAME
// marks unused, is debounced by the game but never gives a credit.)
wire coin4 = joystick_0[7];   // D0  J1-36  MAME COIN1
wire coin3 = joystick_1[7];   // D1  J1-35  MAME COIN2
wire coin2 = joystick_2[7];   // D2  J1-31  MAME COIN3
wire coin1 = joystick_3[7];   // D3  J1-33  MAME unused

// One net, both boards.
wire service = status[6];

///////////////////////   CORE   /////////////////////////////////

wire        ce_pix;
wire  [7:0] core_r, core_g, core_b;
wire        core_hs, core_vs, core_hb, core_vb;
wire [10:0] core_pix_index;      // the software palette index (debug only)
wire        core_rom_loaded;
wire        cctr1, cctr2, cctr_wired_or;
wire signed [15:0] aud_l, aud_r;

skullxbo_core u_core
(
	.clk_sys(clk_sys), .reset(reset), .init_reset(~pll_locked),

	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_index(ioctl_index), .ioctl_wait(ioctl_wait),
	.ioctl_upload(ioctl_upload), .ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(ioctl_upload_index), .ioctl_din(ioctl_din),

	.service(service),
	.p1_joy(p1_joy), .p2_joy(p2_joy),
	.p1_sword(p1_sword), .p1_turn(p1_turn),
	.p1_btn3(p1_btn3), .p1_start(p1_start),
	.p2_sword(p2_sword), .p2_turn(p2_turn),
	.p2_btn3(p2_btn3), .p2_start(p2_start),
	.coin1(coin1), .coin2(coin2), .coin3(coin3), .coin4(coin4),

	// The two JAMMA coin-counter drivers and the R13 = 0 ohm node the board
	// actually has.  MiSTer has no use for them.
	.cctr1(cctr1), .cctr2(cctr2), .cctr_wired_or(cctr_wired_or),

	.ce_pix(ce_pix), .vga_r(core_r), .vga_g(core_g), .vga_b(core_b),
	.hsync(core_hs), .vsync(core_vs), .hblank(core_hb), .vblank(core_vb),
	.pix_index(core_pix_index),

	.aud_l(aud_l), .aud_r(aud_r),
	.rom_loaded(core_rom_loaded),

	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH), .SDRAM_CKE(SDRAM_CKE), .SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE)
);

///////////////////////   AUDIO   ////////////////////////////////

// The JSA II output is MONO (one TDA2030); both channels carry one signal.
assign AUDIO_S = 1'b1;              // signed samples
assign AUDIO_L = aud_l;
assign AUDIO_R = aud_r;

///////////////////////   VIDEO   ////////////////////////////////

// CRT Adjust (H-Size / H-Position / V-Shift): rmonic79's crt_adjust engine with
// this core's OSD decode, read-rate generator and DE glue around it.  Placed
// ahead of arcade_video so the mixer, scandoubler and video_freak all see the
// adjusted raster.  With the stage On the output pixel rate is no longer
// ce_pix, which is why arcade_video is clocked from adj_ce rather than ce_pix.
// Off is a bit-exact bypass.
//
// H_TOTAL is in ce_pix ticks: 912 pixels per line.  V_TOTAL matches the core's
// default of 262 lines.  Both, and CLK_PER_PIX, are load-bearing; HPOS_MODE = 1
// selects the content-shift form of H-Position, for the reasons set out in
// rtl/video/skullxbo_analog_adjust.sv.
//
// `crt_enable` is declared up with the hps_io wires because status_menumask
// reads it too: the three amounts disappear from the menu whenever the stage is
// not running, rather than sitting there being ignored.
wire [7:0] adj_r, adj_g, adj_b;
wire       adj_hs, adj_vs, adj_hb, adj_vb, adj_ce;

skullxbo_analog_adjust #(
	.H_TOTAL(912), .V_TOTAL(262), .CLK_PER_PIX(4), .HPOS_MODE(1), .AW(11)
) u_analog_adjust
(
	.clk        (clk_sys),
	.ce_pix     (ce_pix),
	.osd_on     (crt_enable),
	.osd_hsize  (status[28:24]),
	.osd_hpos   (status[35:29]),
	.osd_vshift (status[41:36]),
	.r_in(core_r), .g_in(core_g), .b_in(core_b),
	.hs_in(core_hs), .vs_in(core_vs), .hb_in(core_hb), .vb_in(core_vb),
	.r_out(adj_r), .g_out(adj_g), .b_out(adj_b),
	.hs_out(adj_hs), .vs_out(adj_vs), .hb_out(adj_hb), .vb_out(adj_vb),
	.ce_out(adj_ce)
);

wire [2:0] fx = 3'b000;

wire       rotate_ccw = 1'b0;
wire       no_rotate  = 1'b1;
wire       flip       = status[4] & ~direct_video;
wire       video_rotated;

wire vga_de_raw;

// 672 pixels wide, 24-bit RGB.  ce_pix = ce_14m: the board draws ONE pixel
// per 14M clock (two per SOS-2 count).
arcade_video #(.WIDTH(672), .DW(24)) arcade_video
(
	.clk_video (clk_sys),
	.ce_pix    (adj_ce),
	.RGB_in    ({adj_r, adj_g, adj_b}),
	.HBlank    (adj_hb),
	.VBlank    (adj_vb),
	.HSync     (adj_hs),
	.VSync     (adj_vs),

	.CLK_VIDEO (CLK_VIDEO),
	.CE_PIXEL  (CE_PIXEL),
	.VGA_R     (VGA_R),
	.VGA_G     (VGA_G),
	.VGA_B     (VGA_B),
	.VGA_HS    (VGA_HS),
	.VGA_VS    (VGA_VS),
	.VGA_DE    (vga_de_raw),
	.VGA_SL    (VGA_SL),

	.fx                 (fx),
	.forced_scandoubler (forced_scandoubler),
	.gamma_bus          (gamma_bus)
);

// video_freak SCALE encoding: 0 normal, 1 V-integer, 2 HV-Integer-, 4 HV-Integer.
wire [2:0] scale_sel = (status[22:20] == 3'd0) ? 3'd0 :
                       (status[22:20] == 3'd1) ? 3'd1 :
                       (status[22:20] == 3'd2) ? 3'd4 :
                                                 3'd2;

video_freak video_freak
(
	.CLK_VIDEO  (CLK_VIDEO),
	.CE_PIXEL   (CE_PIXEL),
	.VGA_VS     (VGA_VS),
	.HDMI_WIDTH (HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE     (VGA_DE),
	.VIDEO_ARX  (VIDEO_ARX),
	.VIDEO_ARY  (VIDEO_ARY),
	.VGA_DE_IN  (vga_de_raw),
	.ARX        (arx),
	.ARY        (ary),
	.CROP_SIZE  (12'd0),
	.CROP_OFF   (5'd0),
	.SCALE      (scale_sel)
);

screen_rotate screen_rotate (.*);

///////////////////////   STATUS LED   ///////////////////////////

assign LED_USER = ioctl_download;

// Nothing in the MiSTer framework uses the palette index, the coin counters
// or the download flag.  Collected here so the lint does not warn.
/* verilator lint_off UNUSEDSIGNAL */
wire _unused_emu = &{1'b0, core_pix_index, core_rom_loaded,
                     cctr1, cctr2, cctr_wired_or, 1'b0};
/* verilator lint_on UNUSEDSIGNAL */

endmodule
