// =============================================================================
// rvfi_writer  (testbench only)
// -----------------------------------------------------------------------------
// Purpose    : Writes the core's retirement trace (docs/architecture.md P3.2)
//              to +rvfi=<file>: one I (retired) or E (exception) line per
//              record, and a Q line after an I line that took an interrupt.
//              The trace ends with the record of the first store to tohost
//              (+tohost=<hex>); co-simulation compares up to it. Shared by the
//              core and SoC testbenches.
// Interfaces : rvfi_i, the core's rvfi_o. The testbench reads `on` (a trace
//              was requested), `done` (the tohost record is written) and `err`
//              (the first consistency error, "" if none) hierarchically.
// Checks     : order increases by one; each record's pc is the previous
//              record's pc_wdata; no interrupt when +irq is off or absent.
// =============================================================================
module rvfi_writer
  import riscv_pkg::*;
(
  input logic  clk_i,
  input logic  rst_ni,
  // mem_rdata is for lockstep co-simulation; the text trace does not show it.
  /* verilator lint_off UNUSEDSIGNAL */
  input rvfi_t rvfi_i
  /* verilator lint_on UNUSEDSIGNAL */
);

  int          fd;
  bit          on, irq_off, done;
  word_t       tohost;
  logic [63:0] expect_order;
  word_t       expect_pc;
  bit          have_pc;
  string       err;

  initial begin
    string path, irq_mode;
    on      = $value$plusargs("rvfi=%s", path);
    irq_off = !$value$plusargs("irq=%s", irq_mode) || (irq_mode == "off");
    void'($value$plusargs("tohost=%h", tohost));
    done = 1'b0;
    err  = "";
    expect_order = '0;
    have_pc = 1'b0;
    if (on) begin
      fd = $fopen(path, "w");
      if (fd == 0) $fatal(1, "[rvfi_writer] cannot open +rvfi file %s", path);
    end
  end

  // Store data as written: the bytes selected by the mask, shifted to bit 0.
  function automatic word_t store_bytes(word_t wdata, logic [3:0] mask);
    unique case (mask)
      4'b0001: return {24'b0, wdata[7:0]};
      4'b0010: return {24'b0, wdata[15:8]};
      4'b0100: return {24'b0, wdata[23:16]};
      4'b1000: return {24'b0, wdata[31:24]};
      4'b0011: return {16'b0, wdata[15:0]};
      4'b1100: return {16'b0, wdata[31:16]};
      default: return wdata;
    endcase
  endfunction

  always @(posedge clk_i) begin
    if (rst_ni && on && rvfi_i.valid && !done) begin
      string line;
      // Consistency: order counts records, each record's pc is the previous
      // record's pc_wdata, and no interrupt is taken with +irq=off.
      if (err == "") begin
        if (rvfi_i.order != expect_order)
          err <= $sformatf("rvfi order %0d, expected %0d", rvfi_i.order, expect_order);
        else if (have_pc && rvfi_i.pc_rdata != expect_pc)
          err <= $sformatf("rvfi pc %08h, previous pc_wdata %08h", rvfi_i.pc_rdata, expect_pc);
        else if (rvfi_i.intr && irq_off)
          err <= $sformatf("interrupt taken with +irq=off at pc=%08h", rvfi_i.pc_rdata);
      end
      expect_order <= expect_order + 1;
      expect_pc    <= rvfi_i.pc_wdata;
      have_pc      <= 1'b1;
      if (rvfi_i.trap) begin
        line = $sformatf("E %0d %08h %08h cause=%0d tval=%08h", rvfi_i.order, rvfi_i.pc_rdata,
                         rvfi_i.insn, rvfi_i.trap_cause, rvfi_i.trap_tval);
      end else begin
        line = $sformatf("I %0d %08h %08h", rvfi_i.order, rvfi_i.pc_rdata, rvfi_i.insn);
        if (rvfi_i.rd_addr != '0)
          line = {line, $sformatf(" x%0d=%08h", rvfi_i.rd_addr, rvfi_i.rd_wdata)};
        if (rvfi_i.mem_rmask != '0)
          line = {line, $sformatf(" ld %08h %b", rvfi_i.mem_addr, rvfi_i.mem_rmask)};
        if (rvfi_i.mem_wmask != '0)
          line = {line, $sformatf(" st %08h %b %08h", rvfi_i.mem_addr, rvfi_i.mem_wmask,
                                  store_bytes(rvfi_i.mem_wdata, rvfi_i.mem_wmask))};
        if (rvfi_i.csr_we)
          line = {line, $sformatf(" csr %03h=%08h", rvfi_i.csr_addr, rvfi_i.csr_wdata)};
      end
      $fdisplay(fd, "%s", line);
      if (rvfi_i.intr)
        $fdisplay(fd, "Q cause=%0d epc=%08h", rvfi_i.intr_cause, rvfi_i.intr_epc);
      // The first store to tohost ends the trace.
      if (rvfi_i.mem_wmask != '0 && rvfi_i.mem_addr == tohost) begin
        done <= 1'b1;
        $fclose(fd);
      end
    end
  end

endmodule : rvfi_writer
