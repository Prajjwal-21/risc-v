# =============================================================================
# Timing constraints for soc_top (docs/architecture.md P8.3, D-051)
# -----------------------------------------------------------------------------
# One clock, clk_i. Every value below is derived from ::env(CLOCK_PERIOD) and
# the flow's own constraint variables, so the same file serves:
#   - LibreLane placement, CTS, routing and sign-off (PNR_SDC_FILE,
#     SIGNOFF_SDC_FILE in config.json);
#   - `scripts/pnr.py fmax`, which re-reads it at trial periods on the
#     signed-off netlist to measure Fmax.
# It follows LibreLane's generic SDC: I/O delays of IO_DELAY_CONSTRAINT % of
# the period on every port but the clock (the reset included: rst_ni is
# deasserted synchronously by the system, CLAUDE.md section 4), the standard
# driving cell and output load, clock uncertainty and transition, and a
# derate of TIME_DERATING_CONSTRAINT % on early and late paths.
# =============================================================================

set period $::env(CLOCK_PERIOD)
create_clock [get_ports clk_i] -name clk_i -period $period
set clk [get_clocks clk_i]

set io_delay [expr {$period * $::env(IO_DELAY_CONSTRAINT) / 100.0}]
set inputs [lsearch -inline -all -not -exact [all_inputs] [get_ports clk_i]]
set_input_delay  $io_delay -clock $clk $inputs
set_output_delay $io_delay -clock $clk [all_outputs]

set drv [split $::env(SYNTH_DRIVING_CELL) "/"]
set_driving_cell -lib_cell [lindex $drv 0] -pin [lindex $drv 1] $inputs
set clk_drv [split [expr {[info exists ::env(SYNTH_CLK_DRIVING_CELL)] ?
                          $::env(SYNTH_CLK_DRIVING_CELL) : $::env(SYNTH_DRIVING_CELL)}] "/"]
set_driving_cell -lib_cell [lindex $clk_drv 0] -pin [lindex $clk_drv 1] [get_ports clk_i]
set_load [expr {$::env(OUTPUT_CAP_LOAD) / 1000.0}] [all_outputs]

set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
if {[info exists ::env(MAX_TRANSITION_CONSTRAINT)]} {
    set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
}
if {[info exists ::env(MAX_CAPACITANCE_CONSTRAINT)]} {
    set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT) [current_design]
}

set_clock_uncertainty $::env(CLOCK_UNCERTAINTY_CONSTRAINT) $clk
set_clock_transition  $::env(CLOCK_TRANSITION_CONSTRAINT) $clk
set_timing_derate -early [expr {1.0 - $::env(TIME_DERATING_CONSTRAINT) / 100.0}]
set_timing_derate -late  [expr {1.0 + $::env(TIME_DERATING_CONSTRAINT) / 100.0}]

# Ideal clock before CTS, propagated after (as LibreLane's generic SDC).
if {[info exists ::env(OPENLANE_SDC_IDEAL_CLOCKS)] && $::env(OPENLANE_SDC_IDEAL_CLOCKS)} {
    unset_propagated_clock [all_clocks]
} else {
    set_propagated_clock [all_clocks]
}
