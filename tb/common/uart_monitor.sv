// =============================================================================
// uart_monitor  (testbench only, not synthesizable)
// -----------------------------------------------------------------------------
// Purpose    : Decodes 8N1 frames on a UART line (docs/architecture.md P6.6):
//              waits for a start bit, samples each bit in its middle using the
//              bit length div_i (the DUT's BAUDDIV, read hierarchically), and
//              checks the stop bit. With +uart_log the characters are printed
//              as "[uart] <text>" lines, so a program's output appears in the
//              simulation log.
// Interfaces : line_i (the TX pin), div_i (clock cycles per bit).
// Checks     : a stop bit of 0 stops the simulation (the DUT's transmitter
//              must never produce one). n_bytes counts decoded bytes.
// =============================================================================
module uart_monitor (
  input logic        clk_i,
  input logic        rst_ni,
  input logic        line_i,
  input logic [15:0] div_i
);

  longint unsigned n_bytes;
  bit              log_on;
  string           text;

  initial begin
    n_bytes = 0;
    text    = "";
    log_on  = $test$plusargs("uart_log");
  end

  task automatic wait_cycles(int n);
    repeat (n) @(posedge clk_i);
  endtask

  initial begin
    @(posedge rst_ni);
    forever begin
      logic [7:0] b;
      int         d;
      @(negedge line_i);
      d = (div_i < 2) ? 2 : int'(div_i);
      wait_cycles(d / 2);
      if (line_i) continue;                          // glitch
      for (int i = 0; i < 8; i++) begin
        wait_cycles(d);
        b[i] = line_i;
      end
      wait_cycles(d);
      if (!line_i) $fatal(1, "[uart_monitor] stop bit is 0 after byte %02h", b);
      n_bytes++;
      if (log_on) begin
        if (b == 8'h0a) begin
          $display("[uart] %s", text);
          text = "";
        end else if (b >= 8'h20 && b < 8'h7f) begin
          text = {text, string'(b)};
        end
      end
    end
  end

  final if (log_on && text != "") $display("[uart] %s", text);

endmodule : uart_monitor
