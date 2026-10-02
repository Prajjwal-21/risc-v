// =============================================================================
// spi_slave_model  (testbench only, not synthesizable)
// -----------------------------------------------------------------------------
// Purpose    : Behavioural SPI slave for the SoC testbench (docs/architecture.md
//              P6.6). Configured like a real slave: the mode (CPOL, CPHA) and
//              bit order are inputs (the testbench wires the DUT's CTRL
//              register to them). It answers each 8-bit frame with the bitwise
//              complement of the previous byte it received (0x3C before the
//              first), so every byte software reads back proves that the
//              previous frame arrived intact, in the right mode and bit order.
// Interfaces : sclk_i, mosi_i, cs_n_i from the master; miso_o to it.
// Timing     : event-driven on SCLK edges while cs_n_i is low, like a real
//              slave. CPHA = 0: MISO holds bit 0 before the first edge; MOSI is
//              sampled on leading edges and the next MISO bit driven on
//              trailing edges; the trailing edge after the 8th sample ends the
//              frame. CPHA = 1: MISO driven on leading edges, MOSI sampled on
//              trailing edges; the 8th sample ends the frame.
// Checks     : SCLK is at CPOL whenever CS is asserted outside a frame; CS is
//              never released in the middle of a frame. n_frames counts
//              complete frames; last_rx is the last byte received.
// =============================================================================
module spi_slave_model (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic sclk_i,
  input  logic mosi_i,
  input  logic cs_n_i,
  output logic miso_o,
  input  logic cpol_i,
  input  logic cpha_i,
  input  logic lsb_i
);

  logic [7:0]      tx_byte, rx_sh;
  // For debugging in a waveform or with a hierarchical reference.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [7:0]      last_rx;
  /* verilator lint_on UNUSEDSIGNAL */
  int              samples, drives;          // in the current frame
  longint unsigned n_frames;

  function automatic logic bit_of(logic [7:0] b, int k, logic lsb);
    return lsb ? b[k] : b[7 - k];
  endfunction

  task automatic end_frame();
    last_rx = rx_sh;
    tx_byte = ~rx_sh;
    samples = 0;
    drives  = 0;
    n_frames++;
    if (!cpha_i) miso_o = bit_of(tx_byte, 0, lsb_i);
  endtask

  initial begin
    tx_byte  = 8'h3C;
    rx_sh    = '0;
    last_rx  = '0;
    samples  = 0;
    drives   = 0;
    n_frames = 0;
    miso_o   = 1'b0;
  end

  // Behavioural model: MISO changes immediately on each event, as the pin of a
  // real slave would, so blocking assignments are intended here.
  /* verilator lint_off BLKSEQ */

  // CPHA = 0: bit 0 must be on MISO before the first edge of a transaction.
  always @(negedge cs_n_i) begin
    if (!cpha_i && samples == 0) miso_o = bit_of(tx_byte, 0, lsb_i);
  end

  always @(sclk_i) begin
    if (rst_ni && !cs_n_i) begin
      logic leading;
      leading = (sclk_i != cpol_i);
      if (leading != cpha_i) begin                       // sample MOSI
        rx_sh = lsb_i ? {mosi_i, rx_sh[7:1]} : {rx_sh[6:0], mosi_i};
        samples++;
        if (cpha_i && samples == 8) end_frame();
      end else if (cpha_i) begin                         // CPHA 1: drive on leading
        miso_o = bit_of(tx_byte, drives, lsb_i);
        drives++;
      end else if (samples == 8) begin                   // CPHA 0: last trailing edge
        end_frame();
      end else begin                                     // CPHA 0: drive the next bit
        drives++;
        miso_o = bit_of(tx_byte, drives, lsb_i);
      end
    end
  end

  /* verilator lint_on BLKSEQ */

  // Checks, on the system clock
  always @(posedge clk_i) begin
    if (rst_ni && !cs_n_i && samples == 0 && drives == 0 && sclk_i != cpol_i)
      $fatal(1, "[spi_slave_model] SCLK=%0b away from CPOL=%0b between frames with CS asserted",
             sclk_i, cpol_i);
  end

  always @(posedge cs_n_i) begin
    if (rst_ni && (samples != 0 || drives != 0))
      $fatal(1, "[spi_slave_model] CS released in the middle of a frame (%0d bits sampled)", samples);
  end

endmodule : spi_slave_model
