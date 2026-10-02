// =============================================================================
// soc_tb_top  (testbench only)
// -----------------------------------------------------------------------------
// Purpose    : Verilator testbench for the full SoC (docs/architecture.md
//              P5.5, P6.6): soc_top + axil_mem_model on the external AXI4-Lite
//              port, UART loopback with a monitor, an SPI slave model,
//              tohost_monitor on the core's D-port, the retirement trace, the
//              AXI4-Lite and APB protocol checkers on every link, counters, a
//              timeout.
// Plusargs   : +hex=<file> +tohost=<hex> [+mem=ideal|random] [+seed=N]
//              [+timeout=<cycles>, default 200000] [+rvfi=<file>]
//              [+irq_count=<hex>] [+wave=<file.fst> [+wave_from=N] [+wave_to=N]]
//              [+uart_log] (print the text the UART transmits)
//              (+irq=on is rejected: the SoC has no sim_ctrl, D-029.)
// Output     : "RESULT: PASS" or "RESULT: FAIL <reason>", and
//              "STATS: key=value ..." (the keys of core_tb_top that apply,
//              plus the cache counters and bus transfer counts).
// Checks     : protocol checkers (stop on violation); interrupt entries ==
//              irq_handled at the end (when +irq_count is given).
// Timing     : 100 MHz clock; reset for 5 cycles, released on a falling edge.
// =============================================================================
module soc_tb_top #(
  parameter bit CACHE_EN = 1'b1
);

  import riscv_pkg::*;
  import axil_pkg::*;
  import soc_pkg::*;

  logic clk;
  logic rst_n;

  initial begin
    clk = 1'b0;
    forever #5ns clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
  end

  initial begin
    string irq_mode;
    if ($value$plusargs("irq=%s", irq_mode) && irq_mode != "off")
      $fatal(1, "[soc_tb] +irq=%s: the SoC has no sim_ctrl (D-029)", irq_mode);
  end

  // ---------------------------------------------------------------------------
  // DUT and external memory
  // ---------------------------------------------------------------------------
  axil_req_t mem_req;
  axil_rsp_t mem_rsp;
  rvfi_t     rvfi;
  logic      uart_tx, spi_sclk, spi_mosi, spi_miso, spi_cs_n;

  soc_top #(
    .CACHE_EN (CACHE_EN)
  ) u_soc (
    .clk_i        (clk),
    .rst_ni       (rst_n),
    .m_axil_req_o (mem_req),
    .m_axil_rsp_i (mem_rsp),
    .uart_tx_o    (uart_tx),
    .uart_rx_i    (uart_tx),          // loopback (P6.6)
    .spi_sclk_o   (spi_sclk),
    .spi_mosi_o   (spi_mosi),
    .spi_miso_i   (spi_miso),
    .spi_cs_n_o   (spi_cs_n),
    .rvfi_o       (rvfi)
  );

  axil_mem_model u_mem (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .req_i  (mem_req),
    .rsp_o  (mem_rsp)
  );

  // ---------------------------------------------------------------------------
  // Peripheral models (P6.6): the SPI slave takes its mode from the DUT's
  // CTRL register, as a real slave would be configured; the UART monitor
  // decodes TX at the DUT's BAUDDIV (+uart_log prints the text).
  // ---------------------------------------------------------------------------
  spi_slave_model u_spi_slave (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .sclk_i (spi_sclk),
    .mosi_i (spi_mosi),
    .cs_n_i (spi_cs_n),
    .miso_o (spi_miso),
    .cpol_i (u_soc.u_periph.u_spi.cpol),
    .cpha_i (u_soc.u_periph.u_spi.cpha),
    .lsb_i  (u_soc.u_periph.u_spi.lsb)
  );

  uart_monitor u_uart_mon (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .line_i (uart_tx),
    .div_i  (u_soc.u_periph.u_uart.div)
  );

  // ---------------------------------------------------------------------------
  // Protocol checkers on every AXI4-Lite link and APB slot (P5.5)
  // ---------------------------------------------------------------------------
  axil_checker #(.NAME("cpu->interconnect")) u_chk_cpu (
    .clk_i (clk), .rst_ni (rst_n), .req_i (u_soc.cpu_axil_req), .rsp_i (u_soc.cpu_axil_rsp));
  axil_checker #(.NAME("interconnect->mem")) u_chk_mem (
    .clk_i (clk), .rst_ni (rst_n), .req_i (mem_req), .rsp_i (mem_rsp));
  axil_checker #(.NAME("interconnect->apb")) u_chk_apb_bridge (
    .clk_i (clk), .rst_ni (rst_n), .req_i (u_soc.u_periph.slv_axil_req[AXI_SLV_APB]),
    .rsp_i (u_soc.u_periph.slv_axil_rsp[AXI_SLV_APB]));

  for (genvar i = 0; i < int'(APB_NSLV); i++) begin : g_apb_chk
    apb_checker #(.NAME($sformatf("apb%0d", i))) u_chk (
      .clk_i (clk), .rst_ni (rst_n), .req_i (u_soc.u_periph.apb_req[i]), .rsp_i (u_soc.u_periph.apb_rsp[i]));
  end

  // ---------------------------------------------------------------------------
  // Pass/fail, trace, waveforms
  // ---------------------------------------------------------------------------
  logic  done, pass;
  word_t testnum;

  tohost_monitor u_tohost (
    .clk_i            (clk),
    .rst_ni           (rst_n),
    .dmem_req_valid_i (u_soc.core_dreq_valid),
    .dmem_req_ready_i (u_soc.core_dreq_ready),
    .dmem_req_i       (u_soc.core_dreq),
    .done_o           (done),
    .pass_o           (pass),
    .testnum_o        (testnum)
  );

  rvfi_writer u_rvfi (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .rvfi_i (rvfi)
  );

  // Lockstep co-simulation with Spike (+lockstep, P7.1)
  lockstep u_lock (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .rvfi_i (rvfi)
  );

  longint unsigned cycles, retired, n_irq, n_exc;

  wave_ctl u_wave (
    .clk_i   (clk),
    .cycle_i (cycles)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cycles  <= 0;
      retired <= 0;
      n_irq   <= 0;
      n_exc   <= 0;
    end else begin
      cycles <= cycles + 1;
      if (u_soc.u_core.retire)    retired <= retired + 1;
      if (u_soc.u_core.irq_take)  n_irq   <= n_irq + 1;
      if (u_soc.u_core.trap_take) n_exc   <= n_exc + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // Cache counters and write-buffer drain (as core_tb_top, P4.5)
  // ---------------------------------------------------------------------------
  longint unsigned cstat [8];
  logic            dc_drained;

  if (CACHE_EN) begin : g_cache
    longint unsigned wb_pushes, wb_writes, wb_target;
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        cstat     <= '{default: 0};
        wb_pushes <= 0;
        wb_writes <= 0;
        wb_target <= '1;
      end else begin
        cstat[0] <= cstat[0] + longint'(u_soc.g_cache.u_icache.ev_hit);
        cstat[1] <= cstat[1] + longint'(u_soc.g_cache.u_icache.ev_miss);
        cstat[2] <= cstat[2] + longint'(u_soc.g_cache.u_dcache.ev_ld_hit);
        cstat[3] <= cstat[3] + longint'(u_soc.g_cache.u_dcache.ev_ld_miss);
        cstat[4] <= cstat[4] + longint'(u_soc.g_cache.u_dcache.ev_st_hit);
        cstat[5] <= cstat[5] + longint'(u_soc.g_cache.u_dcache.ev_st_miss);
        cstat[6] <= cstat[6] + longint'(u_soc.g_cache.u_dcache.ev_unc);
        cstat[7] <= cstat[7] + longint'(u_soc.g_cache.u_dcache.ev_wb_full);
        wb_pushes <= wb_pushes + longint'(u_soc.g_cache.u_dcache.wb_push);
        wb_writes <= wb_writes + longint'(u_soc.g_cache.u_dcache.wb_rsp_valid);
        if (done && wb_target == '1) wb_target <= wb_pushes + 1;
      end
    end
    assign dc_drained = (wb_target != '1) && (wb_writes >= wb_target);
  end else begin : g_nocache
    assign dc_drained = 1'b1;
    always_ff @(posedge clk) cstat <= '{default: 0};
  end

  // ---------------------------------------------------------------------------
  // End of test
  // ---------------------------------------------------------------------------
  longint unsigned timeout, done_cycles;
  word_t           irq_count_addr;
  bit              has_irq_count;

  initial begin
    timeout = 200000;
    void'($value$plusargs("timeout=%d", timeout));
    has_irq_count = $value$plusargs("irq_count=%h", irq_count_addr);
  end

  always_ff @(posedge clk) begin
    if (!rst_n || !done) done_cycles <= 0;
    else                 done_cycles <= done_cycles + 1;
  end

  // Lockstep counters (records compared, interrupts injected, MMIO loads and
  // stores answered, values injected), when +lockstep is on.
  function automatic string lockstep_stats();
    if (!u_lock.on) return "";
    return $sformatf(" ls_records=%0d ls_irq=%0d ls_mmio_ld=%0d ls_mmio_st=%0d ls_inject=%0d",
                     u_lock.stat(0), u_lock.stat(1), u_lock.stat(2), u_lock.stat(3), u_lock.stat(4));
  endfunction

  task automatic finish(string result);
    $display("RESULT: %s", result);
    $display("STATS: cycles=%0d retired=%0d exc=%0d irq=%0d axi_rd=%0d axi_wr=%0d apb_xfer=%0d uart_bytes=%0d spi_frames=%0d%s",
             cycles, retired, n_exc, n_irq, u_chk_mem.n_rd, u_chk_mem.n_wr,
             g_apb_chk[0].u_chk.n_xfer + g_apb_chk[1].u_chk.n_xfer
               + g_apb_chk[2].u_chk.n_xfer + g_apb_chk[3].u_chk.n_xfer,
             u_uart_mon.n_bytes, u_spi_slave.n_frames,
             {CACHE_EN ? $sformatf(" ic_hit=%0d ic_miss=%0d dc_ld_hit=%0d dc_ld_miss=%0d dc_st_hit=%0d dc_st_miss=%0d dc_unc=%0d dc_wb_full=%0d",
                                   cstat[0], cstat[1], cstat[2], cstat[3], cstat[4], cstat[5],
                                   cstat[6], cstat[7]) : "",
              lockstep_stats()});
    $finish;
  endtask

  // Interrupt entries == the software handler's count (P2.9 check 1, without
  // sim_ctrl: Phase 6 interrupts are acknowledged at the CLINT/PLIC).
  function automatic string irq_checks();
    if (has_irq_count) begin
      word_t           off;
      longint unsigned handled;
      off     = irq_count_addr - MEM_BASE;
      handled = 64'({u_mem.mem[off + 3], u_mem.mem[off + 2], u_mem.mem[off + 1], u_mem.mem[off]});
      if (handled != n_irq)
        return $sformatf("irq_handled %0d != interrupt entries %0d", handled, n_irq);
    end
    return "";
  endfunction

  always @(posedge clk) begin
    if (rst_n) begin
      if (done && u_rvfi.on && !u_rvfi.done && done_cycles > 64) begin
        finish("FAIL trace: no record of the tohost store within 64 cycles");
      end else if (done && !dc_drained && done_cycles > 1024) begin
        finish("FAIL the D-cache write buffer did not drain within 1024 cycles of the tohost store");
      end else if (u_lock.err != "") begin
        finish({"FAIL ", u_lock.err});
      end else if (done && u_lock.on && !u_lock.done && done_cycles > 64) begin
        finish("FAIL lockstep: no record of the tohost store within 64 cycles");
      end else if (done && dc_drained && (!u_rvfi.on || u_rvfi.done) && (!u_lock.on || u_lock.done)) begin
        string chk;
        chk = irq_checks();
        if (u_rvfi.err != "") finish({"FAIL ", u_rvfi.err});
        else if (!pass)       finish($sformatf("FAIL test=%0d", testnum));
        else if (chk != "")   finish({"FAIL ", chk});
        else                  finish("PASS");
      end else if (cycles >= timeout) begin
        finish($sformatf("FAIL timeout after %0d cycles", cycles));
      end
    end
  end

endmodule : soc_tb_top
