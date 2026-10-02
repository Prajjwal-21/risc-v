// =============================================================================
// axil_agent.svh - AXI4-Lite master agent (docs/architecture.md P7.2)
// -----------------------------------------------------------------------------
// axil_item     one read or write; the driver fills in rdata and resp.
// axil_driver   drives the DUT's CPU-side slave port. A write presents AW and
//               W together, AW first or W first (item.order), with `gap`
//               cycles between them; B/R ready rises after `rsp_delay` cycles.
//               Every valid stays up, payload stable, until its handshake.
// axil_monitor  observes any AXI4-Lite link (CPU port or memory port) and
//               publishes each completed transaction on `ap`.
// axil_adapter  uvm_reg_adapter for the register model (plain full-word
//               accesses, AW and W together).
// =============================================================================

typedef enum { AXIL_TOGETHER, AXIL_AW_FIRST, AXIL_W_FIRST } axil_order_e;

class axil_item extends uvm_sequence_item;
  `uvm_object_utils(axil_item)

  rand bit          write;
  rand logic [31:0] addr;
  rand logic [31:0] data;
  rand logic [3:0]  strb;
  rand axil_order_e order;
  rand int unsigned gap;         // cycles between the first and second of AW/W
  rand int unsigned rsp_delay;   // cycles before BREADY/RREADY rises
  logic [31:0]      rdata;       // filled in by the driver / monitor
  logic [1:0]       resp;

  constraint c_align { addr[1:0] == 2'b00; }
  constraint c_strb  { write -> strb != 4'b0000; !write -> strb == 4'b0000; }
  constraint c_gap   { gap inside {[0:3]}; rsp_delay inside {[0:3]}; }

  function new(string name = "axil_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("%s %08h %s strb=%b resp=%0d%s", write ? "W" : "R", addr,
                     write ? $sformatf("data=%08h", data) : $sformatf("rdata=%08h", rdata),
                     strb, resp, write ? $sformatf(" order=%s gap=%0d", order.name(), gap) : "");
  endfunction
endclass

class axil_driver extends uvm_driver #(axil_item);
  `uvm_component_utils(axil_driver)

  virtual axil_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "axil_driver: no virtual interface")
  endfunction

  task run_phase(uvm_phase phase);
    vif.req <= '0;
    wait (vif.rst_n === 1'b1);
    forever begin
      seq_item_port.get_next_item(req);
      if (req.write) do_write(req);
      else           do_read(req);
      seq_item_port.item_done();
    end
  endtask

  task send_aw(axil_item t);
    vif.req.aw_valid <= 1'b1;
    vif.req.aw       <= '{addr: t.addr, prot: axil_pkg::AXI_PROT_DATA};
    do @(posedge vif.clk); while (vif.rsp.aw_ready !== 1'b1);
    vif.req.aw_valid <= 1'b0;
  endtask

  task send_w(axil_item t);
    vif.req.w_valid <= 1'b1;
    vif.req.w       <= '{data: t.data, strb: t.strb};
    do @(posedge vif.clk); while (vif.rsp.w_ready !== 1'b1);
    vif.req.w_valid <= 1'b0;
  endtask

  task do_write(axil_item t);
    case (t.order)
      AXIL_AW_FIRST: begin send_aw(t); repeat (t.gap) @(posedge vif.clk); send_w(t); end
      AXIL_W_FIRST:  begin send_w(t);  repeat (t.gap) @(posedge vif.clk); send_aw(t); end
      default: fork send_aw(t); send_w(t); join
    endcase
    repeat (t.rsp_delay) @(posedge vif.clk);
    vif.req.b_ready <= 1'b1;
    do @(posedge vif.clk); while (vif.rsp.b_valid !== 1'b1);
    t.resp = vif.rsp.b.resp;
    vif.req.b_ready <= 1'b0;
  endtask

  task do_read(axil_item t);
    vif.req.ar_valid <= 1'b1;
    vif.req.ar       <= '{addr: t.addr, prot: axil_pkg::AXI_PROT_DATA};
    do @(posedge vif.clk); while (vif.rsp.ar_ready !== 1'b1);
    vif.req.ar_valid <= 1'b0;
    repeat (t.rsp_delay) @(posedge vif.clk);
    vif.req.r_ready <= 1'b1;
    do @(posedge vif.clk); while (vif.rsp.r_valid !== 1'b1);
    t.rdata = vif.rsp.r.data;
    t.resp  = vif.rsp.r.resp;
    vif.req.r_ready <= 1'b0;
  endtask
endclass

class axil_monitor extends uvm_monitor;
  `uvm_component_utils(axil_monitor)

  virtual axil_if vif;
  uvm_analysis_port #(axil_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "axil_monitor: no virtual interface")
  endfunction

  task run_phase(uvm_phase phase);
    axil_item aws[$], ws[$], ars[$];
    forever begin
      @(posedge vif.clk);
      if (vif.rst_n !== 1'b1) continue;
      // AW and W arrive in either order; pair them in order of arrival and
      // record which came first.
      if (vif.req.aw_valid && vif.rsp.aw_ready) begin
        axil_item t = axil_item::type_id::create("aw");
        t.write = 1'b1;
        t.addr  = vif.req.aw.addr;
        if (vif.req.w_valid && vif.rsp.w_ready && ws.size() == 0) t.order = AXIL_TOGETHER;
        else if (ws.size() > 0)                                   t.order = AXIL_W_FIRST;
        else                                                      t.order = AXIL_AW_FIRST;
        aws.push_back(t);
      end
      if (vif.req.w_valid && vif.rsp.w_ready) begin
        axil_item t = axil_item::type_id::create("w");
        t.data = vif.req.w.data;
        t.strb = vif.req.w.strb;
        ws.push_back(t);
      end
      if (vif.rsp.b_valid && vif.req.b_ready) begin
        axil_item t;
        if (aws.size() == 0 || ws.size() == 0)
          `uvm_error("AXIL", "B response without a complete write")
        else begin
          axil_item w = ws.pop_front();
          t = aws.pop_front();
          t.data = w.data;
          t.strb = w.strb;
          t.resp = vif.rsp.b.resp;
          ap.write(t);
        end
      end
      if (vif.req.ar_valid && vif.rsp.ar_ready) begin
        axil_item t = axil_item::type_id::create("ar");
        t.write = 1'b0;
        t.addr  = vif.req.ar.addr;
        t.strb  = '0;
        ars.push_back(t);
      end
      if (vif.rsp.r_valid && vif.req.r_ready) begin
        if (ars.size() == 0) `uvm_error("AXIL", "R response without a read")
        else begin
          axil_item t = ars.pop_front();
          t.rdata = vif.rsp.r.data;
          t.resp  = vif.rsp.r.resp;
          ap.write(t);
        end
      end
    end
  endtask
endclass

class axil_agent extends uvm_agent;
  `uvm_component_utils(axil_agent)

  axil_driver                  drv;
  uvm_sequencer #(axil_item)   sqr;
  axil_monitor                 mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = axil_monitor::type_id::create("mon", this);
    if (get_is_active() == UVM_ACTIVE) begin
      drv = axil_driver::type_id::create("drv", this);
      sqr = uvm_sequencer#(axil_item)::type_id::create("sqr", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    if (get_is_active() == UVM_ACTIVE) drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class axil_adapter extends uvm_reg_adapter;
  `uvm_object_utils(axil_adapter)

  function new(string name = "axil_adapter");
    super.new(name);
    supports_byte_enable = 1;
    provides_responses   = 0;
  endfunction

  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    axil_item t = axil_item::type_id::create("reg_item");
    t.write     = (rw.kind == UVM_WRITE);
    t.addr      = 32'(rw.addr);
    t.data      = 32'(rw.data);
    t.strb      = t.write ? 4'(rw.byte_en) : 4'b0000;
    if (t.write && t.strb == '0) t.strb = 4'b1111;
    t.order     = AXIL_TOGETHER;
    t.gap       = 0;
    t.rsp_delay = 0;
    return t;
  endfunction

  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    axil_item t;
    if (!$cast(t, bus_item)) begin
      `uvm_fatal("ADAPTER", "bus2reg: not an axil_item")
      return;
    end
    rw.kind    = t.write ? UVM_WRITE : UVM_READ;
    rw.addr    = uvm_reg_addr_t'(t.addr);
    rw.data    = t.write ? uvm_reg_data_t'(t.data) : uvm_reg_data_t'(t.rdata);
    rw.byte_en = uvm_reg_byte_en_t'(t.write ? {4'b0, t.strb} : 8'h0F);
    rw.status  = t.resp[1] ? UVM_NOT_OK : UVM_IS_OK;
  endfunction
endclass
