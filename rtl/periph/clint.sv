// =============================================================================
// clint
// -----------------------------------------------------------------------------
// Purpose    : Core-local interruptor (docs/architecture.md P6.2): msip,
//              mtimecmp and mtime at the standard offsets. mtime counts once
//              every PRESCALE clock cycles and also drives the core's time CSR.
// Interfaces : APB4 slave (apb_req_i/apb_rsp_o); irq_software_o and
//              irq_timer_o to the core; mtime_o to the core's mtime_i.
// Timing     : zero wait states (PREADY = 1, D-034); a write takes effect at
//              the end of its ACCESS cycle. The interrupt lines are registered:
//              irq_timer_o = (mtime >= mtimecmp) one cycle late.
//              Offsets without a register answer PSLVERR.
// =============================================================================
module clint
  import apb_pkg::*;
  import soc_pkg::*;
#(
  parameter int unsigned PRESCALE = MTIME_PRESCALE
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  // Only the offset bits of PADDR are decoded (the bridge selects the window).
  /* verilator lint_off UNUSEDSIGNAL */
  input  apb_req_t    apb_req_i,
  /* verilator lint_on UNUSEDSIGNAL */
  output apb_rsp_t    apb_rsp_o,
  output logic        irq_software_o,
  output logic        irq_timer_o,
  output logic [63:0] mtime_o
);

  localparam int unsigned PS_W = (PRESCALE > 1) ? $clog2(PRESCALE) : 1;

  logic        msip_q;
  logic [63:0] mtimecmp_q, mtime_q;
  logic [PS_W-1:0] ps_q;

  logic        access, wr;
  logic [15:0] off;
  assign access = apb_req_i.psel && apb_req_i.penable;
  assign wr     = access && apb_req_i.pwrite;
  assign off    = apb_req_i.paddr[15:0];

  function automatic logic [31:0] merge(logic [31:0] old, logic [31:0] wdata, logic [3:0] strb);
    for (int b = 0; b < 4; b++) if (strb[b]) old[8*b +: 8] = wdata[8*b +: 8];
    return old;
  endfunction

  // ---------------------------------------------------------------------------
  // Read data and errors
  // ---------------------------------------------------------------------------
  logic        known;
  logic [31:0] rdata;
  always_comb begin
    known = 1'b1;
    rdata = '0;
    unique case (off)
      CLINT_MSIP:      rdata = {31'b0, msip_q};
      CLINT_MTIMECMP:  rdata = mtimecmp_q[31:0];
      CLINT_MTIMECMPH: rdata = mtimecmp_q[63:32];
      CLINT_MTIME:     rdata = mtime_q[31:0];
      CLINT_MTIMEH:    rdata = mtime_q[63:32];
      default:         known = 1'b0;
    endcase
  end

  assign apb_rsp_o = '{prdata: rdata, pready: 1'b1, pslverr: access && !known};

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  logic tick;
  assign tick = (PRESCALE <= 1) || (ps_q == PS_W'(PRESCALE - 1));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      msip_q         <= 1'b0;
      mtimecmp_q     <= '1;
      mtime_q        <= '0;
      ps_q           <= '0;
      irq_software_o <= 1'b0;
      irq_timer_o    <= 1'b0;
    end else begin
      ps_q <= tick ? '0 : ps_q + PS_W'(1);
      if (tick) mtime_q <= mtime_q + 64'd1;
      if (wr) begin
        unique case (off)
          CLINT_MSIP:      if (apb_req_i.pstrb[0]) msip_q <= apb_req_i.pwdata[0];
          CLINT_MTIMECMP:  mtimecmp_q[31:0]  <= merge(mtimecmp_q[31:0],  apb_req_i.pwdata, apb_req_i.pstrb);
          CLINT_MTIMECMPH: mtimecmp_q[63:32] <= merge(mtimecmp_q[63:32], apb_req_i.pwdata, apb_req_i.pstrb);
          CLINT_MTIME:     mtime_q[31:0]     <= merge(mtime_q[31:0],     apb_req_i.pwdata, apb_req_i.pstrb);
          CLINT_MTIMEH:    mtime_q[63:32]    <= merge(mtime_q[63:32],    apb_req_i.pwdata, apb_req_i.pstrb);
          default: ;
        endcase
      end
      irq_software_o <= msip_q;
      irq_timer_o    <= (mtime_q >= mtimecmp_q);
    end
  end

  assign mtime_o = mtime_q;

endmodule : clint
