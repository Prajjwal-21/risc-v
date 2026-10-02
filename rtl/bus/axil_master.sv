// =============================================================================
// axil_master
// -----------------------------------------------------------------------------
// Purpose    : Turns one core-protocol memory request into one AXI4-Lite
//              transaction (architecture.md P5.1): a read is AR then R; a
//              write is AW and W together, then B. rsp.err = RESP[1] (SLVERR
//              or DECERR: an access fault).
// Interfaces : slave side: the core port protocol (section 2); instr_i marks
//              an instruction fetch (AxPROT[2]). Master side: AXI4-Lite.
// Timing     : * req_ready_o is 1 only in IDLE (registered): one transaction
//                at a time.
//              * AW/W/AR valid come from registered state, never from a ready
//                (AXI and protocol rule 2), and stay up until accepted.
//              * the response is the B or R handshake itself, at least two
//                cycles after acceptance; it never depends on req_valid_i.
// =============================================================================
module axil_master
  import riscv_pkg::*;
  import axil_pkg::*;
(
  input  logic      clk_i,
  // rst_ni is also sampled by the simulation-only assertions (disable iff),
  // which Verilator reports as a synchronous use of an async reset.
  /* verilator lint_off SYNCASYNCNET */
  input  logic      rst_ni,
  /* verilator lint_on SYNCASYNCNET */

  input  logic      req_valid_i,
  output logic      req_ready_o,
  input  mem_req_t  req_i,
  input  logic      instr_i,
  output logic      rsp_valid_o,
  output mem_rsp_t  rsp_o,

  output axil_req_t axil_req_o,
  input  axil_rsp_t axil_rsp_i
);

  typedef enum logic [2:0] { S_IDLE, S_WRITE, S_BRESP, S_READ, S_RRESP } state_e;

  state_e   state_q;
  // .we is not read back: it chooses the state (S_WRITE or S_READ) instead.
  /* verilator lint_off UNUSEDSIGNAL */
  mem_req_t req_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic     prot_instr_q;
  logic     aw_pend_q, w_pend_q;     // AW / W still to be accepted

  assign req_ready_o = (state_q == S_IDLE);

  logic aw_fire, w_fire;
  assign aw_fire = axil_req_o.aw_valid && axil_rsp_i.aw_ready;
  assign w_fire  = axil_req_o.w_valid  && axil_rsp_i.w_ready;

  always_comb begin
    axil_req_o          = '0;
    axil_req_o.aw_valid = (state_q == S_WRITE) && aw_pend_q;
    axil_req_o.aw       = '{addr: req_q.addr, prot: AXI_PROT_DATA};
    axil_req_o.w_valid  = (state_q == S_WRITE) && w_pend_q;
    axil_req_o.w        = '{data: req_q.wdata, strb: req_q.be};
    axil_req_o.b_ready  = (state_q == S_BRESP);
    axil_req_o.ar_valid = (state_q == S_READ);
    axil_req_o.ar       = '{addr: req_q.addr, prot: prot_instr_q ? AXI_PROT_INSTR : AXI_PROT_DATA};
    axil_req_o.r_ready  = (state_q == S_RRESP);
  end

  assign rsp_valid_o = ((state_q == S_BRESP) && axil_rsp_i.b_valid)
                    || ((state_q == S_RRESP) && axil_rsp_i.r_valid);
  assign rsp_o = (state_q == S_RRESP) ? '{rdata: axil_rsp_i.r.data, err: axil_rsp_i.r.resp[1]}
                                      : '{rdata: '0,                err: axil_rsp_i.b.resp[1]};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= S_IDLE;
      req_q        <= '0;
      prot_instr_q <= 1'b0;
      aw_pend_q    <= 1'b0;
      w_pend_q     <= 1'b0;
    end else begin
      unique case (state_q)
        S_IDLE: if (req_valid_i) begin
          req_q        <= req_i;
          prot_instr_q <= instr_i;
          aw_pend_q    <= req_i.we;
          w_pend_q     <= req_i.we;
          state_q      <= req_i.we ? S_WRITE : S_READ;
        end
        S_WRITE: begin
          if (aw_fire) aw_pend_q <= 1'b0;
          if (w_fire)  w_pend_q  <= 1'b0;
          if ((aw_fire || !aw_pend_q) && (w_fire || !w_pend_q)) state_q <= S_BRESP;
        end
        S_BRESP: if (axil_rsp_i.b_valid)             state_q <= S_IDLE;
        S_READ:  if (axil_rsp_i.ar_ready)            state_q <= S_RRESP;
        S_RRESP: if (axil_rsp_i.r_valid)             state_q <= S_IDLE;
        default:                                     state_q <= S_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  // The I-side never writes.
  a_instr_read: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                 (req_valid_i && req_ready_o && instr_i) |-> !req_i.we)
    else $fatal(1, "[axil_master] instruction-side write");
`endif

endmodule : axil_master
