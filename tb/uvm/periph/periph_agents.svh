// =============================================================================
// periph_agents.svh - APB, UART and SPI agents (docs/architecture.md P7.2)
// -----------------------------------------------------------------------------
// apb_monitor   passive, one per APB slot: publishes every completed transfer.
// uart_agent    driver: sends 8N1 bytes into the DUT's RX pin with the bit
//               length in uart_cfg; monitor: decodes the DUT's TX pin (tx_ap)
//               and republishes the bytes the driver sent (rx_ap).
// spi_agent     a slave device: answers each frame with the next byte of its
//               response queue (random when empty), samples MOSI; the mode
//               (CPOL, CPHA, bit order) comes from spi_cfg, set by the test
//               independently of the DUT's CTRL register. Publishes frames.
// =============================================================================

// ---------------------------------------------------------------------------
// APB
// ---------------------------------------------------------------------------
class apb_item extends uvm_sequence_item;
  `uvm_object_utils(apb_item)
  int          slot;
  logic [31:0] addr, wdata, rdata;
  logic [3:0]  strb;
  bit          write, slverr;
  function new(string name = "apb_item");
    super.new(name);
  endfunction
  function string convert2string();
    return $sformatf("slot %0d %s %08h wdata=%08h strb=%b rdata=%08h slverr=%0b", slot,
                     write ? "W" : "R", addr, wdata, strb, rdata, slverr);
  endfunction
endclass

class apb_monitor extends uvm_monitor;
  `uvm_component_utils(apb_monitor)
  virtual apb_if vif;
  int            slot;
  uvm_analysis_port #(apb_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "apb_monitor: no virtual interface")
    void'(uvm_config_db#(int)::get(this, "", "slot", slot));
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.clk);
      if (vif.rst_n === 1'b1 && vif.req.psel && vif.req.penable && vif.rsp.pready) begin
        apb_item t = apb_item::type_id::create("apb");
        t.slot   = slot;
        t.addr   = vif.req.paddr;
        t.write  = vif.req.pwrite;
        t.wdata  = vif.req.pwdata;
        t.strb   = vif.req.pstrb;
        t.rdata  = vif.rsp.prdata;
        t.slverr = vif.rsp.pslverr;
        ap.write(t);
      end
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// UART
// ---------------------------------------------------------------------------
class uart_cfg extends uvm_object;
  `uvm_object_utils(uart_cfg)
  int unsigned bit_len = 16;          // clock cycles per bit (= DUT BAUDDIV)
  function new(string name = "uart_cfg");
    super.new(name);
  endfunction
endclass

class uart_item extends uvm_sequence_item;
  `uvm_object_utils(uart_item)
  rand logic [7:0]  data;
  rand int unsigned idle;             // idle cycles before the start bit
  int unsigned      bit_len;          // recorded by the monitor
  constraint c_idle { idle inside {[0:20]}; }
  function new(string name = "uart_item");
    super.new(name);
  endfunction
  function string convert2string();
    return $sformatf("uart byte %02h (bit length %0d)", data, bit_len);
  endfunction
endclass

class uart_driver extends uvm_driver #(uart_item);
  `uvm_component_utils(uart_driver)
  virtual uart_if vif;
  uart_cfg        cfg;
  uvm_analysis_port #(uart_item) sent_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    sent_ap = new("sent_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual uart_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "uart_driver: no virtual interface")
    if (!uvm_config_db#(uart_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "uart_driver: no uart_cfg")
  endfunction

  task run_phase(uvm_phase phase);
    vif.rx <= 1'b1;
    wait (vif.rst_n === 1'b1);
    forever begin
      logic [9:0] frame;
      seq_item_port.get_next_item(req);
      repeat (req.idle) @(posedge vif.clk);
      frame = {1'b1, req.data, 1'b0};
      for (int b = 0; b < 10; b++) begin
        vif.rx <= frame[b];
        repeat (cfg.bit_len) @(posedge vif.clk);
      end
      req.bit_len = cfg.bit_len;
      sent_ap.write(req);
      seq_item_port.item_done();
    end
  endtask
endclass

class uart_monitor_c extends uvm_monitor;
  `uvm_component_utils(uart_monitor_c)
  virtual uart_if vif;
  uart_cfg        cfg;
  uvm_analysis_port #(uart_item) tx_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    tx_ap = new("tx_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual uart_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "uart_monitor: no virtual interface")
    if (!uvm_config_db#(uart_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "uart_monitor: no uart_cfg")
  endfunction

  task run_phase(uvm_phase phase);
    wait (vif.rst_n === 1'b1);
    forever begin
      uart_item   t;
      logic [7:0] b;
      int unsigned len;
      @(negedge vif.tx);
      len = cfg.bit_len;
      repeat (len / 2) @(posedge vif.clk);
      if (vif.tx !== 1'b0) continue;                     // glitch
      for (int i = 0; i < 8; i++) begin
        repeat (len) @(posedge vif.clk);
        b[i] = vif.tx;
      end
      repeat (len) @(posedge vif.clk);
      if (vif.tx !== 1'b1) `uvm_error("UART", $sformatf("TX stop bit is 0 after byte %02h", b))
      t = uart_item::type_id::create("tx");
      t.data    = b;
      t.bit_len = len;
      tx_ap.write(t);
    end
  endtask
endclass

class uart_agent extends uvm_agent;
  `uvm_component_utils(uart_agent)
  uart_driver                drv;
  uvm_sequencer #(uart_item) sqr;
  uart_monitor_c             mon;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    drv = uart_driver::type_id::create("drv", this);
    sqr = uvm_sequencer#(uart_item)::type_id::create("sqr", this);
    mon = uart_monitor_c::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

// ---------------------------------------------------------------------------
// SPI (slave device)
// ---------------------------------------------------------------------------
class spi_cfg extends uvm_object;
  `uvm_object_utils(spi_cfg)
  bit cpol, cpha, lsb;
  function new(string name = "spi_cfg");
    super.new(name);
  endfunction
endclass

class spi_frame extends uvm_sequence_item;
  `uvm_object_utils(spi_frame)
  logic [7:0] mosi, miso;
  bit         cpol, cpha, lsb;
  function new(string name = "spi_frame");
    super.new(name);
  endfunction
  function string convert2string();
    return $sformatf("spi frame mode %0d%s mosi=%02h miso=%02h", {cpol, cpha},
                     lsb ? " lsb-first" : "", mosi, miso);
  endfunction
endclass

class spi_slave extends uvm_component;
  `uvm_component_utils(spi_slave)
  virtual spi_if vif;
  spi_cfg        cfg;
  logic [7:0]    responses[$];         // next MISO bytes; random when empty
  uvm_analysis_port #(spi_frame) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual spi_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "spi_slave: no virtual interface")
    if (!uvm_config_db#(spi_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "spi_slave: no spi_cfg")
  endfunction

  function logic bit_of(logic [7:0] b, int k);
    return cfg.lsb ? b[k] : b[7 - k];
  endfunction

  task run_phase(uvm_phase phase);
    logic [7:0] tx, rx;
    int         samples, drives;
    logic       prev_sclk;
    vif.miso <= 1'b0;
    wait (vif.rst_n === 1'b1);
    tx = next_tx();
    samples = 0;
    drives  = 0;
    prev_sclk = vif.sclk;
    forever begin
      @(vif.sclk or vif.cs_n);
      if (vif.cs_n === 1'b1) begin
        if (samples != 0) `uvm_error("SPI", $sformatf("CS released after %0d bits", samples))
        samples = 0;
        drives  = 0;
        prev_sclk = vif.sclk;
        continue;
      end
      if (vif.sclk === prev_sclk) begin                  // CS asserted
        if (!cfg.cpha) vif.miso <= bit_of(tx, 0);
        continue;
      end
      prev_sclk = vif.sclk;
      if ((vif.sclk !== cfg.cpol) != cfg.cpha) begin     // sample MOSI
        rx = cfg.lsb ? {vif.mosi, rx[7:1]} : {rx[6:0], vif.mosi};
        samples++;
        if (cfg.cpha && samples == 8) end_frame(tx, rx, samples, drives);
      end else if (cfg.cpha) begin                       // drive on leading
        vif.miso <= bit_of(tx, drives);
        drives++;
      end else if (samples == 8) begin                   // CPHA 0: last edge
        end_frame(tx, rx, samples, drives);
        vif.miso <= bit_of(tx, 0);
      end else begin                                     // CPHA 0: next bit
        drives++;
        vif.miso <= bit_of(tx, drives);
      end
    end
  endtask

  function logic [7:0] next_tx();
    return (responses.size() > 0) ? responses.pop_front() : 8'($urandom);
  endfunction

  function void end_frame(inout logic [7:0] tx, input logic [7:0] rx, inout int samples,
                          inout int drives);
    spi_frame f = spi_frame::type_id::create("frame");
    f.mosi = rx;
    f.miso = tx;
    f.cpol = cfg.cpol;
    f.cpha = cfg.cpha;
    f.lsb  = cfg.lsb;
    ap.write(f);
    tx = next_tx();
    samples = 0;
    drives  = 0;
  endfunction
endclass
