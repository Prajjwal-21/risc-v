// =============================================================================
// periph_tests.svh - sequences and tests (docs/architecture.md P7.2)
// -----------------------------------------------------------------------------
// reg_reset_test    uvm_reg_hw_reset_seq on the whole register model
// reg_bitbash_test  uvm_reg_bit_bash_seq (registers without side effects)
// uart_tx_test      random bytes at random bit lengths, TXDATA -> TX pin
// uart_rx_test      random bytes at random bit lengths, RX pin -> RXDATA
// spi_test          random modes, bit orders, dividers and data, both ways
// irq_test          CLINT timer and software interrupts; PLIC priority,
//                   claim and complete with UART and SPI sources
// axil_order_test   random reads and writes to every region, including
//                   unmapped addresses and offsets without a register, with
//                   random AW/W order and delays (the bus scoreboard checks)
// Every test prints "** UVM TEST PASSED **" when no UVM_ERROR/UVM_FATAL was
// reported; `make uvm` checks for it.
// =============================================================================

class axil_single_seq extends uvm_sequence #(axil_item);
  `uvm_object_utils(axil_single_seq)
  axil_item item;
  function new(string name = "axil_single_seq");
    super.new(name);
  endfunction
  task body();
    start_item(item);
    finish_item(item);
  endtask
endclass

class uart_bytes_seq extends uvm_sequence #(uart_item);
  `uvm_object_utils(uart_bytes_seq)
  logic [7:0] data[$];
  function new(string name = "uart_bytes_seq");
    super.new(name);
  endfunction
  task body();
    foreach (data[i]) begin
      uart_item t = uart_item::type_id::create("t");
      start_item(t);
      t.data = data[i];
      t.idle = $urandom_range(0, 20);
      finish_item(t);
    end
  endtask
endclass

class base_test extends uvm_test;
  `uvm_component_utils(base_test)

  periph_env     env;
  virtual irq_if irq_vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = periph_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual irq_if)::get(this, "", "irq_vif", irq_vif))
      `uvm_fatal("NOVIF", "base_test: no irq_if")
    // The longest test needs about 0.12 ms of simulated time: a transaction
    // that never completes ends the run with a UVM_FATAL (PH_TIMEOUT).
    uvm_top.set_timeout(2ms, 1);
  endfunction

  task cycles(int unsigned n);
    repeat (n) @(posedge irq_vif.clk);
  endtask

  task wr(uvm_reg r, logic [31:0] v);
    uvm_status_e st;
    r.write(st, uvm_reg_data_t'(v));
    if (st != UVM_IS_OK) `uvm_error("REG", $sformatf("write %s failed", r.get_full_name()))
  endtask

  task rd(uvm_reg r, output uvm_reg_data_t v);
    uvm_status_e st;
    r.read(st, v);
    if (st != UVM_IS_OK) `uvm_error("REG", $sformatf("read %s failed", r.get_full_name()))
  endtask

  // One raw AXI4-Lite access (not through the register model)
  task axi(bit write, logic [31:0] addr, logic [31:0] data, logic [3:0] strb,
           axil_order_e order, int unsigned gap, output logic [1:0] resp, output logic [31:0] rdata);
    axil_single_seq s = axil_single_seq::type_id::create("s");
    s.item = axil_item::type_id::create("item");
    s.item.write = write; s.item.addr = addr; s.item.data = data; s.item.strb = strb;
    s.item.order = order; s.item.gap = gap; s.item.rsp_delay = $urandom_range(0, 3);
    s.start(env.cpu.sqr);
    resp  = s.item.resp;
    rdata = s.item.rdata;
  endtask

  task wait_reg(uvm_reg r, uvm_reg_data_t mask, uvm_reg_data_t want, int unsigned tries = 2000);
    uvm_reg_data_t v;
    for (int i = 0; i < tries; i++) begin
      rd(r, v);
      if ((v & mask) == want) return;
    end
    `uvm_error("WAIT", $sformatf("%s & %h never became %h", r.get_full_name(), mask, want))
  endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server srv = uvm_report_server::get_server();
    if (srv.get_severity_count(UVM_ERROR) == 0 && srv.get_severity_count(UVM_FATAL) == 0)
      `uvm_info("TEST", "** UVM TEST PASSED **", UVM_NONE)
    else
      `uvm_info("TEST", "** UVM TEST FAILED **", UVM_NONE)
  endfunction
endclass

class reg_reset_test extends base_test;
  `uvm_component_utils(reg_reset_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    uvm_reg_hw_reset_seq seq = uvm_reg_hw_reset_seq::type_id::create("seq");
    phase.raise_objection(this);
    cycles(10);
    seq.model = env.regmodel;
    seq.start(null);
    phase.drop_objection(this);
  endtask
endclass

class reg_bitbash_test extends base_test;
  `uvm_component_utils(reg_bitbash_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    uvm_reg_bit_bash_seq seq = uvm_reg_bit_bash_seq::type_id::create("seq");
    phase.raise_objection(this);
    cycles(10);
    seq.model = env.regmodel;
    seq.start(null);
    phase.drop_objection(this);
  endtask
endclass

class uart_tx_test extends base_test;
  `uvm_component_utils(uart_tx_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    uart_block u = env.regmodel.uart;
    phase.raise_objection(this);
    cycles(10);
    for (int it = 0; it < 4; it++) begin
      int unsigned len = (it == 0) ? 2 : $urandom_range(3, 40);
      env.uart_c.bit_len = len;
      wr(u.regs["bauddiv"], 32'(len));
      wr(u.regs["ctrl"], 1);                                   // TXEN
      for (int i = 0; i < 12; i++) begin
        logic [7:0] b = (i == 0) ? 8'h00 : (i == 1) ? 8'hFF : 8'($urandom);
        wait_reg(u.regs["status"], 1 << soc_pkg::UART_ST_TXFULL, 0);
        wr(u.regs["txdata"], 32'(b));
      end
      wait_reg(u.regs["status"], 1 << soc_pkg::UART_ST_TXEMPTY, 1 << soc_pkg::UART_ST_TXEMPTY, 20000);
      cycles(2 * len);                                         // the monitor's last stop bit
    end
    phase.drop_objection(this);
  endtask
endclass

class uart_rx_test extends base_test;
  `uvm_component_utils(uart_rx_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    uart_block u = env.regmodel.uart;
    phase.raise_objection(this);
    cycles(10);
    for (int it = 0; it < 4; it++) begin
      uart_bytes_seq s = uart_bytes_seq::type_id::create("s");
      int unsigned   len = (it == 0) ? 2 : $urandom_range(3, 40);
      uvm_reg_data_t v;
      env.uart_c.bit_len = len;
      wr(u.regs["bauddiv"], 32'(len));
      wr(u.regs["ctrl"], 2);                                   // RXEN
      for (int i = 0; i < 6; i++) s.data.push_back((i == 0) ? 8'h00 : (i == 1) ? 8'hFF : 8'($urandom));
      s.start(env.uart.sqr);                                   // returns once all are sent
      cycles(2 * len);
      for (int i = 0; i < 6; i++) begin
        rd(u.regs["rxdata"], v);
        if (v[31]) `uvm_error("UART", $sformatf("RXDATA empty at byte %0d of 6", i))
      end
      rd(u.regs["rxdata"], v);
      if (!v[31]) `uvm_error("UART", "RXDATA not empty after the bytes sent")
    end
    phase.drop_objection(this);
  endtask
endclass

class spi_test extends base_test;
  `uvm_component_utils(spi_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    spi_block sp = env.regmodel.spi;
    phase.raise_objection(this);
    cycles(10);
    for (int it = 0; it < 16; it++) begin
      bit cpol = it[0], cpha = it[1], lsb = it[2];
      int unsigned div = (it < 8) ? 1 + it % 3 : $urandom_range(1, 6);
      uvm_reg_data_t v;
      if (it >= 8) begin cpol = 1'($urandom); cpha = 1'($urandom); lsb = 1'($urandom); end
      env.spi_c.cpol = cpol;
      env.spi_c.cpha = cpha;
      env.spi_c.lsb  = lsb;
      wr(sp.regs["clkdiv"], 32'(div));
      wr(sp.regs["ctrl"], {28'b0, lsb, cpha, cpol, 1'b1});
      wr(sp.regs["cs"], 1);
      for (int i = 0; i < 4; i++) wr(sp.regs["txdata"], 32'($urandom_range(0, 255)));
      wait_reg(sp.regs["status"], 1 << soc_pkg::SPI_ST_BUSY, 0);
      wr(sp.regs["cs"], 0);
      for (int i = 0; i < 4; i++) begin
        rd(sp.regs["rxdata"], v);
        if (v[31]) `uvm_error("SPI", $sformatf("RXDATA empty at byte %0d of 4", i))
      end
    end
    phase.drop_objection(this);
  endtask
endclass

class irq_test extends base_test;
  `uvm_component_utils(irq_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // which: 0 = MSIP, 1 = MTIP, 2 = MEIP
  function logic line(int which);
    return (which == 0) ? irq_vif.sw : (which == 1) ? irq_vif.timer : irq_vif.ext;
  endfunction

  task expect_line(int which, bit want, int unsigned max_cycles);
    string names[3] = '{"MSIP", "MTIP", "MEIP"};
    for (int i = 0; i < max_cycles; i++) begin
      if (line(which) === want) return;
      cycles(1);
    end
    `uvm_error("IRQ", $sformatf("%s did not become %0b within %0d cycles", names[which], want, max_cycles))
  endtask

  task run_phase(uvm_phase phase);
    clint_block    c = env.regmodel.clint;
    plic_block     p = env.regmodel.plic;
    uart_block     u = env.regmodel.uart;
    spi_block      sp = env.regmodel.spi;
    uvm_reg_data_t v;
    phase.raise_objection(this);
    cycles(10);

    // CLINT timer: MTIP rises when mtime reaches mtimecmp, not before
    rd(c.regs["mtime"], v);
    wr(c.regs["mtimecmph"], 0);
    wr(c.regs["mtimecmp"], 32'(v) + 32'd60);
    if (irq_vif.timer !== 1'b0) `uvm_error("IRQ", "MTIP high before mtime reached mtimecmp")
    expect_line(1, 1'b1, 60 * soc_pkg::MTIME_PRESCALE + 50);
    if (irq_vif.mtime < v + 60) `uvm_error("IRQ", "MTIP high before mtime reached mtimecmp")
    wr(c.regs["mtimecmph"], 32'hFFFF_FFFF);
    expect_line(1, 1'b0, 5);

    // CLINT software interrupt
    wr(c.regs["msip"], 1);
    expect_line(0, 1'b1, 5);
    wr(c.regs["msip"], 0);
    expect_line(0, 1'b0, 5);

    // PLIC: UART RX (source 1)
    begin
      uart_bytes_seq s = uart_bytes_seq::type_id::create("s");
      env.uart_c.bit_len = 8;
      wr(u.regs["bauddiv"], 8);
      wr(u.regs["ctrl"], 2);
      wr(u.regs["ie"], 1);
      wr(p.regs["priority1"], 1);
      wr(p.regs["enable"], 2);
      wr(p.regs["threshold"], 0);
      if (irq_vif.ext !== 1'b0) `uvm_error("IRQ", "MEIP high with nothing pending")
      s.data.push_back(8'h5A);
      s.start(env.uart.sqr);
      expect_line(2, 1'b1, 100);
      rd(p.regs["claim"], v);
      if (v != 1) `uvm_error("IRQ", $sformatf("claim returned %0d, expected 1 (UART)", v))
      rd(u.regs["rxdata"], v);
      wr(p.regs["claim"], 1);                                  // complete
      expect_line(2, 1'b0, 10);
      wr(u.regs["ie"], 0);
    end

    // PLIC: SPI idle (source 2) against the UART at lower priority
    wr(p.regs["priority1"], 1);
    wr(p.regs["priority2"], 3);
    wr(p.regs["enable"], 6);
    wr(u.regs["ie"], 2);                                       // TX empty: high
    wr(sp.regs["ie"], 2);                                      // SPI idle: high
    expect_line(2, 1'b1, 10);
    rd(p.regs["claim"], v);
    if (v != 2) `uvm_error("IRQ", $sformatf("claim returned %0d, expected 2 (SPI, priority 3)", v))
    rd(p.regs["claim"], v);
    if (v != 1) `uvm_error("IRQ", $sformatf("second claim returned %0d, expected 1 (UART)", v))
    wr(sp.regs["ie"], 0);
    wr(u.regs["ie"], 0);
    wr(p.regs["claim"], 2);
    wr(p.regs["claim"], 1);
    expect_line(2, 1'b0, 10);
    phase.drop_objection(this);
  endtask
endclass

class axil_order_test extends base_test;
  `uvm_component_utils(axil_order_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function logic [31:0] pick_addr();
    // Registers of every peripheral, offsets without a register, main memory,
    // and unmapped addresses next to each region.
    logic [31:0] regs[] = '{
      soc_pkg::CLINT_BASE + 32'h0000, soc_pkg::CLINT_BASE + 32'h4000, soc_pkg::CLINT_BASE + 32'h4004,
      soc_pkg::CLINT_BASE + 32'hBFF8, soc_pkg::CLINT_BASE + 32'h0008,
      soc_pkg::PLIC_BASE + 32'h4, soc_pkg::PLIC_BASE + 32'h8, soc_pkg::PLIC_BASE + 32'h2000,
      soc_pkg::PLIC_BASE + 32'h20_0000, soc_pkg::PLIC_BASE + 32'h0, soc_pkg::PLIC_BASE + 32'h1000,
      soc_pkg::UART_BASE + 32'h0C, soc_pkg::UART_BASE + 32'h10, soc_pkg::UART_BASE + 32'h14,
      soc_pkg::UART_BASE + 32'h08, soc_pkg::UART_BASE + 32'h18,
      soc_pkg::SPI_BASE + 32'h10, soc_pkg::SPI_BASE + 32'h18, soc_pkg::SPI_BASE + 32'h08,
      soc_pkg::SPI_BASE + 32'h1C,
      32'h0000_0000, 32'h01FF_FFFC, 32'h0201_0000, 32'h0C40_0000, 32'h1000_2000, 32'h7FFF_FFFC,
      32'h8001_0000, 32'hFFFF_FFFC};
    case ($urandom_range(0, 2))
      0: return regs[$urandom_range(0, regs.size() - 1)];
      1: return soc_pkg::MEM_BASE + 32'({$urandom_range(0, soc_pkg::MEM_SIZE / 4 - 1), 2'b00});
      default: return regs[$urandom_range(20, regs.size() - 1)];
    endcase
  endfunction

  task run_phase(uvm_phase phase);
    logic [3:0] strbs[] = '{4'b1111, 4'b0011, 4'b1100, 4'b0001, 4'b0010, 4'b0100, 4'b1000};
    phase.raise_objection(this);
    env.uart_sb.enabled = 0;           // random TXDATA/RXDATA traffic: the bus
    env.spi_sb.enabled  = 0;           // scoreboard is the checker here
    cycles(10);
    for (int i = 0; i < 600; i++) begin
      logic [1:0]  resp;
      logic [31:0] rdata;
      bit          write = 1'($urandom_range(0, 1));
      axi(write, pick_addr(), $urandom, write ? strbs[$urandom_range(0, strbs.size() - 1)] : 4'b0000,
          axil_order_e'($urandom_range(0, 2)), $urandom_range(0, 3), resp, rdata);
    end
    cycles(20);
    phase.drop_objection(this);
  endtask
endclass
