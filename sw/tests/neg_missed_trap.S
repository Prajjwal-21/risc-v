# =============================================================================
# neg_missed_trap.S - negative test for DIRECTED_TRAP_HANDLER (D-041)
# -----------------------------------------------------------------------------
# A planted failure: case 2 arms an expected exception (s11 = 1, resume at
# mepc + 4) on an instruction that does NOT trap (a nop), so its check
# `bnez s11, fail` must fail the test. Before the D-041 fix the handler took
# RVTEST_FAIL's ecall as the expected exception and resumed at mepc + 4, which
# is `pass:`, so this test reported PASS.
#
# This test must FAIL with test number 2 on the core and on Spike
# (make neg-tests, part of make test). It is not part of accept-phase2.
#
# EXPECT-FAIL: test=2
#
# Stock environment + sw/common/irq_handler.h. Registers t5/t6 and s5-s11
# belong to the trap handler.
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"
#include "irq_handler.h"

RVTEST_RV32M
RVTEST_CODE_BEGIN

  DIRECTED_TRAP_INSTALL(trap_handler)

  li   TESTNUM, 2
  li   s11, 1                       # an exception is expected ...
  nop                               # ... but this does not trap
  bnez s11, fail                    # so the test must fail here

  TEST_PASSFAIL

  .align 2
trap_handler:
  DIRECTED_TRAP_HANDLER

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
  IRQ_DATA

RVTEST_DATA_END
