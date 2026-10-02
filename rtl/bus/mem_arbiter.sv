// =============================================================================
// mem_arbiter
// -----------------------------------------------------------------------------
// Purpose    : Merges the I-side and D-side memory ports (the caches' memory
//              sides) into one port towards axil_master (architecture.md
//              P5.1). Round-robin between the two; one transaction at a time.
// Interfaces : two slave ports and one master port, all in the core port
//              protocol (architecture.md section 2); m_instr_o marks a
//              request from the I-side (AXI AxPROT[2]).
// Timing     : * m_req_valid_o depends on registered state and the two request
//                valids, never on any ready (protocol rule 2).
//              * a granted request that waits for m_req_ready_i keeps the
//                grant (lock_q) until accepted, so the master port's request
//                stays stable (rule 1).
//              * the response goes to the owner recorded at acceptance; the
//                next request is granted from the cycle after the response.
// =============================================================================
module mem_arbiter
  import riscv_pkg::*;
(
  input  logic     clk_i,
  // rst_ni is also sampled by the simulation-only assertions (disable iff),
  // which Verilator reports as a synchronous use of an async reset.
  /* verilator lint_off SYNCASYNCNET */
  input  logic     rst_ni,
  /* verilator lint_on SYNCASYNCNET */

  // I-side (requester 0)
  input  logic     i_req_valid_i,
  output logic     i_req_ready_o,
  input  mem_req_t i_req_i,
  output logic     i_rsp_valid_o,
  output mem_rsp_t i_rsp_o,

  // D-side (requester 1)
  input  logic     d_req_valid_i,
  output logic     d_req_ready_o,
  input  mem_req_t d_req_i,
  output logic     d_rsp_valid_o,
  output mem_rsp_t d_rsp_o,

  // Towards axil_master
  output logic     m_req_valid_o,
  input  logic     m_req_ready_i,
  output mem_req_t m_req_o,
  output logic     m_instr_o,
  input  logic     m_rsp_valid_i,
  input  mem_rsp_t m_rsp_i
);

  logic busy_q;        // a request was accepted, its response is pending
  logic owner_q;       // 1: the D-side owns the pending transaction
  logic lock_q;        // last cycle's request was not accepted: keep the grant
  logic lock_d_q;      // ...and it was the D-side's
  logic last_d_q;      // the D-side won the last arbitration (round-robin)
  logic grant_d;       // this cycle's grant: 1 = D-side

  always_comb begin
    if (lock_q)                             grant_d = lock_d_q;
    else if (i_req_valid_i && d_req_valid_i) grant_d = !last_d_q;
    else                                    grant_d = d_req_valid_i;
  end

  assign m_req_valid_o = !busy_q && (grant_d ? d_req_valid_i : i_req_valid_i);
  assign m_req_o       = grant_d ? d_req_i : i_req_i;
  assign m_instr_o     = !grant_d;

  logic fire;
  assign fire          = m_req_valid_o && m_req_ready_i;
  assign i_req_ready_o = !grant_d && !busy_q && m_req_ready_i;
  assign d_req_ready_o =  grant_d && !busy_q && m_req_ready_i;

  assign i_rsp_valid_o = m_rsp_valid_i && busy_q && !owner_q;
  assign d_rsp_valid_o = m_rsp_valid_i && busy_q &&  owner_q;
  assign i_rsp_o       = m_rsp_i;
  assign d_rsp_o       = m_rsp_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q   <= 1'b0;
      owner_q  <= 1'b0;
      lock_q   <= 1'b0;
      lock_d_q <= 1'b0;
      last_d_q <= 1'b0;
    end else begin
      lock_q   <= m_req_valid_o && !m_req_ready_i;
      lock_d_q <= grant_d;
      if (fire) begin
        busy_q   <= 1'b1;
        owner_q  <= grant_d;
        last_d_q <= grant_d;
      end else if (m_rsp_valid_i) begin
        busy_q <= 1'b0;
      end
    end
  end

`ifndef SYNTHESIS
  a_rsp_owned: assert property (@(posedge clk_i) disable iff (!rst_ni) m_rsp_valid_i |-> busy_q)
    else $fatal(1, "[mem_arbiter] response with no transaction pending");
  a_no_rsp_same_cycle: assert property (@(posedge clk_i) disable iff (!rst_ni) !(fire && m_rsp_valid_i))
    else $fatal(1, "[mem_arbiter] response in the acceptance cycle");
`endif

endmodule : mem_arbiter
