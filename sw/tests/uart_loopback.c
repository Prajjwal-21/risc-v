// =============================================================================
// uart_loopback.c - UART 8N1 loopback, FIFOs and RX interrupt (P6.7)
// -----------------------------------------------------------------------------
// The testbench wires TX to RX. Returns 0 on success, otherwise the number of
// the failing check.
//   1  8 bytes sent by polling come back in order (BAUDDIV = 8)
//   2  the same at an odd bit length (BAUDDIV = 21)
//   3  TX disabled: 8 writes fill the FIFO (TXFULL), a 9th is dropped and
//      sets TXOVF (W1C clears it); enabling TX sends the 8, in order
//   4  9 bytes arrive unread: the 9th is dropped and RXOVR set; the FIFO
//      holds the first 8
//   5  RX interrupt through the PLIC: one byte -> one interrupt, claim = 1;
//      two bytes with only one read per interrupt -> the source stays high
//      and is pending again after complete: two interrupts, bytes in order
//   6  TX-empty interrupt (IE[1]) is taken when TX is idle
//   7  an offset with no register (0x18) raises a load access fault
// =============================================================================
#include "hal.h"

#define SPIN 400000u

static volatile uint32_t ext_count, rx_bytes, last_claim, txe_count;
static volatile uint8_t  rx_buf[8];
static volatile uint32_t fault_cause, fault_tval;

static void ext_isr(void) {
  uint32_t id = plic_claim();
  last_claim = id;
  if (id == PLIC_SRC_UART) {
    uint32_t ie = mmio_read(UART_BASE + UART_IE);
    if (ie & UART_IE_TXEMPTY) {                     // check 6
      mmio_write(UART_BASE + UART_IE, ie & ~UART_IE_TXEMPTY);
      txe_count = txe_count + 1;
    } else {                                        // check 5: read ONE byte
      uint32_t v = mmio_read(UART_BASE + UART_RXDATA);
      if (!(v & RXDATA_EMPTY) && rx_bytes < 8) rx_buf[rx_bytes++] = (uint8_t)v;
    }
  }
  ext_count = ext_count + 1;
  plic_complete(id);
}

static uint32_t on_fault(uint32_t cause, uint32_t epc, uint32_t tval) {
  fault_cause = cause;
  fault_tval = tval;
  return epc + 4;
}

static int wait_status(uint32_t mask, uint32_t want) {
  for (uint32_t i = 0; i < SPIN; i++)
    if ((uart_status() & mask) == want) return 1;
  return 0;
}

static int echo(const uint8_t *b, int n) {
  for (int i = 0; i < n; i++) uart_putc((char)b[i]);
  for (int i = 0; i < n; i++)
    if (uart_getc_timeout(SPIN) != b[i]) return 0;
  return 1;
}

int main(void) {
  static const uint8_t msg[8] = {'H', 'i', ' ', 0x00, 0xFF, 0x55, 0xAA, '\n'};

  // 1, 2
  uart_init(8);
  if (!echo(msg, 8)) return 1;
  uart_init(21);
  if (!echo(msg, 8)) return 2;

  // 3: fill the TX FIFO with TX disabled
  mmio_write(UART_BASE + UART_CTRL, UART_CTRL_RXEN);
  for (int i = 0; i < 8; i++) mmio_write(UART_BASE + UART_TXDATA, 0x30 + i);
  if (!(uart_status() & UART_ST_TXFULL)) return 3;
  if (uart_status() & UART_ST_TXOVF) return 3;
  mmio_write(UART_BASE + UART_TXDATA, 0x7E);        // dropped
  if (!(uart_status() & UART_ST_TXOVF)) return 3;
  mmio_write(UART_BASE + UART_STATUS, UART_ST_TXOVF);
  if (uart_status() & UART_ST_TXOVF) return 3;
  mmio_write(UART_BASE + UART_CTRL, UART_CTRL_TXEN | UART_CTRL_RXEN);
  for (int i = 0; i < 8; i++)
    if (uart_getc_timeout(SPIN) != 0x30 + i) return 3;

  // 4: RX overrun
  for (int i = 0; i < 9; i++) uart_putc((char)(0x40 + i));
  if (!wait_status(UART_ST_TXEMPTY, UART_ST_TXEMPTY)) return 4;
  for (volatile int i = 0; i < 200; i++) { }         // the last frame's stop bit
  if (!(uart_status() & UART_ST_RXOVR)) return 4;
  for (int i = 0; i < 8; i++)
    if (uart_getc_timeout(10) != 0x40 + i) return 4;
  if (uart_getc_timeout(10) != -1) return 4;
  mmio_write(UART_BASE + UART_STATUS, UART_ST_RXOVR);
  if (uart_status() & UART_ST_RXOVR) return 4;

  // 5: RX interrupt through the PLIC
  trap_set_irq_handler(IRQ_M_EXT, ext_isr);
  plic_set_priority(PLIC_SRC_UART, 1);
  plic_set_enable(1u << PLIC_SRC_UART);
  plic_set_threshold(0);
  mmio_write(UART_BASE + UART_IE, UART_IE_RX);
  csr_set(mie, MIE_MEIE);
  irq_global_enable();
  uart_putc(0x5A);
  for (uint32_t i = 0; i < SPIN && ext_count < 1; i++) { }
  if (ext_count != 1 || last_claim != PLIC_SRC_UART || rx_bytes != 1 || rx_buf[0] != 0x5A) return 5;
  irq_global_disable();                              // queue two bytes, then take them
  uart_putc(0x11);
  uart_putc(0x22);
  if (!wait_status(UART_ST_TXEMPTY, UART_ST_TXEMPTY)) return 5;
  for (volatile int i = 0; i < 200; i++) { }
  irq_global_enable();
  for (uint32_t i = 0; i < SPIN && ext_count < 3; i++) { }
  if (ext_count != 3 || rx_bytes != 3 || rx_buf[1] != 0x11 || rx_buf[2] != 0x22) return 5;

  // 6: TX-empty interrupt
  mmio_write(UART_BASE + UART_IE, UART_IE_TXEMPTY);
  for (uint32_t i = 0; i < SPIN && txe_count < 1; i++) { }
  if (txe_count != 1) return 6;
  irq_global_disable();
  mmio_write(UART_BASE + UART_IE, 0);

  // 7: unmapped offset
  trap_set_exc_handler(on_fault);
  (void)mmio_read(UART_BASE + 0x18);
  if (fault_cause != CAUSE_LOAD_ACCESS || fault_tval != UART_BASE + 0x18) return 7;

  uart_puts("uart_loopback: all checks passed\n");
  if (!wait_status(UART_ST_TXEMPTY, UART_ST_TXEMPTY)) return 8;
  return 0;
}
