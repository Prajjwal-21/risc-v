// =============================================================================
// periph_checks.svh - scoreboards and coverage (docs/architecture.md P7.2)
// -----------------------------------------------------------------------------
// bus_scoreboard   every CPU-port transaction is checked against the address
//                  map: to an APB window -> exactly one APB transfer on that
//                  slot with the same address, direction, data and strobes
//                  (PSTRB = 0 on reads), PSLVERR <-> SLVERR, PRDATA = RDATA;
//                  to main memory -> exactly one transaction on the memory port
//                  with the same fields; unmapped -> SLVERR and nothing
//                  downstream. At the end nothing may be left unmatched.
// uart_scoreboard  bytes written to TXDATA (OKAY, TX FIFO not full) equal the
//                  bytes decoded on TX, in order; bytes the agent sent equal the
//                  bytes read from RXDATA (EMPTY = 0), in order.
// spi_scoreboard   bytes written to TXDATA equal the MOSI bytes of the frames;
//                  the MISO bytes equal the bytes read from RXDATA.
// periph_cov       explicit coverage bins (Verilator 5.052 does not sample
//                  covergroups, D-050); reported at the end, also as JSON
//                  (+uvm_cov_json=<file>).
// =============================================================================

`uvm_analysis_imp_decl(_cpu)
`uvm_analysis_imp_decl(_mem)
`uvm_analysis_imp_decl(_apb)
`uvm_analysis_imp_decl(_uart_tx)
`uvm_analysis_imp_decl(_uart_rx)
`uvm_analysis_imp_decl(_spi)

// Region of an address, as the SoC decodes it (soc_pkg).
typedef enum { RG_MEM, RG_CLINT, RG_PLIC, RG_UART, RG_SPI, RG_UNMAPPED } region_e;

function automatic region_e region_of(logic [31:0] a);
  if ((a - soc_pkg::MEM_BASE)   < soc_pkg::MEM_SIZE)   return RG_MEM;
  if ((a - soc_pkg::CLINT_BASE) < soc_pkg::CLINT_SIZE) return RG_CLINT;
  if ((a - soc_pkg::PLIC_BASE)  < soc_pkg::PLIC_SIZE)  return RG_PLIC;
  if ((a - soc_pkg::UART_BASE)  < soc_pkg::UART_SIZE)  return RG_UART;
  if ((a - soc_pkg::SPI_BASE)   < soc_pkg::SPI_SIZE)   return RG_SPI;
  return RG_UNMAPPED;
endfunction

class bus_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(bus_scoreboard)

  uvm_analysis_imp_cpu #(axil_item, bus_scoreboard) cpu_imp;
  uvm_analysis_imp_mem #(axil_item, bus_scoreboard) mem_imp;
  uvm_analysis_imp_apb #(apb_item, bus_scoreboard)  apb_imp;

  axil_item mem_q[$];
  apb_item  apb_q[4][$];
  int       n_checked, n_errors;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cpu_imp = new("cpu_imp", this);
    mem_imp = new("mem_imp", this);
    apb_imp = new("apb_imp", this);
  endfunction

  function void write_mem(axil_item t);
    mem_q.push_back(t);
  endfunction

  function void write_apb(apb_item t);
    apb_q[t.slot].push_back(t);
  endfunction

  function void fail(string msg);
    n_errors++;
    `uvm_error("BUS_SB", msg)
  endfunction

  function void write_cpu(axil_item t);
    region_e r = region_of(t.addr);
    n_checked++;
    case (r)
      RG_UNMAPPED: if (t.resp != axil_pkg::AXI_RESP_SLVERR)
        fail($sformatf("unmapped %s: resp %0d, expected SLVERR", t.convert2string(), t.resp));
      RG_MEM: begin
        axil_item m;
        if (mem_q.size() == 0) begin
          fail($sformatf("%s reached no memory transaction", t.convert2string()));
          return;
        end
        m = mem_q.pop_front();
        if (m.write != t.write || m.addr != t.addr || m.resp != t.resp
            || (t.write && (m.data != t.data || m.strb != t.strb))
            || (!t.write && m.rdata != t.rdata))
          fail($sformatf("memory port %s differs from CPU port %s", m.convert2string(),
                         t.convert2string()));
      end
      default: begin
        int      slot = int'(r) - int'(RG_CLINT);
        apb_item a;
        if (apb_q[slot].size() == 0) begin
          fail($sformatf("%s produced no APB transfer on slot %0d", t.convert2string(), slot));
          return;
        end
        a = apb_q[slot].pop_front();
        if (a.addr != t.addr || a.write != t.write
            || (t.write && (a.wdata != t.data || a.strb != t.strb))
            || (!t.write && (a.strb != '0 || a.rdata != t.rdata))
            || (t.resp != (a.slverr ? axil_pkg::AXI_RESP_SLVERR : axil_pkg::AXI_RESP_OKAY)))
          fail($sformatf("APB %s differs from CPU %s", a.convert2string(), t.convert2string()));
      end
    endcase
  endfunction

  function void check_phase(uvm_phase phase);
    if (mem_q.size() != 0) fail($sformatf("%0d memory transactions without a CPU transaction", mem_q.size()));
    for (int s = 0; s < 4; s++)
      if (apb_q[s].size() != 0) fail($sformatf("%0d APB transfers on slot %0d without a CPU transaction",
                                               apb_q[s].size(), s));
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("BUS_SB", $sformatf("%0d CPU transactions checked, %0d errors", n_checked, n_errors), UVM_LOW)
  endfunction
endclass

class uart_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(uart_scoreboard)

  uvm_analysis_imp_cpu #(axil_item, uart_scoreboard)     cpu_imp;
  uvm_analysis_imp_uart_tx #(uart_item, uart_scoreboard) tx_imp;
  uvm_analysis_imp_uart_rx #(uart_item, uart_scoreboard) rx_imp;

  logic [7:0] exp_tx[$], exp_rx[$];
  int         n_tx, n_rx;
  bit         enabled = 1;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cpu_imp = new("cpu_imp", this);
    tx_imp  = new("tx_imp", this);
    rx_imp  = new("rx_imp", this);
  endfunction

  // The test tells the scoreboard which TXDATA writes were accepted: writes
  // only while TXFULL = 0 (uart tests poll STATUS). Writes to TXDATA while the
  // scoreboard is disabled (random bus tests) are not expected on the pin.
  function void write_cpu(axil_item t);
    if (!enabled || t.resp != axil_pkg::AXI_RESP_OKAY) return;
    if (t.addr == soc_pkg::UART_BASE + 32'(soc_pkg::UART_TXDATA) && t.write && t.strb[0])
      exp_tx.push_back(t.data[7:0]);
    if (t.addr == soc_pkg::UART_BASE + 32'(soc_pkg::UART_RXDATA) && !t.write && !t.rdata[31]) begin
      if (exp_rx.size() == 0)
        `uvm_error("UART_SB", $sformatf("RXDATA returned %02h, nothing was sent", t.rdata[7:0]))
      else begin
        logic [7:0] e = exp_rx.pop_front();
        if (e != t.rdata[7:0])
          `uvm_error("UART_SB", $sformatf("RXDATA %02h, the agent sent %02h", t.rdata[7:0], e))
        n_rx++;
      end
    end
  endfunction

  function void write_uart_tx(uart_item t);
    if (!enabled) return;
    if (exp_tx.size() == 0) `uvm_error("UART_SB", $sformatf("unexpected byte %02h on TX", t.data))
    else begin
      logic [7:0] e = exp_tx.pop_front();
      if (e != t.data) `uvm_error("UART_SB", $sformatf("TX byte %02h, TXDATA was %02h", t.data, e))
      n_tx++;
    end
  endfunction

  function void write_uart_rx(uart_item t);
    if (enabled) exp_rx.push_back(t.data);
  endfunction

  function void check_phase(uvm_phase phase);
    if (exp_tx.size() != 0) `uvm_error("UART_SB", $sformatf("%0d TXDATA bytes never transmitted", exp_tx.size()))
    if (exp_rx.size() != 0) `uvm_error("UART_SB", $sformatf("%0d sent bytes never read", exp_rx.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("UART_SB", $sformatf("%0d TX bytes and %0d RX bytes checked", n_tx, n_rx), UVM_LOW)
  endfunction
endclass

class spi_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(spi_scoreboard)

  uvm_analysis_imp_cpu #(axil_item, spi_scoreboard) cpu_imp;
  uvm_analysis_imp_spi #(spi_frame, spi_scoreboard) spi_imp;

  logic [7:0] exp_mosi[$], exp_rx[$];
  int         n_frames, n_rx;
  bit         enabled = 1;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cpu_imp = new("cpu_imp", this);
    spi_imp = new("spi_imp", this);
  endfunction

  function void write_cpu(axil_item t);
    if (!enabled || t.resp != axil_pkg::AXI_RESP_OKAY) return;
    if (t.addr == soc_pkg::SPI_BASE + 32'(soc_pkg::SPI_TXDATA) && t.write && t.strb[0])
      exp_mosi.push_back(t.data[7:0]);
    if (t.addr == soc_pkg::SPI_BASE + 32'(soc_pkg::SPI_RXDATA) && !t.write && !t.rdata[31]) begin
      if (exp_rx.size() == 0)
        `uvm_error("SPI_SB", $sformatf("RXDATA returned %02h without a frame", t.rdata[7:0]))
      else begin
        logic [7:0] e = exp_rx.pop_front();
        if (e != t.rdata[7:0])
          `uvm_error("SPI_SB", $sformatf("RXDATA %02h, MISO carried %02h", t.rdata[7:0], e))
        n_rx++;
      end
    end
  endfunction

  function void write_spi(spi_frame f);
    if (!enabled) return;
    if (exp_mosi.size() == 0) `uvm_error("SPI_SB", $sformatf("unexpected %s", f.convert2string()))
    else begin
      logic [7:0] e = exp_mosi.pop_front();
      if (e != f.mosi) `uvm_error("SPI_SB", $sformatf("%s, TXDATA was %02h", f.convert2string(), e))
      n_frames++;
    end
    exp_rx.push_back(f.miso);
  endfunction

  function void check_phase(uvm_phase phase);
    if (exp_mosi.size() != 0) `uvm_error("SPI_SB", $sformatf("%0d TXDATA bytes never sent", exp_mosi.size()))
    if (exp_rx.size() != 0) `uvm_error("SPI_SB", $sformatf("%0d received bytes never read", exp_rx.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SPI_SB", $sformatf("%0d frames and %0d RX bytes checked", n_frames, n_rx), UVM_LOW)
  endfunction
endclass

// ---------------------------------------------------------------------------
// Coverage: named bins with hit counts
// ---------------------------------------------------------------------------
class periph_cov extends uvm_component;
  `uvm_component_utils(periph_cov)

  uvm_analysis_imp_cpu #(axil_item, periph_cov)     cpu_imp;
  uvm_analysis_imp_uart_tx #(uart_item, periph_cov) utx_imp;
  uvm_analysis_imp_uart_rx #(uart_item, periph_cov) urx_imp;
  uvm_analysis_imp_spi #(spi_frame, periph_cov)     spi_imp;

  int unsigned cnt[string];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cpu_imp = new("cpu_imp", this);
    utx_imp = new("utx_imp", this);
    urx_imp = new("urx_imp", this);
    spi_imp = new("spi_imp", this);
  endfunction

  // Every bin exists from the start, so a hole shows as 0.
  function void build_phase(uvm_phase phase);
    string regions[6] = '{"mem", "clint", "plic", "uart", "spi", "unmapped"};
    super.build_phase(phase);
    foreach (regions[i]) begin
      cnt[{"axi.read.", regions[i]}]  = 0;
      cnt[{"axi.write.", regions[i]}] = 0;
    end
    cnt["axi.resp.read.okay"] = 0;   cnt["axi.resp.read.slverr"] = 0;
    cnt["axi.resp.write.okay"] = 0;  cnt["axi.resp.write.slverr"] = 0;
    cnt["axi.strb.word"] = 0; cnt["axi.strb.half"] = 0; cnt["axi.strb.byte"] = 0;
    cnt["axi.order.together"] = 0; cnt["axi.order.aw_first"] = 0; cnt["axi.order.w_first"] = 0;
    cnt["uart.tx.len.short"] = 0; cnt["uart.tx.len.mid"] = 0; cnt["uart.tx.len.long"] = 0;
    cnt["uart.rx.len.short"] = 0; cnt["uart.rx.len.mid"] = 0; cnt["uart.rx.len.long"] = 0;
    cnt["uart.data.00"] = 0; cnt["uart.data.ff"] = 0; cnt["uart.data.other"] = 0;
    for (int m = 0; m < 4; m++)
      for (int l = 0; l < 2; l++) cnt[$sformatf("spi.mode%0d.%s", m, (l != 0) ? "lsb" : "msb")] = 0;
  endfunction

  function void hit(string b);
    if (!cnt.exists(b)) cnt[b] = 0;
    cnt[b]++;
  endfunction

  function void write_cpu(axil_item t);
    string rn[6] = '{"mem", "clint", "plic", "uart", "spi", "unmapped"};
    hit({t.write ? "axi.write." : "axi.read.", rn[int'(region_of(t.addr))]});
    hit({"axi.resp.", t.write ? "write." : "read.", t.resp[1] ? "slverr" : "okay"});
    if (t.write) begin
      if (t.strb == 4'b1111)                          hit("axi.strb.word");
      else if (t.strb == 4'b0011 || t.strb == 4'b1100) hit("axi.strb.half");
      else if ($countones(t.strb) == 1)               hit("axi.strb.byte");
      case (t.order)
        AXIL_TOGETHER: hit("axi.order.together");
        AXIL_AW_FIRST: hit("axi.order.aw_first");
        default:       hit("axi.order.w_first");
      endcase
    end
  endfunction

  function string len_class(int unsigned l);
    return (l < 8) ? "short" : (l < 32) ? "mid" : "long";
  endfunction

  function void data_bin(logic [7:0] d);
    hit(d == 8'h00 ? "uart.data.00" : d == 8'hFF ? "uart.data.ff" : "uart.data.other");
  endfunction

  function void write_uart_tx(uart_item t);
    hit({"uart.tx.len.", len_class(t.bit_len)});
    data_bin(t.data);
  endfunction

  function void write_uart_rx(uart_item t);
    hit({"uart.rx.len.", len_class(t.bit_len)});
    data_bin(t.data);
  endfunction

  function void write_spi(spi_frame f);
    hit($sformatf("spi.mode%0d.%s", {f.cpol, f.cpha}, f.lsb ? "lsb" : "msb"));
  endfunction

  function void report_phase(uvm_phase phase);
    string json, file;
    int    n_hit;
    foreach (cnt[b]) if (cnt[b] != 0) n_hit++;
    `uvm_info("COV", $sformatf("%0d of %0d coverage bins hit", n_hit, cnt.size()), UVM_LOW)
    json = "{";
    foreach (cnt[b]) json = {json, $sformatf("%s\"%s\": %0d", json == "{" ? "" : ", ", b, cnt[b])};
    json = {json, "}"};
    if ($value$plusargs("uvm_cov_json=%s", file)) begin
      int fd = $fopen(file, "w");
      if (fd != 0) begin
        $fdisplay(fd, "%s", json);
        $fclose(fd);
      end
    end
  endfunction
endclass
