// =============================================================================
// sram_wrapper
// -----------------------------------------------------------------------------
// Purpose    : Single-port (1RW) synchronous SRAM behind one interface, so the
//              caches use a behavioural model in simulation and a sky130 SRAM
//              macro in physical design (CLAUDE.md 5.3, docs/architecture.md
//              P8.2): with SKY130_SRAM defined, 512 x 32 (byte mask) maps to
//              sky130_sram_2kbyte_1rw1r_32x512_8 and up to 256 x 32 (no mask)
//              to sky130_sram_1kbyte_1rw1r_32x256_8.
// Interfaces : en_i selects the array this cycle; with we_i it writes the
//              words selected by be_i (one enable per GRAN bits), otherwise it
//              reads addr_i.
// Timing     : synchronous read: rdata_o shows the word read in the previous
//              cycle. Users may rely on it only in the cycle right after the
//              read: the behavioural model holds it, but the sky130 macro does
//              not (+sram_poison checks this in simulation). No
//              read-during-write.
//              The array has no reset; its users keep valid bits elsewhere.
// =============================================================================
module sram_wrapper #(
  parameter int unsigned DEPTH = 512,
  parameter int unsigned WIDTH = 32,
  parameter int unsigned GRAN  = 8,               // bits per write enable
  localparam int unsigned NBE  = WIDTH / GRAN,
  localparam int unsigned AW   = $clog2(DEPTH)
) (
  input  logic             clk_i,
  input  logic             en_i,
  input  logic             we_i,
  input  logic [NBE-1:0]   be_i,
  input  logic [AW-1:0]    addr_i,
  input  logic [WIDTH-1:0] wdata_i,
  output logic [WIDTH-1:0] rdata_o
);

`ifdef SKY130_SRAM
  // ---------------------------------------------------------------------------
  // Physical design (P8.2): sky130 OpenRAM macros. Port 0 is the 1RW port;
  // port 1 (read-only) is unused. The macro captures its inputs at the rising
  // edge, like the behavioural model, and drives dout0 in the next cycle only,
  // which is all the caches use (+sram_poison checks this in simulation).
  // ---------------------------------------------------------------------------
  if (DEPTH == 512 && WIDTH == 32 && GRAN == 8) begin : g_sky130
    // Port 1's read data is never used.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] dout1;
    /* verilator lint_on UNUSEDSIGNAL */
    sky130_sram_2kbyte_1rw1r_32x512_8 u_macro (
`ifdef USE_POWER_PINS
      // Power pins: connected to the power grid by the flow
      // (PDN_MACRO_CONNECTIONS in pnr/soc/config.json), not in the RTL.
      /* verilator lint_off PINCONNECTEMPTY */
      .vccd1  (),
      .vssd1  (),
      /* verilator lint_on PINCONNECTEMPTY */
`endif
      .clk0   (clk_i),
      .csb0   (!en_i),
      .web0   (!we_i),
      .wmask0 (be_i),
      .addr0  (addr_i),
      .din0   (wdata_i),
      .dout0  (rdata_o),
      .clk1   (clk_i),
      .csb1   (1'b1),
      .addr1  ('0),
      .dout1  (dout1)
    );
  end else if (DEPTH <= 256 && WIDTH <= 32 && NBE == 1) begin : g_sky130
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] dout0, dout1;
    /* verilator lint_on UNUSEDSIGNAL */
    sky130_sram_1kbyte_1rw1r_32x256_8 u_macro (
`ifdef USE_POWER_PINS
      // Power pins: connected to the power grid by the flow
      // (PDN_MACRO_CONNECTIONS in pnr/soc/config.json), not in the RTL.
      /* verilator lint_off PINCONNECTEMPTY */
      .vccd1  (),
      .vssd1  (),
      /* verilator lint_on PINCONNECTEMPTY */
`endif
      .clk0   (clk_i),
      .csb0   (!en_i),
      .web0   (!we_i),
      .wmask0 ({4{be_i}}),                 // NBE = 1: one enable for the word
      .addr0  (8'(addr_i)),
      .din0   (32'(wdata_i)),
      .dout0  (dout0),
      .clk1   (clk_i),
      .csb1   (1'b1),
      .addr1  ('0),
      .dout1  (dout1)
    );
    assign rdata_o = dout0[WIDTH-1:0];
  end else begin : g_unsupported
    $error("sram_wrapper: no sky130 macro for %0d x %0d", DEPTH, WIDTH);
  end
`else
  logic [WIDTH-1:0] mem_q [DEPTH];

`ifndef SYNTHESIS
  // +sram_poison (simulation only, P8.3): rdata_o is valid only in the cycle
  // after a read and garbage in every other cycle, as the sky130 OpenRAM
  // macro's output is. The caches must pass with it on, which proves they
  // never rely on rdata_o holding its value.
  bit poison;
  initial poison = $test$plusargs("sram_poison");
`endif

  always_ff @(posedge clk_i) begin
    if (en_i && we_i) begin
      for (int b = 0; b < int'(NBE); b++)
        if (be_i[b]) mem_q[addr_i][b*GRAN +: GRAN] <= wdata_i[b*GRAN +: GRAN];
    end
    if (en_i && !we_i) begin
      rdata_o <= mem_q[addr_i];
    end
`ifndef SYNTHESIS
    else if (poison) begin
      rdata_o <= WIDTH'({$urandom, $urandom});
    end
`endif
  end

`endif

`ifndef SYNTHESIS
  initial begin
    if (WIDTH % GRAN != 0) $fatal(1, "[sram_wrapper] WIDTH %0d is not a multiple of GRAN %0d", WIDTH, GRAN);
  end
`endif

endmodule : sram_wrapper
