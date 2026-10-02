// =============================================================================
// soc_pkg
// -----------------------------------------------------------------------------
// Purpose    : SoC-level constants: reset vector, system memory map and
//              cacheability boundary. This is the single source of truth for
//              the memory map (CLAUDE.md §5.4); docs/memory_map.md and the C
//              header in sw/common mirror it and must be kept in sync.
// Interfaces : none (package).
// Timing     : n/a.
//
// Peripheral register offsets are added alongside each peripheral (Phase 6).
// =============================================================================
package soc_pkg;

  // Waiver: a package is a catalogue of constants; not every constant is
  // referenced by every module or build configuration, so UNUSEDPARAM is
  // noise here. It stays enabled for parameters declared inside modules.
  /* verilator lint_off UNUSEDPARAM */

  localparam int unsigned ADDR_W = 32;

  typedef logic [ADDR_W-1:0] addr_t;

  // ---------------------------------------------------------------------------
  // Memory map: base addresses and region sizes in bytes
  // ---------------------------------------------------------------------------
  localparam addr_t CLINT_BASE = 32'h0200_0000;
  localparam addr_t CLINT_SIZE = 32'h0001_0000;  // 64 KB

  localparam addr_t PLIC_BASE  = 32'h0C00_0000;
  localparam addr_t PLIC_SIZE  = 32'h0040_0000;  // 4 MB

  localparam addr_t UART_BASE  = 32'h1000_0000;
  localparam addr_t UART_SIZE  = 32'h0000_1000;  // 4 KB

  localparam addr_t SPI_BASE   = 32'h1000_1000;
  localparam addr_t SPI_SIZE   = 32'h0000_1000;  // 4 KB

  localparam addr_t MEM_BASE   = 32'h8000_0000;  // main memory (external AXI4-Lite port)
  localparam addr_t MEM_SIZE   = 32'h0001_0000;  // 64 KB

  // Reserved, simulation only (D-029): the core testbench's sim_ctrl device
  // (interrupt lines, acknowledge/force registers). The SoC never decodes this
  // window, so on real hardware an access to it is an access fault.
  localparam addr_t SIMCTRL_BASE = 32'h4000_0000;
  localparam addr_t SIMCTRL_SIZE = 32'h0000_1000;  // 4 KB

  // ---------------------------------------------------------------------------
  // Reset and cacheability
  // ---------------------------------------------------------------------------
  // The core boots from the start of main memory.
  localparam addr_t RESET_PC = MEM_BASE;

  // Every address below this boundary bypasses the D-cache; all MMIO lives
  // there.
  localparam addr_t CACHEABLE_BASE = 32'h8000_0000;

  // ---------------------------------------------------------------------------
  // Caches (CLAUDE.md 5.3, docs/architecture.md P4)
  // ---------------------------------------------------------------------------
  localparam int unsigned CACHE_BYTES      = 2048;  // per cache
  localparam int unsigned CACHE_LINE_BYTES = 16;
  localparam int unsigned WBUF_DEPTH       = 2;     // D-cache write buffer entries
  localparam int unsigned WBUF_MAX_OUT     = 1;     // write buffer writes awaiting a response (P4.3)

  // ---------------------------------------------------------------------------
  // System bus (docs/architecture.md P5.1): AXI4-Lite slave ports of the
  // interconnect and APB slave slots of the bridge
  // ---------------------------------------------------------------------------
  localparam int unsigned AXI_SLV_MEM = 0;       // external main-memory port
  localparam int unsigned AXI_SLV_APB = 1;       // axil2apb
  localparam int unsigned AXI_NSLV    = 2;

  localparam int unsigned APB_SLV_CLINT = 0;
  localparam int unsigned APB_SLV_PLIC  = 1;
  localparam int unsigned APB_SLV_UART  = 2;
  localparam int unsigned APB_SLV_SPI   = 3;
  localparam int unsigned APB_NSLV      = 4;

  // Interconnect decode rules {base, size, port}, one per memory-map region.
  // Index 0 is the least significant element of each packed array.
  localparam int unsigned                BUS_NRULES    = 5;
  localparam logic [BUS_NRULES-1:0][31:0] BUS_RULE_BASE = {SPI_BASE, UART_BASE, PLIC_BASE, CLINT_BASE, MEM_BASE};
  localparam logic [BUS_NRULES-1:0][31:0] BUS_RULE_SIZE = {SPI_SIZE, UART_SIZE, PLIC_SIZE, CLINT_SIZE, MEM_SIZE};
  localparam logic [BUS_NRULES-1:0][7:0]  BUS_RULE_PORT = {8'(AXI_SLV_APB), 8'(AXI_SLV_APB), 8'(AXI_SLV_APB),
                                                           8'(AXI_SLV_APB), 8'(AXI_SLV_MEM)};

  // APB windows, indexed by APB_SLV_*
  localparam logic [APB_NSLV-1:0][31:0] APB_BASE = {SPI_BASE, UART_BASE, PLIC_BASE, CLINT_BASE};
  localparam logic [APB_NSLV-1:0][31:0] APB_SIZE = {SPI_SIZE, UART_SIZE, PLIC_SIZE, CLINT_SIZE};

  // ---------------------------------------------------------------------------
  // Peripheral registers (docs/architecture.md P6, docs/memory_map.md,
  // sw/common/soc.h). Offsets are relative to each peripheral's base.
  // ---------------------------------------------------------------------------
  // CLINT
  localparam logic [15:0] CLINT_MSIP      = 16'h0000;
  localparam logic [15:0] CLINT_MTIMECMP  = 16'h4000;
  localparam logic [15:0] CLINT_MTIMECMPH = 16'h4004;
  localparam logic [15:0] CLINT_MTIME     = 16'hBFF8;
  localparam logic [15:0] CLINT_MTIMEH    = 16'hBFFC;
  localparam int unsigned MTIME_PRESCALE  = 4;       // clock cycles per mtime tick

  // PLIC: 2 sources, 1 context
  localparam logic [21:0] PLIC_PRIORITY1  = 22'h00_0004;
  localparam logic [21:0] PLIC_PRIORITY2  = 22'h00_0008;
  localparam logic [21:0] PLIC_PENDING    = 22'h00_1000;
  localparam logic [21:0] PLIC_ENABLE     = 22'h00_2000;
  localparam logic [21:0] PLIC_THRESHOLD  = 22'h20_0000;
  localparam logic [21:0] PLIC_CLAIM      = 22'h20_0004;
  localparam int unsigned PLIC_NSRC       = 2;
  localparam int unsigned PLIC_PRIO_W     = 3;
  localparam int unsigned PLIC_SRC_UART   = 1;
  localparam int unsigned PLIC_SRC_SPI    = 2;

  // UART
  localparam logic [11:0] UART_TXDATA     = 12'h000;
  localparam logic [11:0] UART_RXDATA     = 12'h004;
  localparam logic [11:0] UART_STATUS     = 12'h008;
  localparam logic [11:0] UART_CTRL       = 12'h00C;
  localparam logic [11:0] UART_BAUDDIV    = 12'h010;
  localparam logic [11:0] UART_IE         = 12'h014;
  localparam int unsigned UART_FIFO_DEPTH = 8;
  localparam logic [15:0] UART_BAUDDIV_RESET = 16'd16;

  // SPI master
  localparam logic [11:0] SPI_TXDATA      = 12'h000;
  localparam logic [11:0] SPI_RXDATA      = 12'h004;
  localparam logic [11:0] SPI_STATUS      = 12'h008;
  localparam logic [11:0] SPI_CTRL        = 12'h00C;
  localparam logic [11:0] SPI_CLKDIV      = 12'h010;
  localparam logic [11:0] SPI_CS          = 12'h014;
  localparam logic [11:0] SPI_IE          = 12'h018;
  localparam int unsigned SPI_FIFO_DEPTH  = 4;
  localparam logic [15:0] SPI_CLKDIV_RESET = 16'd4;

  // Field positions shared by UART and SPI
  localparam int unsigned RXDATA_EMPTY = 31;     // RXDATA: FIFO was empty
  localparam int unsigned ST_RXOVR     = 3;      // STATUS, sticky W1C
  localparam int unsigned ST_TXOVF     = 4;      // STATUS, sticky W1C
  // UART STATUS
  localparam int unsigned UART_ST_TXFULL  = 0;
  localparam int unsigned UART_ST_TXEMPTY = 1;
  localparam int unsigned UART_ST_RXVALID = 2;
  localparam int unsigned UART_ST_FRAMERR = 5;   // sticky W1C
  // SPI STATUS and CTRL
  localparam int unsigned SPI_ST_BUSY     = 0;
  localparam int unsigned SPI_ST_TXFULL   = 1;
  localparam int unsigned SPI_ST_RXVALID  = 2;
  localparam int unsigned SPI_CTRL_EN       = 0;
  localparam int unsigned SPI_CTRL_CPOL     = 1;
  localparam int unsigned SPI_CTRL_CPHA     = 2;
  localparam int unsigned SPI_CTRL_LSBFIRST = 3;

  /* verilator lint_on UNUSEDPARAM */

endpackage : soc_pkg
