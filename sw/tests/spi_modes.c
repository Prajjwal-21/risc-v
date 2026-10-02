// =============================================================================
// spi_modes.c - SPI master in all four modes, both bit orders (P6.7)
// -----------------------------------------------------------------------------
// The testbench's SPI slave takes its mode from CTRL and answers each frame
// with the complement of the previous byte it received (0x3C before the
// first). A frame corrupted in either direction, in any mode or bit order,
// shows up as a wrong byte here. Returns 0 on success, otherwise the number
// of the failing check.
//   1..8   mode m (0..3) x bit order (MSB, LSB first), check = 1 + 2m + lsb:
//          one CS transaction of 4 frames; every byte read back equals the
//          slave's rule; BUSY clear afterwards, nothing more in the RX FIFO
//   9      TX FIFO overflow: 5 writes with EN = 0 -> BUSY (bytes pending),
//          TXFULL, TXOVF (W1C); enabling sends the 4 queued bytes
//   10     RX interrupt through the PLIC: claim returns 2, the frame's byte
//          is read in the handler
//   11     RX overrun: 5 frames with nothing read -> RXOVR, 4 bytes kept
// =============================================================================
#include "hal.h"

#define SPIN 200000u

static uint8_t expect_next = 0x3C;       // the slave's next answer
static volatile uint32_t ext_count, last_claim;
static volatile uint32_t isr_byte;

static uint32_t read_rx(void) { return mmio_read(SPI_BASE + SPI_RXDATA); }

static void ext_isr(void) {
  uint32_t id = plic_claim();
  last_claim = id;
  if (id == PLIC_SRC_SPI) isr_byte = read_rx();
  ext_count = ext_count + 1;
  plic_complete(id);
}

// Sends n bytes in one CS transaction and checks each answer.
static int transfer(const uint8_t *tx, int n) {
  spi_cs(1);
  for (int i = 0; i < n; i++) mmio_write(SPI_BASE + SPI_TXDATA, tx[i]);
  spi_wait_idle();
  spi_cs(0);
  for (int i = 0; i < n; i++) {
    uint32_t v = read_rx();
    if (v & RXDATA_EMPTY) return 0;
    if ((uint8_t)v != expect_next) return 0;
    expect_next = (uint8_t)~tx[i];
  }
  if (!(read_rx() & RXDATA_EMPTY)) return 0;
  return 1;
}

int main(void) {
  // 1..8: every mode and bit order
  for (uint32_t mode = 0; mode < 4; mode++) {
    for (uint32_t lsb = 0; lsb < 2; lsb++) {
      uint32_t ctrl = SPI_CTRL_EN | (mode & 2 ? SPI_CTRL_CPOL : 0) | (mode & 1 ? SPI_CTRL_CPHA : 0)
                    | (lsb ? SPI_CTRL_LSBFIRST : 0);
      uint8_t tx[4] = {(uint8_t)(0x81 + 16 * mode + lsb), 0x42, (uint8_t)(0x0F ^ mode), 0xE7};
      spi_config(ctrl, 1 + (mode & 1) + lsb);     // CLKDIV 1..3
      if (!transfer(tx, 4)) return (int)(1 + 2 * mode + lsb);
    }
  }

  // 9: TX FIFO overflow with the engine disabled
  spi_config(0, 2);
  for (int i = 0; i < 4; i++) mmio_write(SPI_BASE + SPI_TXDATA, 0x10 + i);
  if (!(spi_status() & SPI_ST_TXFULL)) return 9;
  if (!(spi_status() & SPI_ST_BUSY)) return 9;
  mmio_write(SPI_BASE + SPI_TXDATA, 0x99);            // dropped
  if (!(spi_status() & SPI_ST_TXOVF)) return 9;
  mmio_write(SPI_BASE + SPI_STATUS, SPI_ST_TXOVF);
  if (spi_status() & SPI_ST_TXOVF) return 9;
  {                                                   // send the 4 queued bytes
    spi_cs(1);
    mmio_write(SPI_BASE + SPI_CTRL, SPI_CTRL_EN);
    spi_wait_idle();
    spi_cs(0);
    for (int i = 0; i < 4; i++) {
      uint32_t v = read_rx();
      if ((v & RXDATA_EMPTY) || (uint8_t)v != expect_next) return 9;
      expect_next = (uint8_t)~(0x10 + i);
    }
  }

  // 10: RX interrupt through the PLIC
  trap_set_irq_handler(IRQ_M_EXT, ext_isr);
  plic_set_priority(PLIC_SRC_SPI, 2);
  plic_set_enable(1u << PLIC_SRC_SPI);
  plic_set_threshold(0);
  mmio_write(SPI_BASE + SPI_IE, SPI_IE_RX);
  csr_set(mie, MIE_MEIE);
  irq_global_enable();
  spi_cs(1);
  mmio_write(SPI_BASE + SPI_TXDATA, 0x6D);
  for (uint32_t i = 0; i < SPIN && ext_count < 1; i++) { }
  spi_cs(0);
  if (ext_count != 1 || last_claim != PLIC_SRC_SPI) return 10;
  if ((isr_byte & RXDATA_EMPTY) || (uint8_t)isr_byte != expect_next) return 10;
  expect_next = (uint8_t)~0x6D;
  irq_global_disable();
  mmio_write(SPI_BASE + SPI_IE, 0);

  // 11: RX overrun
  spi_cs(1);
  for (int i = 0; i < 5; i++) {
    while (spi_status() & SPI_ST_TXFULL) { }
    mmio_write(SPI_BASE + SPI_TXDATA, 0xA0 + i);
  }
  spi_wait_idle();
  spi_cs(0);
  if (!(spi_status() & SPI_ST_RXOVR)) return 11;
  for (int i = 0; i < 4; i++) {
    uint32_t v = read_rx();
    if ((v & RXDATA_EMPTY) || (uint8_t)v != expect_next) return 11;
    expect_next = (uint8_t)~(0xA0 + i);
  }
  if (!(read_rx() & RXDATA_EMPTY)) return 11;
  expect_next = (uint8_t)~0xA4;                        // the slave saw the 5th byte too
  mmio_write(SPI_BASE + SPI_STATUS, SPI_ST_RXOVR);
  if (spi_status() & SPI_ST_RXOVR) return 11;
  return 0;
}
