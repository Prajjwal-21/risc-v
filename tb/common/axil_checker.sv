// =============================================================================
// axil_checker  (testbench only)
// -----------------------------------------------------------------------------
// Purpose    : AXI4-Lite protocol checker for one link (docs/architecture.md
//              P5.5). Stops the simulation on the first violation.
// Interfaces : req_i/rsp_i: the link's request and response structs (read
//              only). NAME labels the messages.
// Checks     : * AW, W, AR (master) and B, R (slave): once valid is high
//                without ready, valid stays high and the payload is unchanged
//                until the handshake;
//              * a B only while a write (AW and W) is outstanding, an R only
//                while a read is outstanding; at most MAX_OUT of each;
//              * no AW/W/AR/B/R valid during reset.
//              Counters n_rd/n_wr (completed transactions) are read by the
//              testbench.
// =============================================================================
module axil_checker
  import axil_pkg::*;
#(
  parameter string       NAME    = "axil",
  parameter int unsigned MAX_OUT = 1
) (
  input logic      clk_i,
  input logic      rst_ni,
  input axil_req_t req_i,
  input axil_rsp_t rsp_i
);

  axil_req_t       req_q;
  axil_rsp_t       rsp_q;
  int              aw_out, w_out, ar_out;     // accepted, response pending
  longint unsigned n_rd, n_wr;

  function automatic void fail(string msg);
    $fatal(1, "[axil_checker %s] %s", NAME, msg);
  endfunction

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      if (req_i.aw_valid || req_i.w_valid || req_i.ar_valid || rsp_i.b_valid || rsp_i.r_valid)
        fail("valid asserted during reset");
      aw_out <= 0;
      w_out  <= 0;
      ar_out <= 0;
      n_rd   <= 0;
      n_wr   <= 0;
    end else begin
      // Stability: last cycle valid && !ready  ->  this cycle valid, same payload
      if (req_q.aw_valid && !rsp_q.aw_ready && !(req_i.aw_valid && req_i.aw == req_q.aw))
        fail("AW withdrawn or changed before AWREADY");
      if (req_q.w_valid && !rsp_q.w_ready && !(req_i.w_valid && req_i.w == req_q.w))
        fail("W withdrawn or changed before WREADY");
      if (req_q.ar_valid && !rsp_q.ar_ready && !(req_i.ar_valid && req_i.ar == req_q.ar))
        fail("AR withdrawn or changed before ARREADY");
      if (rsp_q.b_valid && !req_q.b_ready && !(rsp_i.b_valid && rsp_i.b == rsp_q.b))
        fail("B withdrawn or changed before BREADY");
      if (rsp_q.r_valid && !req_q.r_ready && !(rsp_i.r_valid && rsp_i.r == rsp_q.r))
        fail("R withdrawn or changed before RREADY");

      // Responses only for outstanding requests
      if (rsp_i.b_valid && (aw_out == 0 || w_out == 0))
        fail("B without an outstanding write (AW and W)");
      if (rsp_i.r_valid && ar_out == 0)
        fail("R without an outstanding read");

      begin
        int aw_n, w_n, ar_n;
        aw_n = aw_out + int'(req_i.aw_valid && rsp_i.aw_ready) - int'(rsp_i.b_valid && req_i.b_ready);
        w_n  = w_out  + int'(req_i.w_valid  && rsp_i.w_ready)  - int'(rsp_i.b_valid && req_i.b_ready);
        ar_n = ar_out + int'(req_i.ar_valid && rsp_i.ar_ready) - int'(rsp_i.r_valid && req_i.r_ready);
        if (aw_n > int'(MAX_OUT) || w_n > int'(MAX_OUT) || ar_n > int'(MAX_OUT))
          fail($sformatf("more than %0d transactions outstanding in one direction", MAX_OUT));
        aw_out <= aw_n;
        w_out  <= w_n;
        ar_out <= ar_n;
      end
      if (rsp_i.b_valid && req_i.b_ready) n_wr <= n_wr + 1;
      if (rsp_i.r_valid && req_i.r_ready) n_rd <= n_rd + 1;
    end
    req_q <= req_i;
    rsp_q <= rsp_i;
  end

endmodule : axil_checker
