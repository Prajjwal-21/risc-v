// =============================================================================
// sync_2ff
// -----------------------------------------------------------------------------
// Purpose    : Two-flop synchronizer for an asynchronous input (UART RX,
//              docs/architecture.md P6.1).
// Interfaces : d_i asynchronous; q_o synchronous to clk_i, 2 cycles later.
// Timing     : both flops reset to RESET_VAL (the input's idle level).
// =============================================================================
module sync_2ff #(
  parameter logic RESET_VAL = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic d_i,
  output logic q_o
);

  logic meta_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      meta_q <= RESET_VAL;
      q_o    <= RESET_VAL;
    end else begin
      meta_q <= d_i;
      q_o    <= meta_q;
    end
  end

endmodule : sync_2ff
