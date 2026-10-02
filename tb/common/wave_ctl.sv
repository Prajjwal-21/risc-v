// =============================================================================
// wave_ctl  (testbench only)
// -----------------------------------------------------------------------------
// Purpose    : Waveform dumping switched per run and per time window with
//              plusargs (CLAUDE.md section 7, rule 10; D-044), and the file the
//              functional coverage counters go to (P7.3):
//                +cov=<file.dat>    write the coverage counters there at the end
//                                   (default: /dev/null, nothing is kept)
//                +wave=<file.fst>   dump every signal of the model to <file>
//                +wave_from=<N>     start at clock cycle N (default 0)
//                +wave_to=<N>       stop after clock cycle N (default: the end
//                                   of the run)
//              Without +wave nothing is dumped and the run is unaffected.
// Interfaces : cycle_i, the testbench's cycle counter (0 at the end of reset).
// Timing     : Verilator ignores $dumpoff, so the window is implemented by
//              opening the dump late ($dumpvars at cycle N) and closing it
//              through tb_wave_close() (tb/common/wave_ctl.cpp), which closes
//              the file the model opened for $dumpvars.
// =============================================================================
module wave_ctl (
  input logic            clk_i,
  input longint unsigned cycle_i
);

  import "DPI-C" context function void tb_wave_close();
  import "DPI-C" function void tb_coverage_file(input string name);

  initial begin
    string cov;
    if (!$value$plusargs("cov=%s", cov)) cov = "/dev/null";
    tb_coverage_file(cov);
  end

  initial begin
    string           file;
    longint unsigned from, to;
    from = 0;
    to   = '1;
    if ($value$plusargs("wave=%s", file)) begin
      void'($value$plusargs("wave_from=%d", from));
      void'($value$plusargs("wave_to=%d", to));
      if (to < from) $fatal(1, "[wave_ctl] +wave_to=%0d is before +wave_from=%0d", to, from);
      $display("[wave_ctl] dumping to %s, cycles %0d..%0s", file, from,
               (to == '1) ? "end" : $sformatf("%0d", to));
      while (cycle_i < from) @(posedge clk_i);
      $dumpfile(file);
      $dumpvars;
      if (to != '1) begin
        while (cycle_i <= to) @(posedge clk_i);
        tb_wave_close();
        $display("[wave_ctl] dump closed after cycle %0d", to);
      end
    end
  end

endmodule : wave_ctl
