// =============================================================================
// write_buffer
// -----------------------------------------------------------------------------
// Purpose    : D-cache write buffer (docs/architecture.md P4.3): a FIFO of
//              DEPTH stores to main memory, drained in order to the memory
//              side. The D-cache acknowledges a cacheable store once it is
//              pushed here.
// Interfaces : push_i/push_req_i from the D-cache (never while full_o);
//              memory side: the core port protocol as a master; mem_rsp_valid_i
//              is the response to one of this buffer's writes (the D-cache
//              routes responses here while busy_o).
//              full_o: no free entry. idle_o: empty and every write
//              acknowledged. busy_o: a write awaits its response.
// Timing     : full_o, idle_o, busy_o and mem_req_valid_o depend only on
//              registered state. Up to MAX_OUT writes may await a response.
//              The head entry stays on mem_req_o until accepted (rule 1).
// =============================================================================
module write_buffer
  import riscv_pkg::*;
#(
  parameter int unsigned DEPTH   = soc_pkg::WBUF_DEPTH,
  parameter int unsigned MAX_OUT = soc_pkg::WBUF_MAX_OUT
) (
  input  logic     clk_i,
  // rst_ni is also sampled by the simulation-only assertions (disable iff),
  // which Verilator reports as a synchronous use of an async reset.
  /* verilator lint_off SYNCASYNCNET */
  input  logic     rst_ni,
  /* verilator lint_on SYNCASYNCNET */

  input  logic     push_i,
  input  mem_req_t push_req_i,
  output logic     full_o,
  output logic     idle_o,
  output logic     busy_o,

  output logic     mem_req_valid_o,
  input  logic     mem_req_ready_i,
  output mem_req_t mem_req_o,
  input  logic     mem_rsp_valid_i,
  // Only err is used: a write response carries no data.
  /* verilator lint_off UNUSEDSIGNAL */
  input  mem_rsp_t mem_rsp_i
  /* verilator lint_on UNUSEDSIGNAL */
);

  localparam int unsigned PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  localparam int unsigned CNT_W = $clog2(DEPTH + 1);
  localparam int unsigned OUT_W = $clog2(MAX_OUT + 1);

  typedef logic [PTR_W-1:0] ptr_t;
  typedef logic [CNT_W-1:0] cnt_t;
  typedef logic [OUT_W-1:0] out_t;

  mem_req_t fifo_q [DEPTH];
  ptr_t     head_q, tail_q;
  cnt_t     cnt_q;
  out_t     out_q;               // writes accepted, response pending

  logic pop;

  assign full_o          = (cnt_q == cnt_t'(DEPTH));
  assign idle_o          = (cnt_q == '0) && (out_q == '0);
  assign busy_o          = (out_q != '0);
  assign mem_req_valid_o = (cnt_q != '0) && (out_q != out_t'(MAX_OUT));
  assign mem_req_o       = fifo_q[head_q];
  assign pop             = mem_req_valid_o && mem_req_ready_i;

  function automatic ptr_t next_ptr(ptr_t p);
    return (p == ptr_t'(DEPTH - 1)) ? '0 : p + ptr_t'(1);
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fifo_q <= '{default: '0};
      head_q <= '0;
      tail_q <= '0;
      cnt_q  <= '0;
      out_q  <= '0;
    end else begin
      if (push_i) begin
        fifo_q[tail_q] <= push_req_i;
        tail_q         <= next_ptr(tail_q);
      end
      if (pop) head_q <= next_ptr(head_q);
      cnt_q <= cnt_q + cnt_t'(push_i) - cnt_t'(pop);
      out_q <= out_q + out_t'(pop) - out_t'(mem_rsp_valid_i);
    end
  end

`ifndef SYNTHESIS
  a_push_full: assert property (@(posedge clk_i) disable iff (!rst_ni) !(push_i && full_o))
    else $fatal(1, "[write_buffer] push while full");
  a_rsp: assert property (@(posedge clk_i) disable iff (!rst_ni) mem_rsp_valid_i |-> busy_o)
    else $fatal(1, "[write_buffer] response with no write outstanding");
  // Only main-memory stores are buffered, and main memory never errors (D-045).
  a_no_err: assert property (@(posedge clk_i) disable iff (!rst_ni) !(mem_rsp_valid_i && mem_rsp_i.err))
    else $fatal(1, "[write_buffer] buffered store got an error response");
  a_push_we: assert property (@(posedge clk_i) disable iff (!rst_ni) push_i |-> push_req_i.we)
    else $fatal(1, "[write_buffer] push of a non-store");
`endif

endmodule : write_buffer
