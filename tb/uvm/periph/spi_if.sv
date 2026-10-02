// =============================================================================
// spi_if  (UVM testbench, docs/architecture.md P7.2)
// -----------------------------------------------------------------------------
// Purpose : SPI pins: sclk, mosi, cs_n from the DUT; miso driven by the SPI slave agent.
// =============================================================================
// Signals here are driven and sampled through virtual interfaces from UVM class
// code, which Verilator's driver/usage analysis does not follow: UNDRIVEN and
// UNUSEDSIGNAL are false positives for this interface.
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */
interface spi_if (
  input logic clk,
  input logic rst_n
);
  logic sclk;
  logic mosi;
  logic miso;
  logic cs_n;
endinterface : spi_if
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
