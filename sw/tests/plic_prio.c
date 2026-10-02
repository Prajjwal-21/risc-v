// =============================================================================
// plic_prio.c - PLIC priority, tie-break, threshold, enable, gateway (P6.7)
// -----------------------------------------------------------------------------
// Both sources are held high without interrupts enabled in the core: the UART
// TX-empty interrupt (TX idle) is source 1, the SPI idle interrupt source 2.
// Claims are made by polling. Returns 0 on success, otherwise the number of
// the failing check.
//   1  both pending; PENDING shows bits 1 and 2; mip.MEIP set
//   2  priorities 2 (UART) < 3 (SPI): claims return 2, then 1, then 0
//   3  completing one of two claimed sources ends only its service: it is
//      pending again (still high), the other is not; after the second
//      complete both are pending
//   4  equal priorities: the lower ID (1) is claimed first
//   5  threshold 2: only the priority-3 source is claimed
//   6  source 1 disabled: never claimed; MEIP follows enable and threshold
//   7  priority 0 never interrupts
//   8  an offset with no register (0x0) raises a store access fault
// =============================================================================
#include "hal.h"

static volatile uint32_t fault_cause, fault_tval;

static uint32_t on_fault(uint32_t cause, uint32_t epc, uint32_t tval) {
  fault_cause = cause;
  fault_tval = tval;
  return epc + 4;
}

static void settle(void) { for (volatile int i = 0; i < 8; i++) { } }

static void drain(void) {                  // claim and complete everything
  for (int i = 0; i < 4; i++) {
    uint32_t id = plic_claim();
    if (!id) break;
    plic_complete(id);
  }
}

int main(void) {
  plic_set_threshold(0);
  plic_set_enable((1u << PLIC_SRC_UART) | (1u << PLIC_SRC_SPI));
  plic_set_priority(PLIC_SRC_UART, 2);
  plic_set_priority(PLIC_SRC_SPI, 3);
  mmio_write(UART_BASE + UART_IE, UART_IE_TXEMPTY);   // UART TX idle: high
  mmio_write(SPI_BASE + SPI_IE, SPI_IE_IDLE);         // SPI idle: high
  settle();

  // 1
  if (plic_pending() != ((1u << PLIC_SRC_UART) | (1u << PLIC_SRC_SPI))) return 1;
  if (!(csr_read(mip) & MIP_MEIP)) return 1;

  // 2
  if (plic_claim() != PLIC_SRC_SPI) return 2;
  if (plic_claim() != PLIC_SRC_UART) return 2;
  if (plic_claim() != 0) return 2;
  settle();
  if (csr_read(mip) & MIP_MEIP) return 2;              // both in service

  // 3
  plic_complete(PLIC_SRC_SPI);
  settle();
  if (plic_pending() != (1u << PLIC_SRC_SPI)) return 3;
  plic_complete(PLIC_SRC_UART);
  settle();
  if (plic_pending() != ((1u << PLIC_SRC_UART) | (1u << PLIC_SRC_SPI))) return 3;

  // 4: tie
  plic_set_priority(PLIC_SRC_SPI, 2);
  if (plic_claim() != PLIC_SRC_UART) return 4;
  if (plic_claim() != PLIC_SRC_SPI) return 4;
  plic_complete(PLIC_SRC_UART);
  plic_complete(PLIC_SRC_SPI);
  settle();

  // 5: threshold
  plic_set_priority(PLIC_SRC_SPI, 3);
  plic_set_threshold(2);
  if (plic_claim() != PLIC_SRC_SPI) return 5;
  if (plic_claim() != 0) return 5;
  plic_complete(PLIC_SRC_SPI);
  settle();

  // 6: enable
  plic_set_threshold(0);
  plic_set_enable(1u << PLIC_SRC_SPI);
  if (plic_claim() != PLIC_SRC_SPI) return 6;
  if (plic_claim() != 0) return 6;
  settle();
  if (csr_read(mip) & MIP_MEIP) return 6;              // source 1 pending but disabled
  plic_complete(PLIC_SRC_SPI);
  settle();
  if (!(csr_read(mip) & MIP_MEIP)) return 6;
  plic_set_threshold(3);
  settle();
  if (csr_read(mip) & MIP_MEIP) return 6;              // priority 3 not above 3
  plic_set_threshold(0);

  // 7: priority 0
  plic_set_enable((1u << PLIC_SRC_UART) | (1u << PLIC_SRC_SPI));
  plic_set_priority(PLIC_SRC_UART, 0);
  plic_set_priority(PLIC_SRC_SPI, 0);
  if (plic_claim() != 0) return 7;
  settle();
  if (csr_read(mip) & MIP_MEIP) return 7;

  // Clean up: sources low, nothing in service
  mmio_write(UART_BASE + UART_IE, 0);
  mmio_write(SPI_BASE + SPI_IE, 0);
  plic_set_priority(PLIC_SRC_UART, 1);
  plic_set_priority(PLIC_SRC_SPI, 1);
  drain();

  // 8: offset 0 (the nonexistent source 0's priority)
  trap_set_exc_handler(on_fault);
  mmio_write(PLIC_BASE + 0x0, 1);
  if (fault_cause != CAUSE_STORE_ACCESS || fault_tval != PLIC_BASE) return 8;
  return 0;
}
