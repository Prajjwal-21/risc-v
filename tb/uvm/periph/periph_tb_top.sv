// =============================================================================
// periph_tb_top - UVM testbench top for periph_subsys (docs/architecture.md P7.2)
// -----------------------------------------------------------------------------
// DUT: periph_subsys (interconnect, main-memory port, APB bridge, CLINT, PLIC,
// UART, SPI). The CPU-side port is driven by the UVM AXI4-Lite agent; the
// memory port is answered by axil_mem_model (+mem=ideal|random, +seed=N).
// The APB slots are observed through apb_if (hierarchical taps, passive).
// Run: +UVM_TESTNAME=<test> [+verilator+seed+N] [+uvm_cov_json=<file>]
// =============================================================================
module periph_tb_top;
  import uvm_pkg::*;
  import periph_uvm_pkg::*;

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

  axil_if  cpu_if  (.clk(clk), .rst_n(rst_n));
  axil_if  mem_if  (.clk(clk), .rst_n(rst_n));
  apb_if   apb0_if (.clk(clk), .rst_n(rst_n));
  apb_if   apb1_if (.clk(clk), .rst_n(rst_n));
  apb_if   apb2_if (.clk(clk), .rst_n(rst_n));
  apb_if   apb3_if (.clk(clk), .rst_n(rst_n));
  uart_if  uart_vif(.clk(clk), .rst_n(rst_n));
  spi_if   spi_vif (.clk(clk), .rst_n(rst_n));
  irq_if   irq_vif (.clk(clk), .rst_n(rst_n));

  periph_subsys dut (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .s_axil_req_i   (cpu_if.req),
    .s_axil_rsp_o   (cpu_if.rsp),
    .m_axil_req_o   (mem_if.req),
    .m_axil_rsp_i   (mem_if.rsp),
    .uart_tx_o      (uart_vif.tx),
    .uart_rx_i      (uart_vif.rx),
    .spi_sclk_o     (spi_vif.sclk),
    .spi_mosi_o     (spi_vif.mosi),
    .spi_miso_i     (spi_vif.miso),
    .spi_cs_n_o     (spi_vif.cs_n),
    .irq_software_o (irq_vif.sw),
    .irq_timer_o    (irq_vif.timer),
    .irq_external_o (irq_vif.ext),
    .mtime_o        (irq_vif.mtime)
  );

  axil_mem_model u_mem (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .req_i  (mem_if.req),
    .rsp_o  (mem_if.rsp)
  );

  assign apb0_if.req = dut.apb_req[0];
  assign apb0_if.rsp = dut.apb_rsp[0];
  assign apb1_if.req = dut.apb_req[1];
  assign apb1_if.rsp = dut.apb_rsp[1];
  assign apb2_if.req = dut.apb_req[2];
  assign apb2_if.rsp = dut.apb_rsp[2];
  assign apb3_if.req = dut.apb_req[3];
  assign apb3_if.rsp = dut.apb_rsp[3];

  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.env.cpu.*", "vif", cpu_if);
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.env.mem_mon", "vif", mem_if);
    uvm_config_db#(virtual apb_if)::set(null, "uvm_test_top.env.apb_mon0", "vif", apb0_if);
    uvm_config_db#(virtual apb_if)::set(null, "uvm_test_top.env.apb_mon1", "vif", apb1_if);
    uvm_config_db#(virtual apb_if)::set(null, "uvm_test_top.env.apb_mon2", "vif", apb2_if);
    uvm_config_db#(virtual apb_if)::set(null, "uvm_test_top.env.apb_mon3", "vif", apb3_if);
    uvm_config_db#(virtual uart_if)::set(null, "uvm_test_top.env.uart.*", "vif", uart_vif);
    uvm_config_db#(virtual spi_if)::set(null, "uvm_test_top.env.spi", "vif", spi_vif);
    uvm_config_db#(virtual irq_if)::set(null, "uvm_test_top", "irq_vif", irq_vif);
    run_test();
  end
endmodule : periph_tb_top
