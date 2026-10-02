// =============================================================================
// apb_if  (UVM testbench, docs/architecture.md P7.2)
// -----------------------------------------------------------------------------
// Purpose : One APB4 peripheral slot inside the DUT, observed by the passive APB monitor.
// =============================================================================
// Signals here are driven and sampled through virtual interfaces from UVM class
// code, which Verilator's driver/usage analysis does not follow: UNDRIVEN and
// UNUSEDSIGNAL are false positives for this interface.
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */
interface apb_if (
  input logic clk,
  input logic rst_n
);
  apb_pkg::apb_req_t req;
  apb_pkg::apb_rsp_t rsp;
endinterface : apb_if
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
