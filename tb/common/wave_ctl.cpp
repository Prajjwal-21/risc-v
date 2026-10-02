// =============================================================================
// wave_ctl.cpp - DPI helpers for tb/common/wave_ctl.sv (testbench only)
// -----------------------------------------------------------------------------
// tb_coverage_file(): the models are built with --coverage-user (P7.3) and
// write their coverage counters when the run ends; this sets the file (the
// testbench passes +cov=<file>, or /dev/null so that no run leaves a
// coverage.dat in the working directory).
//
// Verilator (5.052) ignores $dumpoff, so the end of a +wave_to window closes
// the dump file instead. The file was opened by the model's own $dumpvars
// handling; the model's symbol table (<prefix>__Syms) owns it and closes it in
// _traceDumpClose(). Every testbench model is built with --prefix Vtb (Makefile,
// D-044), so the symbol table class is Vtb__Syms.
// =============================================================================
#include "svdpi.h"
#include "verilated.h"
#include "verilated_syms.h"
#include "Vtb__Syms.h"

extern "C" void tb_wave_close() {
    const VerilatedScope* scope = static_cast<const VerilatedScope*>(svGetScope());
    static_cast<Vtb__Syms*>(scope->symsp())->_traceDumpClose();
}

extern "C" void tb_coverage_file(const char* name) {
    Verilated::threadContextp()->coverageFilename(name);
}
