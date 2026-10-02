// =============================================================================
// periph_ral.svh - register model of the CLINT, PLIC, UART and SPI
// -----------------------------------------------------------------------------
// docs/architecture.md P6 (register maps, also docs/memory_map.md) and P7.2.
// Every register of every peripheral is modelled. Registers whose reads or
// writes have side effects the built-in sequences cannot predict carry the
// NO_REG_TESTS attribute (or the narrower NO_REG_BIT_BASH_TEST):
//   TXDATA (a write transmits), RXDATA (a read pops), CLAIM (a read claims),
//   PENDING and STATUS (hardware-driven), MTIME/MTIMEH (counting), SPI CS and
//   CTRL (bit-bashing them clocks SCLK edges at the slave with CS asserted).
// =============================================================================

// One 32-bit register with fields added by add_field().
class preg extends uvm_reg;
  `uvm_object_utils(preg)

  uvm_reg_field fields[$];

  function new(string name = "preg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  function void add_field(string fname, int unsigned width, int unsigned lsb, string access,
                          logic [31:0] reset, bit is_volatile = 0);
    uvm_reg_field f = uvm_reg_field::type_id::create(fname);
    f.configure(this, width, lsb, access, is_volatile, uvm_reg_data_t'(reset), 1, 0, 0);
    fields.push_back(f);
  endfunction
endclass

// A block of pregs; build() adds them from a table.
class pblock extends uvm_reg_block;
  `uvm_object_utils(pblock)

  preg regs[string];

  function new(string name = "pblock");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  function preg add(string rname, uvm_reg_addr_t offset, string rights = "RW");
    preg r = preg::type_id::create(rname);
    r.configure(this, null, "");
    regs[rname] = r;
    default_map.add_reg(r, offset, rights);
    return r;
  endfunction

  function void no_tests(string rname, bit only_bit_bash = 0);
    uvm_resource_db#(bit)::set({"REG::", regs[rname].get_full_name()},
                               only_bit_bash ? "NO_REG_BIT_BASH_TEST" : "NO_REG_TESTS", 1, this);
  endfunction
endclass

class clint_block extends pblock;
  `uvm_object_utils(clint_block)
  function new(string name = "clint_block");
    super.new(name);
  endfunction
  virtual function void build();
    preg r;
    default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN);
    r = add("msip",      'h0000); r.add_field("msip", 1, 0, "RW", 0);
    r = add("mtimecmp",  'h4000); r.add_field("value", 32, 0, "RW", 32'hFFFF_FFFF);
    r = add("mtimecmph", 'h4004); r.add_field("value", 32, 0, "RW", 32'hFFFF_FFFF);
    r = add("mtime",     'hBFF8); r.add_field("value", 32, 0, "RW", 0, 1);
    r = add("mtimeh",    'hBFFC); r.add_field("value", 32, 0, "RW", 0, 1);
    no_tests("mtime");
    no_tests("mtimeh");
  endfunction
endclass

class plic_block extends pblock;
  `uvm_object_utils(plic_block)
  function new(string name = "plic_block");
    super.new(name);
  endfunction
  virtual function void build();
    preg r;
    default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN);
    r = add("priority1", 'h00_0004); r.add_field("prio", 3, 0, "RW", 0);
    r = add("priority2", 'h00_0008); r.add_field("prio", 3, 0, "RW", 0);
    r = add("pending",   'h00_1000, "RO"); r.add_field("ip", 2, 1, "RO", 0, 1);
    r = add("enable",    'h00_2000); r.add_field("ie", 2, 1, "RW", 0);
    r = add("threshold", 'h20_0000); r.add_field("thr", 3, 0, "RW", 0);
    r = add("claim",     'h20_0004); r.add_field("id", 32, 0, "RW", 0, 1);
    no_tests("pending");
    no_tests("claim");
  endfunction
endclass

class uart_block extends pblock;
  `uvm_object_utils(uart_block)
  function new(string name = "uart_block");
    super.new(name);
  endfunction
  virtual function void build();
    preg r;
    default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN);
    r = add("txdata",  'h00, "WO"); r.add_field("data", 8, 0, "WO", 0);
    r = add("rxdata",  'h04, "RO"); r.add_field("data", 8, 0, "RO", 0, 1);
                                    r.add_field("empty", 1, 31, "RO", 1, 1);
    r = add("status",  'h08);       r.add_field("txfull", 1, 0, "RO", 0, 1);
                                    r.add_field("txempty", 1, 1, "RO", 1, 1);
                                    r.add_field("rxvalid", 1, 2, "RO", 0, 1);
                                    r.add_field("rxovr", 1, 3, "W1C", 0, 1);
                                    r.add_field("txovf", 1, 4, "W1C", 0, 1);
                                    r.add_field("framerr", 1, 5, "W1C", 0, 1);
    r = add("ctrl",    'h0C);       r.add_field("txen", 1, 0, "RW", 0);
                                    r.add_field("rxen", 1, 1, "RW", 0);
    r = add("bauddiv", 'h10);       r.add_field("div", 16, 0, "RW", 16);
    r = add("ie",      'h14);       r.add_field("rx", 1, 0, "RW", 0);
                                    r.add_field("txempty", 1, 1, "RW", 0);
    no_tests("txdata");
    no_tests("rxdata");
    no_tests("status");
  endfunction
endclass

class spi_block extends pblock;
  `uvm_object_utils(spi_block)
  function new(string name = "spi_block");
    super.new(name);
  endfunction
  virtual function void build();
    preg r;
    default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN);
    r = add("txdata", 'h00, "WO"); r.add_field("data", 8, 0, "WO", 0);
    r = add("rxdata", 'h04, "RO"); r.add_field("data", 8, 0, "RO", 0, 1);
                                   r.add_field("empty", 1, 31, "RO", 1, 1);
    r = add("status", 'h08);       r.add_field("busy", 1, 0, "RO", 0, 1);
                                   r.add_field("txfull", 1, 1, "RO", 0, 1);
                                   r.add_field("rxvalid", 1, 2, "RO", 0, 1);
                                   r.add_field("rxovr", 1, 3, "W1C", 0, 1);
                                   r.add_field("txovf", 1, 4, "W1C", 0, 1);
    r = add("ctrl",   'h0C);       r.add_field("en", 1, 0, "RW", 0);
                                   r.add_field("cpol", 1, 1, "RW", 0);
                                   r.add_field("cpha", 1, 2, "RW", 0);
                                   r.add_field("lsbfirst", 1, 3, "RW", 0);
    r = add("clkdiv", 'h10);       r.add_field("div", 16, 0, "RW", 4);
    r = add("cs",     'h14);       r.add_field("cs", 1, 0, "RW", 0);
    r = add("ie",     'h18);       r.add_field("rx", 1, 0, "RW", 0);
                                   r.add_field("idle", 1, 1, "RW", 0);
    no_tests("txdata");
    no_tests("rxdata");
    no_tests("status");
    no_tests("ctrl", 1);
    no_tests("cs", 1);
  endfunction
endclass

class soc_reg_block extends uvm_reg_block;
  `uvm_object_utils(soc_reg_block)

  clint_block clint;
  plic_block  plic;
  uart_block  uart;
  spi_block   spi;

  function new(string name = "soc_reg_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN);
    clint = clint_block::type_id::create("clint");
    plic  = plic_block::type_id::create("plic");
    uart  = uart_block::type_id::create("uart");
    spi   = spi_block::type_id::create("spi");
    clint.configure(this);
    plic.configure(this);
    uart.configure(this);
    spi.configure(this);
    clint.build();
    plic.build();
    uart.build();
    spi.build();
    default_map.add_submap(clint.default_map, uvm_reg_addr_t'(soc_pkg::CLINT_BASE));
    default_map.add_submap(plic.default_map,  uvm_reg_addr_t'(soc_pkg::PLIC_BASE));
    default_map.add_submap(uart.default_map,  uvm_reg_addr_t'(soc_pkg::UART_BASE));
    default_map.add_submap(spi.default_map,   uvm_reg_addr_t'(soc_pkg::SPI_BASE));
    lock_model();
  endfunction
endclass
