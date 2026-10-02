// =============================================================================
// sync_fifo
// -----------------------------------------------------------------------------
// Purpose    : Single-clock FIFO for the UART and SPI data paths (docs/
//              architecture.md P6.4, P6.5).
// Interfaces : push_i/wdata_i (ignored when full), pop_i (ignored when empty);
//              rdata_o is the head entry (valid when !empty_o).
// Timing     : registered storage and pointers; full_o/empty_o/count_o depend
//              only on registers. A push and a pop in the same cycle are both
//              performed.
// =============================================================================
module sync_fifo #(
  parameter int unsigned DEPTH = 8,
  parameter int unsigned WIDTH = 8,
  localparam int unsigned PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1,
  localparam int unsigned CNT_W = $clog2(DEPTH + 1)
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             push_i,
  input  logic [WIDTH-1:0] wdata_i,
  input  logic             pop_i,
  output logic [WIDTH-1:0] rdata_o,
  output logic             full_o,
  output logic             empty_o,
  output logic [CNT_W-1:0] count_o
);

  typedef logic [PTR_W-1:0] ptr_t;

  logic [WIDTH-1:0] mem_q [DEPTH];
  ptr_t             head_q, tail_q;
  logic [CNT_W-1:0] cnt_q;
  logic             do_push, do_pop;

  assign full_o  = (cnt_q == CNT_W'(DEPTH));
  assign empty_o = (cnt_q == '0);
  assign count_o = cnt_q;
  assign rdata_o = mem_q[head_q];
  assign do_push = push_i && !full_o;
  assign do_pop  = pop_i && !empty_o;

  function automatic ptr_t next_ptr(ptr_t p);
    return (p == ptr_t'(DEPTH - 1)) ? '0 : p + ptr_t'(1);
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_q  <= '{default: '0};
      head_q <= '0;
      tail_q <= '0;
      cnt_q  <= '0;
    end else begin
      if (do_push) begin
        mem_q[tail_q] <= wdata_i;
        tail_q        <= next_ptr(tail_q);
      end
      if (do_pop) head_q <= next_ptr(head_q);
      cnt_q <= cnt_q + CNT_W'(do_push) - CNT_W'(do_pop);
    end
  end

endmodule : sync_fifo
