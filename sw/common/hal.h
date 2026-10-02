// =============================================================================
// hal.h - minimal hardware access layer for the SoC C tests
// -----------------------------------------------------------------------------
// MMIO and CSR access, and small helpers for the CLINT, PLIC, UART and SPI
// (docs/architecture.md P6). Header only; include soc.h's register map.
// =============================================================================
#ifndef HAL_H
#define HAL_H

#include <stdint.h>
#include "soc.h"

// ---- MMIO -----------------------------------------------------------------------
static inline void mmio_write(uint32_t addr, uint32_t v) { *(volatile uint32_t *)addr = v; }
static inline uint32_t mmio_read(uint32_t addr) { return *(volatile uint32_t *)addr; }

// ---- CSRs -----------------------------------------------------------------------
#define csr_read(csr) ({ uint32_t __v; __asm__ volatile ("csrr %0, " #csr : "=r"(__v)); __v; })
#define csr_write(csr, v) __asm__ volatile ("csrw " #csr ", %0" :: "rK"(v))
#define csr_set(csr, v)   __asm__ volatile ("csrs " #csr ", %0" :: "rK"(v))
#define csr_clear(csr, v) __asm__ volatile ("csrc " #csr ", %0" :: "rK"(v))

#define MSTATUS_MIE  (1u << 3)
#define MIE_MSIE     (1u << 3)
#define MIE_MTIE     (1u << 7)
#define MIE_MEIE     (1u << 11)
#define MIP_MSIP     (1u << 3)
#define MIP_MTIP     (1u << 7)
#define MIP_MEIP     (1u << 11)
#define IRQ_M_SOFT   3u
#define IRQ_M_TIMER  7u
#define IRQ_M_EXT    11u
#define MCAUSE_IRQ   (1u << 31)
#define CAUSE_LOAD_ACCESS  5u
#define CAUSE_STORE_ACCESS 7u

static inline void irq_global_enable(void)  { csr_set(mstatus, MSTATUS_MIE); }
static inline void irq_global_disable(void) { csr_clear(mstatus, MSTATUS_MIE); }
static inline void wfi(void) { __asm__ volatile ("wfi"); }

// ---- CLINT ----------------------------------------------------------------------
static inline uint64_t clint_mtime(void) {
  uint32_t hi, lo;
  do {                                    // re-read if the low word carried
    hi = mmio_read(CLINT_BASE + CLINT_MTIMEH);
    lo = mmio_read(CLINT_BASE + CLINT_MTIME);
  } while (hi != mmio_read(CLINT_BASE + CLINT_MTIMEH));
  return ((uint64_t)hi << 32) | lo;
}
// Writing the high word to all ones first avoids a spurious match in between.
static inline void clint_set_mtimecmp(uint64_t t) {
  mmio_write(CLINT_BASE + CLINT_MTIMECMPH, 0xFFFFFFFFu);
  mmio_write(CLINT_BASE + CLINT_MTIMECMP, (uint32_t)t);
  mmio_write(CLINT_BASE + CLINT_MTIMECMPH, (uint32_t)(t >> 32));
}
static inline void clint_set_msip(uint32_t v) { mmio_write(CLINT_BASE + CLINT_MSIP, v); }

// ---- PLIC -------------------------------------------------------------------------
static inline void plic_set_priority(uint32_t id, uint32_t p) { mmio_write(PLIC_BASE + PLIC_PRIORITY(id), p); }
static inline void plic_set_enable(uint32_t mask) { mmio_write(PLIC_BASE + PLIC_ENABLE, mask); }
static inline void plic_set_threshold(uint32_t t) { mmio_write(PLIC_BASE + PLIC_THRESHOLD, t); }
static inline uint32_t plic_pending(void) { return mmio_read(PLIC_BASE + PLIC_PENDING); }
static inline uint32_t plic_claim(void) { return mmio_read(PLIC_BASE + PLIC_CLAIM); }
static inline void plic_complete(uint32_t id) { mmio_write(PLIC_BASE + PLIC_CLAIM, id); }

// ---- UART -------------------------------------------------------------------------
static inline uint32_t uart_status(void) { return mmio_read(UART_BASE + UART_STATUS); }
static inline void uart_init(uint32_t bauddiv) {
  mmio_write(UART_BASE + UART_BAUDDIV, bauddiv);
  mmio_write(UART_BASE + UART_CTRL, UART_CTRL_TXEN | UART_CTRL_RXEN);
}
static inline void uart_putc(char c) {
  while (uart_status() & UART_ST_TXFULL) { }
  mmio_write(UART_BASE + UART_TXDATA, (uint8_t)c);
}
static inline void uart_puts(const char *s) { while (*s) uart_putc(*s++); }
// Returns the byte, or -1 if nothing arrives within `spins` polls.
static inline int uart_getc_timeout(uint32_t spins) {
  for (uint32_t i = 0; i < spins; i++) {
    uint32_t v = mmio_read(UART_BASE + UART_RXDATA);
    if (!(v & RXDATA_EMPTY)) return (int)(v & 0xFF);
  }
  return -1;
}

// ---- SPI --------------------------------------------------------------------------
static inline uint32_t spi_status(void) { return mmio_read(SPI_BASE + SPI_STATUS); }
static inline void spi_config(uint32_t ctrl, uint32_t clkdiv) {
  mmio_write(SPI_BASE + SPI_CLKDIV, clkdiv);
  mmio_write(SPI_BASE + SPI_CTRL, ctrl);
}
static inline void spi_cs(uint32_t on) { mmio_write(SPI_BASE + SPI_CS, on); }
static inline void spi_wait_idle(void) { while (spi_status() & SPI_ST_BUSY) { } }

// ---- Trap dispatch (trap.c) ----------------------------------------------------
typedef void (*irq_fn_t)(void);
// An exception handler returns the pc to resume at.
typedef uint32_t (*exc_fn_t)(uint32_t cause, uint32_t epc, uint32_t tval);
void trap_set_irq_handler(uint32_t cause, irq_fn_t fn);
void trap_set_exc_handler(exc_fn_t fn);
extern volatile uint32_t irq_handled;     // interrupts dispatched (the testbench checks it)

#endif
