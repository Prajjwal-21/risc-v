// =============================================================================
// trap.c - trap dispatch for the SoC C tests (docs/architecture.md P6.7)
// -----------------------------------------------------------------------------
// trap_entry (crt0.S) calls trap_dispatch with mcause/mepc/mtval and resumes
// at the pc it returns. Interrupts go to the handler registered for their
// cause and count in irq_handled, which the testbench compares with the
// number of interrupts the core took (+irq_count). An exception goes to the
// registered exception handler; with none, the test fails with tohost code
// 0x7EE (via the same path as main returning 0x7EE).
// =============================================================================
#include "hal.h"

volatile uint32_t irq_handled;

static irq_fn_t irq_fns[16];
static exc_fn_t exc_fn;

void trap_set_irq_handler(uint32_t cause, irq_fn_t fn) { irq_fns[cause & 15u] = fn; }
void trap_set_exc_handler(exc_fn_t fn) { exc_fn = fn; }

extern volatile uint64_t tohost;

static void fail_unexpected(void) {
  tohost = (0x7EEu << 1) | 1u;
  for (;;) { }
}

uint32_t trap_dispatch(uint32_t cause, uint32_t epc, uint32_t tval) {
  if (cause & MCAUSE_IRQ) {
    irq_fn_t fn = irq_fns[cause & 15u];
    if (!fn) fail_unexpected();
    fn();
    irq_handled = irq_handled + 1;
    return epc;
  }
  if (!exc_fn) fail_unexpected();
  return exc_fn(cause, epc, tval);
}
