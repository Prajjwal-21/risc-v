// =============================================================================
// periph_uvm_pkg - UVM environment for periph_subsys (docs/architecture.md P7.2)
// -----------------------------------------------------------------------------
// UVM convention: one package holds the agents, register model, scoreboards,
// coverage, environment and tests (the .svh files below), so class names
// cannot match the file names. Class members are written and read through
// object handles, which Verilator's driver/usage analysis does not follow:
// UNDRIVEN and UNUSEDSIGNAL on class members are false positives here.
// =============================================================================
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */
package periph_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "axil_agent.svh"
  `include "periph_agents.svh"
  `include "periph_ral.svh"
  `include "periph_checks.svh"
  `include "periph_env.svh"
  `include "periph_tests.svh"
endpackage : periph_uvm_pkg
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on DECLFILENAME */
