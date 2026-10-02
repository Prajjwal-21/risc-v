// =============================================================================
// soc_top
// -----------------------------------------------------------------------------
// Purpose    : The SoC (CLAUDE.md 5.4, docs/architecture.md P5, P6): core, I-
//              and D-cache, mem_arbiter, axil_master, axil_interconnect, the
//              external main-memory port and the AXI4-Lite-to-APB bridge with
//              the CLINT, PLIC, UART and SPI master.
// Interfaces : clk_i, rst_ni (async assert, sync de-assert, synchronised
//              outside); m_axil_*: AXI4-Lite master port to main memory
//              (MEM_BASE..+MEM_SIZE); UART and SPI pins; simulation only:
//              rvfi_o, the core's retirement trace.
// Timing     : every block boundary follows the core port protocol or AXI4-Lite
//              / APB4; the interconnect and the bridge register every output.
//              The CLINT drives the software and timer interrupts and mtime
//              (the core's time CSR); the PLIC merges the UART and SPI
//              interrupts into the external interrupt.
// =============================================================================
module soc_top
  import riscv_pkg::*;
  import axil_pkg::*;
#(
  // 0: the caches are replaced by wires (CLAUDE.md 5.3), for debugging.
  parameter bit CACHE_EN = 1'b1
) (
  input  logic      clk_i,
  input  logic      rst_ni,

  // External main memory (AXI4-Lite master)
  output axil_req_t m_axil_req_o,
  input  axil_rsp_t m_axil_rsp_i,

  // UART
  output logic      uart_tx_o,
  input  logic      uart_rx_i,

  // SPI master
  output logic      spi_sclk_o,
  output logic      spi_mosi_o,
  input  logic      spi_miso_i,
  output logic      spi_cs_n_o
`ifndef SYNTHESIS
  ,
  output rvfi_t     rvfi_o
`endif
);

  // ---------------------------------------------------------------------------
  // Core
  // ---------------------------------------------------------------------------
  logic     core_ireq_valid, core_ireq_ready, core_irsp_valid;
  mem_req_t core_ireq;
  mem_rsp_t core_irsp;
  logic     core_dreq_valid, core_dreq_ready, core_drsp_valid;
  mem_req_t core_dreq;
  mem_rsp_t core_drsp;
  logic     irq_software, irq_timer, irq_external;
  logic [63:0] mtime;
  logic     fence_i;

  core_top u_core (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .imem_req_valid_o (core_ireq_valid),
    .imem_req_ready_i (core_ireq_ready),
    .imem_req_o       (core_ireq),
    .imem_rsp_valid_i (core_irsp_valid),
    .imem_rsp_i       (core_irsp),
    .dmem_req_valid_o (core_dreq_valid),
    .dmem_req_ready_i (core_dreq_ready),
    .dmem_req_o       (core_dreq),
    .dmem_rsp_valid_i (core_drsp_valid),
    .dmem_rsp_i       (core_drsp),
    .irq_software_i   (irq_software),
    .irq_timer_i      (irq_timer),
    .irq_external_i   (irq_external),
    .mtime_i          (mtime),
    .fence_i_o        (fence_i)
`ifndef SYNTHESIS
    ,
    .rvfi_o           (rvfi_o)
`endif
  );

  // ---------------------------------------------------------------------------
  // Caches (or wires with CACHE_EN = 0)
  // ---------------------------------------------------------------------------
  logic     ic_mreq_valid, ic_mreq_ready, ic_mrsp_valid;
  mem_req_t ic_mreq;
  mem_rsp_t ic_mrsp;
  logic     dc_mreq_valid, dc_mreq_ready, dc_mrsp_valid;
  mem_req_t dc_mreq;
  mem_rsp_t dc_mrsp;
  logic     dc_wb_idle;

  if (CACHE_EN) begin : g_cache
    icache u_icache (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .req_valid_i     (core_ireq_valid),
      .req_ready_o     (core_ireq_ready),
      .req_i           (core_ireq),
      .rsp_valid_o     (core_irsp_valid),
      .rsp_o           (core_irsp),
      .flush_i         (fence_i),
      .sync_ok_i       (dc_wb_idle),
      .mem_req_valid_o (ic_mreq_valid),
      .mem_req_ready_i (ic_mreq_ready),
      .mem_req_o       (ic_mreq),
      .mem_rsp_valid_i (ic_mrsp_valid),
      .mem_rsp_i       (ic_mrsp)
    );

    dcache u_dcache (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .req_valid_i     (core_dreq_valid),
      .req_ready_o     (core_dreq_ready),
      .req_i           (core_dreq),
      .rsp_valid_o     (core_drsp_valid),
      .rsp_o           (core_drsp),
      .wb_idle_o       (dc_wb_idle),
      .mem_req_valid_o (dc_mreq_valid),
      .mem_req_ready_i (dc_mreq_ready),
      .mem_req_o       (dc_mreq),
      .mem_rsp_valid_i (dc_mrsp_valid),
      .mem_rsp_i       (dc_mrsp)
    );
  end else begin : g_nocache
    assign ic_mreq_valid   = core_ireq_valid;
    assign core_ireq_ready = ic_mreq_ready;
    assign ic_mreq         = core_ireq;
    assign core_irsp_valid = ic_mrsp_valid;
    assign core_irsp       = ic_mrsp;
    assign dc_mreq_valid   = core_dreq_valid;
    assign core_dreq_ready = dc_mreq_ready;
    assign dc_mreq         = core_dreq;
    assign core_drsp_valid = dc_mrsp_valid;
    assign core_drsp       = dc_mrsp;
    assign dc_wb_idle      = 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Arbiter and AXI4-Lite master
  // ---------------------------------------------------------------------------
  logic     bus_req_valid, bus_req_ready, bus_req_instr, bus_rsp_valid;
  mem_req_t bus_req;
  mem_rsp_t bus_rsp;

  mem_arbiter u_arbiter (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .i_req_valid_i (ic_mreq_valid),
    .i_req_ready_o (ic_mreq_ready),
    .i_req_i       (ic_mreq),
    .i_rsp_valid_o (ic_mrsp_valid),
    .i_rsp_o       (ic_mrsp),
    .d_req_valid_i (dc_mreq_valid),
    .d_req_ready_o (dc_mreq_ready),
    .d_req_i       (dc_mreq),
    .d_rsp_valid_o (dc_mrsp_valid),
    .d_rsp_o       (dc_mrsp),
    .m_req_valid_o (bus_req_valid),
    .m_req_ready_i (bus_req_ready),
    .m_req_o       (bus_req),
    .m_instr_o     (bus_req_instr),
    .m_rsp_valid_i (bus_rsp_valid),
    .m_rsp_i       (bus_rsp)
  );

  axil_req_t cpu_axil_req;
  axil_rsp_t cpu_axil_rsp;

  axil_master u_axil_master (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .req_valid_i (bus_req_valid),
    .req_ready_o (bus_req_ready),
    .req_i       (bus_req),
    .instr_i     (bus_req_instr),
    .rsp_valid_o (bus_rsp_valid),
    .rsp_o       (bus_rsp),
    .axil_req_o  (cpu_axil_req),
    .axil_rsp_i  (cpu_axil_rsp)
  );

  // ---------------------------------------------------------------------------
  // System bus and peripherals (P5.1, P6): interconnect, main-memory port,
  // APB bridge, CLINT, PLIC, UART, SPI
  // ---------------------------------------------------------------------------
  periph_subsys u_periph (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .s_axil_req_i   (cpu_axil_req),
    .s_axil_rsp_o   (cpu_axil_rsp),
    .m_axil_req_o   (m_axil_req_o),
    .m_axil_rsp_i   (m_axil_rsp_i),
    .uart_tx_o      (uart_tx_o),
    .uart_rx_i      (uart_rx_i),
    .spi_sclk_o     (spi_sclk_o),
    .spi_mosi_o     (spi_mosi_o),
    .spi_miso_i     (spi_miso_i),
    .spi_cs_n_o     (spi_cs_n_o),
    .irq_software_o (irq_software),
    .irq_timer_o    (irq_timer),
    .irq_external_o (irq_external),
    .mtime_o        (mtime)
  );

endmodule : soc_top
