// =============================================================================
// periph_env.svh - UVM environment for periph_subsys (docs/architecture.md P7.2)
// -----------------------------------------------------------------------------
// cpu      active AXI4-Lite master agent on the DUT's CPU-side port
// mem_mon  AXI4-Lite monitor on the DUT's main-memory port (axil_mem_model
//          answers there, in the testbench top)
// apb_mon  one passive APB monitor per peripheral slot
// uart     UART agent (drives RX, decodes TX); spi: SPI slave device
// bus_sb, uart_sb, spi_sb, cov: scoreboards and coverage (periph_checks.svh)
// regmodel the register model, predicted from the CPU-port monitor
// uart_c, spi_c: shared configuration objects the tests change
// =============================================================================
class periph_env extends uvm_env;
  `uvm_component_utils(periph_env)

  axil_agent       cpu;
  axil_monitor     mem_mon;
  apb_monitor      apb_mon[4];
  uart_agent       uart;
  spi_slave        spi;
  bus_scoreboard   bus_sb;
  uart_scoreboard  uart_sb;
  spi_scoreboard   spi_sb;
  periph_cov       cov;

  soc_reg_block                    regmodel;
  axil_adapter                     adapter;
  uvm_reg_predictor #(axil_item)   predictor;

  uart_cfg uart_c;
  spi_cfg  spi_c;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uart_c = uart_cfg::type_id::create("uart_c");
    spi_c  = spi_cfg::type_id::create("spi_c");
    uvm_config_db#(uart_cfg)::set(this, "uart.*", "cfg", uart_c);
    uvm_config_db#(spi_cfg)::set(this, "spi", "cfg", spi_c);

    cpu     = axil_agent::type_id::create("cpu", this);
    mem_mon = axil_monitor::type_id::create("mem_mon", this);
    for (int i = 0; i < 4; i++) begin
      apb_mon[i] = apb_monitor::type_id::create($sformatf("apb_mon%0d", i), this);
      uvm_config_db#(int)::set(this, $sformatf("apb_mon%0d", i), "slot", i);
    end
    uart    = uart_agent::type_id::create("uart", this);
    spi     = spi_slave::type_id::create("spi", this);
    bus_sb  = bus_scoreboard::type_id::create("bus_sb", this);
    uart_sb = uart_scoreboard::type_id::create("uart_sb", this);
    spi_sb  = spi_scoreboard::type_id::create("spi_sb", this);
    cov     = periph_cov::type_id::create("cov", this);

    regmodel = soc_reg_block::type_id::create("regmodel");
    regmodel.build();
    regmodel.reset();
    adapter   = axil_adapter::type_id::create("adapter");
    predictor = uvm_reg_predictor#(axil_item)::type_id::create("predictor", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    cpu.mon.ap.connect(bus_sb.cpu_imp);
    cpu.mon.ap.connect(uart_sb.cpu_imp);
    cpu.mon.ap.connect(spi_sb.cpu_imp);
    cpu.mon.ap.connect(cov.cpu_imp);
    mem_mon.ap.connect(bus_sb.mem_imp);
    for (int i = 0; i < 4; i++) apb_mon[i].ap.connect(bus_sb.apb_imp);
    uart.mon.tx_ap.connect(uart_sb.tx_imp);
    uart.drv.sent_ap.connect(uart_sb.rx_imp);
    uart.mon.tx_ap.connect(cov.utx_imp);
    uart.drv.sent_ap.connect(cov.urx_imp);
    spi.ap.connect(spi_sb.spi_imp);
    spi.ap.connect(cov.spi_imp);

    regmodel.default_map.set_sequencer(cpu.sqr, adapter);
    regmodel.default_map.set_auto_predict(0);
    predictor.map     = regmodel.default_map;
    predictor.adapter = adapter;
    cpu.mon.ap.connect(predictor.bus_in);
  endfunction
endclass
