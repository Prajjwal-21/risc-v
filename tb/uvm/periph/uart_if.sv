// =============================================================================
// uart_if  (UVM testbench, docs/architecture.md P7.2)
// -----------------------------------------------------------------------------
// Purpose : UART pins: tx from the DUT (monitored), rx into the DUT (driven by the UART agent).
// =============================================================================
// Signals here are driven and sampled through virtual interfaces from UVM class
// code, which Verilator's driver/usage analysis does not follow: UNDRIVEN and
// UNUSEDSIGNAL are false positives for this interface.
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */
interface uart_if (
  input logic clk,
  input logic rst_n
);
  logic tx;
  logic rx;
endinterface : uart_if
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
