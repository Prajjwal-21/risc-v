// =============================================================================
// lockstep  (testbench only)
// -----------------------------------------------------------------------------
// Purpose    : Lockstep co-simulation with Spike over DPI (docs/architecture.md
//              P7.1). With +lockstep, every retirement record of the core
//              (rvfi_i) steps Spike once (tb/common/lockstep.cpp) and is
//              compared; interrupts the core took are injected into Spike,
//              MMIO loads are answered with the value the core received.
// Interfaces : rvfi_i, the core's rvfi_o. The testbench reads `on`, `done`
//              (the tohost store's record was compared) and `err` (the first
//              mismatch, "" if none) hierarchically, and stat(i) for STATS.
// Plusargs   : +lockstep, +hex=<file> (Spike's memory image, the same file as
//              the testbench memory), +tohost=<hex>.
// =============================================================================
module lockstep
  import riscv_pkg::*;
(
  input logic  clk_i,
  input logic  rst_ni,
  input rvfi_t rvfi_i
);

  import "DPI-C" function int lockstep_init(input string hexfile, input int mem_base, input int mem_size);
  import "DPI-C" function int lockstep_step(input bit [19*32-1:0] rec);
  import "DPI-C" function string lockstep_error();
  import "DPI-C" function longint lockstep_stat(input int which);

  bit    on, done;
  string err;
  word_t tohost;

  initial begin
    string hex;
    on   = $test$plusargs("lockstep");
    done = 1'b0;
    err  = "";
    void'($value$plusargs("tohost=%h", tohost));
    if (on) begin
      if (!$value$plusargs("hex=%s", hex)) $fatal(1, "[lockstep] +lockstep needs +hex=<file>");
      if (lockstep_init(hex, int'(soc_pkg::MEM_BASE), int'(soc_pkg::MEM_SIZE)) != 0)
        $fatal(1, "[lockstep] cannot load %s into Spike's memory", hex);
    end
  end

  // Order of the words: see rec_t in lockstep.cpp (word 0 = insn). The valid
  // bit and the order number are not sent.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic bit [19*32-1:0] pack(rvfi_t r);
    return {32'(r.intr_epc), 32'(r.intr_cause), 32'(r.intr), 32'(r.trap_tval),
            32'(r.trap_cause), 32'(r.trap), 32'(r.csr_wdata), 32'(r.csr_addr), 32'(r.csr_we),
            32'(r.mem_rdata), 32'(r.mem_wdata), 32'(r.mem_wmask), 32'(r.mem_rmask),
            32'(r.mem_addr), 32'(r.rd_wdata), 32'(r.rd_addr), 32'(r.pc_wdata),
            32'(r.pc_rdata), 32'(r.insn)};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic longint stat(int which);
    return on ? lockstep_stat(which) : 0;
  endfunction

  always @(posedge clk_i) begin
    if (rst_ni && on && rvfi_i.valid && !done && err == "") begin
      if (lockstep_step(pack(rvfi_i)) != 0)
        err <= $sformatf("lockstep: record %0d: %s", rvfi_i.order, lockstep_error());
      // The tohost store ends the comparison (as the trace, P3.2).
      if (rvfi_i.mem_wmask != '0 && rvfi_i.mem_addr == tohost) done <= 1'b1;
    end
  end

endmodule : lockstep
