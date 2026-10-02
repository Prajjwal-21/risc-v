// =============================================================================
// axil_pkg
// -----------------------------------------------------------------------------
// Purpose    : AXI4-Lite channel types (docs/architecture.md P5.2, D-047). A
//              link is one request struct (master -> slave) and one response
//              struct (slave -> master); packed structs rather than SV
//              interfaces, for synthesis portability (Yosys / sv2v).
// Interfaces : none (package).
// Timing     : n/a.
// =============================================================================
package axil_pkg;

  // Waiver: a package is a catalogue of constants; not every constant is
  // referenced by every module or build configuration.
  /* verilator lint_off UNUSEDPARAM */

  localparam int unsigned AXIL_ADDR_W = 32;
  localparam int unsigned AXIL_DATA_W = 32;
  localparam int unsigned AXIL_STRB_W = AXIL_DATA_W / 8;

  // RRESP / BRESP encodings
  localparam logic [1:0] AXI_RESP_OKAY   = 2'b00;
  localparam logic [1:0] AXI_RESP_EXOKAY = 2'b01;   // not used by AXI4-Lite
  localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;
  localparam logic [1:0] AXI_RESP_DECERR = 2'b11;

  // AxPROT: unprivileged/privileged, secure/non-secure, data/instruction.
  // The SoC issues data accesses as privileged, and instruction fetches with
  // the instruction bit set.
  localparam logic [2:0] AXI_PROT_DATA  = 3'b001;
  localparam logic [2:0] AXI_PROT_INSTR = 3'b101;

  /* verilator lint_on UNUSEDPARAM */

  typedef struct packed {
    logic [AXIL_ADDR_W-1:0] addr;
    logic [2:0]             prot;
  } axil_ax_t;                                     // AW and AR payload

  typedef struct packed {
    logic [AXIL_DATA_W-1:0] data;
    logic [AXIL_STRB_W-1:0] strb;
  } axil_w_t;

  typedef struct packed {
    logic [1:0] resp;
  } axil_b_t;

  typedef struct packed {
    logic [AXIL_DATA_W-1:0] data;
    logic [1:0]             resp;
  } axil_r_t;

  // Master -> slave
  typedef struct packed {
    logic     aw_valid;
    axil_ax_t aw;
    logic     w_valid;
    axil_w_t  w;
    logic     b_ready;
    logic     ar_valid;
    axil_ax_t ar;
    logic     r_ready;
  } axil_req_t;

  // Slave -> master
  typedef struct packed {
    logic    aw_ready;
    logic    w_ready;
    logic    b_valid;
    axil_b_t b;
    logic    ar_ready;
    logic    r_valid;
    axil_r_t r;
  } axil_rsp_t;

endpackage : axil_pkg
