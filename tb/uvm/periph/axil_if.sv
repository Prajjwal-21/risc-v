// =============================================================================
// axil_if  (UVM testbench, docs/architecture.md P7.2)
// -----------------------------------------------------------------------------
// Purpose : AXI4-Lite link (the DUT's CPU-side slave port, or its main-memory master port): one request and one response struct, as the RTL (axil_pkg, D-047).
// =============================================================================
// Signals here are driven and sampled through virtual interfaces from UVM class
// code, which Verilator's driver/usage analysis does not follow: UNDRIVEN and
// UNUSEDSIGNAL are false positives for this interface.
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */
interface axil_if (
  input logic clk,
  input logic rst_n
);
  axil_pkg::axil_req_t req;   // master -> slave
  axil_pkg::axil_rsp_t rsp;   // slave -> master
endinterface : axil_if
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
