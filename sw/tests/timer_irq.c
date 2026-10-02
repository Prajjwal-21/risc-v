// =============================================================================
// timer_irq.c - CLINT timer and software interrupts (architecture.md P6.7)
// -----------------------------------------------------------------------------
// Returns 0 on success, otherwise the number of the failing check.
//   1  mtime advances, and the time CSR follows it
//   2  a timer interrupt pending with MIE = 0 is visible in mip and not taken
//   3  five timer interrupts, each at or after its deadline (mtime read in the
//      handler >= mtimecmp); the handler re-arms mtimecmp to "never"
//   4  wfi with a timer interrupt coming: execution resumes after it
//   5  MSIP: a software interrupt raised through the CLINT is taken once and
//      cleared by its handler
//   6  mtime carries from MTIME into MTIMEH (MTIME written near 2^32)
// =============================================================================
#include "hal.h"

#define DEADLINE_TICKS  40u
#define SPIN_LIMIT      200000u

static volatile uint32_t timer_count, soft_count;
static volatile uint64_t timer_seen, deadline;

static void timer_isr(void) {
  timer_seen = clint_mtime();
  timer_count = timer_count + 1;
  clint_set_mtimecmp(~0ull);             // disarm
}

static void soft_isr(void) {
  clint_set_msip(0);
  soft_count = soft_count + 1;
}

static int wait_count(volatile uint32_t *c, uint32_t want) {
  for (uint32_t i = 0; i < SPIN_LIMIT; i++)
    if (*c >= want) return 1;
  return 0;
}

int main(void) {
  // 1: mtime and time advance
  uint64_t t0 = clint_mtime();
  for (volatile int i = 0; i < 20; i++) { }
  uint64_t t1 = clint_mtime();
  if (!(t1 > t0)) return 1;
  uint32_t tcsr = csr_read(time);
  if (tcsr < (uint32_t)t1) return 1;

  trap_set_irq_handler(IRQ_M_TIMER, timer_isr);
  trap_set_irq_handler(IRQ_M_SOFT, soft_isr);
  csr_set(mie, MIE_MTIE);

  // 2: pending but masked
  clint_set_mtimecmp(clint_mtime());
  for (volatile int i = 0; i < 10; i++) { }
  if (!(csr_read(mip) & MIP_MTIP)) return 2;
  if (timer_count != 0) return 2;
  clint_set_mtimecmp(~0ull);
  for (volatile int i = 0; i < 4; i++) { }
  if (csr_read(mip) & MIP_MTIP) return 2;

  // 3: five interrupts at their deadlines
  irq_global_enable();
  for (uint32_t k = 1; k <= 5; k++) {
    deadline = clint_mtime() + DEADLINE_TICKS * k;
    clint_set_mtimecmp(deadline);
    if (!wait_count(&timer_count, k)) return 3;
    if (timer_seen < deadline) return 3;
  }

  // 4: wfi until the next timer interrupt
  deadline = clint_mtime() + DEADLINE_TICKS;
  clint_set_mtimecmp(deadline);
  while (timer_count < 6) wfi();
  if (timer_seen < deadline) return 4;

  // 5: software interrupt
  csr_set(mie, MIE_MSIE);
  clint_set_msip(1);
  if (!wait_count(&soft_count, 1)) return 5;
  for (volatile int i = 0; i < 20; i++) { }
  if (soft_count != 1) return 5;
  if (csr_read(mip) & MIP_MSIP) return 5;

  irq_global_disable();

  // 6: carry into the high word
  mmio_write(CLINT_BASE + CLINT_MTIMEH, 0);
  mmio_write(CLINT_BASE + CLINT_MTIME, 0xFFFFFFF8u);
  for (volatile int i = 0; i < 40; i++) { }
  if (mmio_read(CLINT_BASE + CLINT_MTIMEH) != 1) return 6;
  if (mmio_read(CLINT_BASE + CLINT_MTIME) > 0x1000u) return 6;
  return 0;
}
