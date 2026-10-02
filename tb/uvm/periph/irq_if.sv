// =============================================================================
// irq_if  (UVM testbench, docs/architecture.md P7.2)
// -----------------------------------------------------------------------------
// Purpose : The DUT's interrupt lines towards the core, and mtime.
// =============================================================================
// Signals here are driven and sampled through virtual interfaces from UVM class
// code, which Verilator's driver/usage analysis does not follow: UNDRIVEN and
// UNUSEDSIGNAL are false positives for this interface.
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */
interface irq_if (
  input logic clk,
  input logic rst_n
);
  logic        sw;
  logic        timer;
  logic        ext;
  logic [63:0] mtime;
endinterface : irq_if
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
