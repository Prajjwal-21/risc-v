// =============================================================================
// periph_subsys
// -----------------------------------------------------------------------------
// Purpose    : The SoC's system bus below the CPU's AXI4-Lite master
//              (docs/architecture.md P5.1, P6, P7.2): axil_interconnect with
//              the external main-memory port and the AXI4-Lite-to-APB bridge,
//              and the CLINT, PLIC, UART and SPI master on the APB bus. A
//              module of its own so the Phase 7 UVM environment drives exactly
//              the logic soc_top uses.
// Interfaces : s_axil_*: AXI4-Lite slave port (from axil_master); m_axil_*:
//              AXI4-Lite master port to main memory; UART and SPI pins; the
//              interrupt lines and mtime towards the core.
// Timing     : every output of the interconnect and the bridge is registered
//              (P5.1); the peripherals are zero-wait-state APB slaves (P6.1).
// =============================================================================
module periph_subsys
  import axil_pkg::*;
  import apb_pkg::*;
  import soc_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,

  input  axil_req_t   s_axil_req_i,
  output axil_rsp_t   s_axil_rsp_o,

  output axil_req_t   m_axil_req_o,
  input  axil_rsp_t   m_axil_rsp_i,

  output logic        uart_tx_o,
  input  logic        uart_rx_i,
  output logic        spi_sclk_o,
  output logic        spi_mosi_o,
  input  logic        spi_miso_i,
  output logic        spi_cs_n_o,

  output logic        irq_software_o,
  output logic        irq_timer_o,
  output logic        irq_external_o,
  output logic [63:0] mtime_o
);

  // ---------------------------------------------------------------------------
  // Interconnect: s0 = external memory port, s1 = APB bridge
  // ---------------------------------------------------------------------------
  axil_req_t [AXI_NSLV-1:0] slv_axil_req;
  axil_rsp_t [AXI_NSLV-1:0] slv_axil_rsp;

  axil_interconnect #(
    .NSLV      (AXI_NSLV),
    .NRULES    (BUS_NRULES),
    .RULE_BASE (BUS_RULE_BASE),
    .RULE_SIZE (BUS_RULE_SIZE),
    .RULE_PORT (BUS_RULE_PORT)
  ) u_interconnect (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .s_req_i (s_axil_req_i),
    .s_rsp_o (s_axil_rsp_o),
    .m_req_o (slv_axil_req),
    .m_rsp_i (slv_axil_rsp)
  );

  assign m_axil_req_o              = slv_axil_req[AXI_SLV_MEM];
  assign slv_axil_rsp[AXI_SLV_MEM] = m_axil_rsp_i;

  // ---------------------------------------------------------------------------
  // APB bridge and peripherals
  // ---------------------------------------------------------------------------
  apb_req_t [APB_NSLV-1:0] apb_req;
  apb_rsp_t [APB_NSLV-1:0] apb_rsp;

  axil2apb #(
    .NSLV     (APB_NSLV),
    .SLV_BASE (APB_BASE),
    .SLV_SIZE (APB_SIZE)
  ) u_apb_bridge (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .s_req_i   (slv_axil_req[AXI_SLV_APB]),
    .s_rsp_o   (slv_axil_rsp[AXI_SLV_APB]),
    .apb_req_o (apb_req),
    .apb_rsp_i (apb_rsp)
  );

  // ---------------------------------------------------------------------------
  // Peripherals (docs/architecture.md P6)
  // ---------------------------------------------------------------------------
  logic uart_irq, spi_irq;

  clint u_clint (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .apb_req_i      (apb_req[APB_SLV_CLINT]),
    .apb_rsp_o      (apb_rsp[APB_SLV_CLINT]),
    .irq_software_o (irq_software_o),
    .irq_timer_o    (irq_timer_o),
    .mtime_o        (mtime_o)
  );

  plic u_plic (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .apb_req_i (apb_req[APB_SLV_PLIC]),
    .apb_rsp_o (apb_rsp[APB_SLV_PLIC]),
    .src_i     ({spi_irq, uart_irq, 1'b0}),      // IDs 2, 1; ID 0 is "none"
    .irq_o     (irq_external_o)
  );

  uart u_uart (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .apb_req_i (apb_req[APB_SLV_UART]),
    .apb_rsp_o (apb_rsp[APB_SLV_UART]),
    .tx_o      (uart_tx_o),
    .rx_i      (uart_rx_i),
    .irq_o     (uart_irq)
  );

  spi_master u_spi (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .apb_req_i (apb_req[APB_SLV_SPI]),
    .apb_rsp_o (apb_rsp[APB_SLV_SPI]),
    .sclk_o    (spi_sclk_o),
    .mosi_o    (spi_mosi_o),
    .cs_n_o    (spi_cs_n_o),
    .miso_i    (spi_miso_i),
    .irq_o     (spi_irq)
  );

endmodule : periph_subsys
