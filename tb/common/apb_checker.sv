// =============================================================================
// apb_checker  (testbench only)
// -----------------------------------------------------------------------------
// Purpose    : APB4 protocol checker for one peripheral slot (docs/
//              architecture.md P5.5). Stops the simulation on the first
//              violation.
// Interfaces : req_i/rsp_i: the slot's request and response structs.
// Checks     : * PENABLE only with PSEL, and only after one SETUP cycle
//                (PSEL && !PENABLE);
//              * PADDR, PWRITE, PWDATA, PSTRB, PPROT stable from SETUP until
//                the transfer ends (PREADY in ACCESS), and PSEL/PENABLE held;
//              * after the transfer PENABLE drops;
//              * PSTRB = 0 on reads (APB4).
//              n_xfer (completed transfers) is read by the testbench.
// =============================================================================
module apb_checker
  import apb_pkg::*;
#(
  parameter string NAME = "apb"
) (
  input logic     clk_i,
  input logic     rst_ni,
  input apb_req_t req_i,
  // Only PREADY matters to the protocol rules checked here.
  /* verilator lint_off UNUSEDSIGNAL */
  input apb_rsp_t rsp_i
  /* verilator lint_on UNUSEDSIGNAL */
);

  apb_req_t        req_q;
  logic            ended_q;       // a transfer ended in the previous cycle
  longint unsigned n_xfer;

  function automatic void fail(string msg);
    $fatal(1, "[apb_checker %s] %s", NAME, msg);
  endfunction

  // The command fields (PSEL/PENABLE are checked separately).
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic same_cmd(apb_req_t a, apb_req_t b);
    return a.paddr == b.paddr && a.pwrite == b.pwrite && a.pwdata == b.pwdata
        && a.pstrb == b.pstrb && a.pprot == b.pprot;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      if (req_i.psel) fail("PSEL during reset");
      ended_q <= 1'b0;
      n_xfer  <= 0;
    end else begin
      if (req_i.penable && !req_i.psel) fail("PENABLE without PSEL");
      if (req_i.psel && !req_i.pwrite && req_i.pstrb != '0) fail("PSTRB not 0 on a read");
      // ACCESS must follow a SETUP cycle of the same transfer
      if (req_i.penable && !(req_q.psel && (!req_q.penable || !ended_q)))
        fail("PENABLE without a preceding SETUP cycle");
      if (req_i.penable && req_q.psel && !same_cmd(req_i, req_q))
        fail("PADDR/PWRITE/PWDATA/PSTRB/PPROT changed during a transfer");
      // A transfer in ACCESS without PREADY continues
      if (req_q.psel && req_q.penable && !ended_q && !(req_i.psel && req_i.penable))
        fail("transfer abandoned before PREADY");
      if (ended_q && req_i.penable) fail("PENABLE held after the transfer ended");
      if (req_i.psel && req_i.penable && rsp_i.pready) n_xfer <= n_xfer + 1;
      ended_q <= req_i.psel && req_i.penable && rsp_i.pready;
    end
    req_q <= req_i;
  end

endmodule : apb_checker
