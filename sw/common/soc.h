// =============================================================================
// soc.h - SoC memory map and peripheral registers
// -----------------------------------------------------------------------------
// Mirrors rtl/pkg/soc_pkg.sv and docs/memory_map.md (CLAUDE.md 5.4, 5.5);
// change all three together. Usable from C and assembly.
// =============================================================================
#ifndef SOC_H
#define SOC_H

// ---- Memory map ---------------------------------------------------------------
#define CLINT_BASE        0x02000000u
#define PLIC_BASE         0x0C000000u
#define UART_BASE         0x10000000u
#define SPI_BASE          0x10001000u
#define MEM_BASE          0x80000000u
#define MEM_SIZE          0x00010000u

// ---- CLINT ----------------------------------------------------------------------
#define CLINT_MSIP        0x0000u
#define CLINT_MTIMECMP    0x4000u
#define CLINT_MTIMECMPH   0x4004u
#define CLINT_MTIME       0xBFF8u
#define CLINT_MTIMEH      0xBFFCu
#define MTIME_PRESCALE    4u          // clock cycles per mtime tick

// ---- PLIC (2 sources, 1 context) -----------------------------------------------
#define PLIC_PRIORITY(id) (0x000000u + 4u * (id))
#define PLIC_PENDING      0x001000u
#define PLIC_ENABLE       0x002000u
#define PLIC_THRESHOLD    0x200000u
#define PLIC_CLAIM        0x200004u   // read: claim, write: complete
#define PLIC_SRC_UART     1u
#define PLIC_SRC_SPI      2u

// ---- UART -------------------------------------------------------------------------
#define UART_TXDATA       0x00u
#define UART_RXDATA       0x04u
#define UART_STATUS       0x08u
#define UART_CTRL         0x0Cu
#define UART_BAUDDIV      0x10u
#define UART_IE           0x14u
#define UART_FIFO_DEPTH   8u
#define UART_ST_TXFULL    (1u << 0)
#define UART_ST_TXEMPTY   (1u << 1)
#define UART_ST_RXVALID   (1u << 2)
#define UART_ST_RXOVR     (1u << 3)   // sticky, write 1 to clear
#define UART_ST_TXOVF     (1u << 4)   // sticky, write 1 to clear
#define UART_ST_FRAMERR   (1u << 5)   // sticky, write 1 to clear
#define UART_CTRL_TXEN    (1u << 0)
#define UART_CTRL_RXEN    (1u << 1)
#define UART_IE_RX        (1u << 0)
#define UART_IE_TXEMPTY   (1u << 1)

// ---- SPI master ---------------------------------------------------------------
#define SPI_TXDATA        0x00u
#define SPI_RXDATA        0x04u
#define SPI_STATUS        0x08u
#define SPI_CTRL          0x0Cu
#define SPI_CLKDIV        0x10u
#define SPI_CS            0x14u
#define SPI_IE            0x18u
#define SPI_FIFO_DEPTH    4u
#define SPI_ST_BUSY       (1u << 0)
#define SPI_ST_TXFULL     (1u << 1)
#define SPI_ST_RXVALID    (1u << 2)
#define SPI_ST_RXOVR      (1u << 3)
#define SPI_ST_TXOVF      (1u << 4)
#define SPI_CTRL_EN       (1u << 0)
#define SPI_CTRL_CPOL     (1u << 1)
#define SPI_CTRL_CPHA     (1u << 2)
#define SPI_CTRL_LSBFIRST (1u << 3)
#define SPI_IE_RX         (1u << 0)
#define SPI_IE_IDLE       (1u << 1)

// RXDATA of the UART and SPI: bit 31 = the FIFO was empty
#define RXDATA_EMPTY      (1u << 31)

#endif
