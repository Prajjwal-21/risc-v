# =============================================================================
# csr_impl.S - CSR checks of this implementation's own choices (D-039)
# -----------------------------------------------------------------------------
# Checks moved unchanged out of csr_ops (same case numbers), for co-simulation:
#   * our spec choices where Spike's legal choice differs: mtvec.MODE is
#     read-only 0 (16), marchid = 0 (27), mcause keeps bit 31 and [3:0] (29);
#   * checks that branch on values read from mcycle(h)/cycle(h) (38-41):
#     co-simulation's R4 taint rule fails a counter-derived value that decides
#     a branch, even when both models agree (architecture.md P3.5).
# New counter-valued checks (D-037, D-038):
#   42  mcountinhibit.CY stops mcycle
#   43  time increases (the testbench's mtime counts clock cycles)
#   44  timeh is 0 this early in a run
# (That time/timeh are read-only is checked in tr_illegal.)
#
# Runs in every accept-phase2 configuration; excluded from co-simulation by
# name (scripts/cosim_exclusions.txt).
#
# Stock environment + sw/common/irq_handler.h. Interrupts are enabled; the
# checks whose result an interrupt handler could change run with
# mstatus.MIE = 0. Registers t5/t6 and s5-s11 belong to the trap handler.
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"
#include "irq_handler.h"

#define MIE_OFF csrci mstatus, MSTATUS_MIE
#define MIE_ON  csrsi mstatus, MSTATUS_MIE

RVTEST_RV32M
RVTEST_CODE_BEGIN

  DIRECTED_TRAP_INSTALL(trap_handler)
  IRQ_ENABLE_ALL

  # --- Moved from csr_ops (unchanged) -------------------------------------------
  # mtvec: MODE is read-only 0 (direct only). mtvec keeps pointing at the
  # handler throughout, so an interrupt in between is harmless.
  TEST_CASE(16, a1, 0,          la a0, trap_handler; addi a0, a0, 3; csrw mtvec, a0; \
                                csrr a1, mtvec; la a0, trap_handler; sub a1, a1, a0 )
  TEST_CASE(27, a1, 0,          csrr a1, mvendorid; csrr a2, marchid; csrr a3, mimpid; csrr a4, mhartid; \
                                or a1, a1, a2; or a1, a1, a3; or a1, a1, a4 )
  TEST_CASE(29, a1, 0x8000000f, MIE_OFF; li a0, -1; csrw mcause, a0; csrr a1, mcause; MIE_ON )
  # mcycleh written after mcycle = 0: the low half cannot carry in between
  TEST_CASE(38, a1, 0x55,       MIE_OFF; csrwi mcycle, 0; li a0, 0x55; csrw mcycleh, a0; \
                                csrr a1, mcycleh; MIE_ON )
  TEST_CASE(39, a1, 0,          csrr a0, cycleh; csrr a1, mcycleh; sub a1, a1, a0 )
  # mcycle restarts from the written value: 0 < mcycle < 1000 shortly after
  TEST_CASE(40, a2, 1,          MIE_OFF; csrwi mcycle, 0; csrr a1, mcycle; MIE_ON; \
                                sltiu a2, a1, 1000; snez a3, a1; and a2, a2, a3 )
  # mcycle counts up; cycle aliases it
  TEST_CASE(41, a2, 1,          csrr a0, mcycle; csrr a1, cycle; sltu a2, a0, a1 )

  # --- New: counter values (D-037, D-038) ----------------------------------------
  # mcountinhibit.CY freezes mcycle; clearing it lets mcycle count again
  TEST_CASE(42, a1, 0,          MIE_OFF; csrwi mcountinhibit, 1; csrr a0, mcycle; nop; nop; \
                                csrr a1, mcycle; csrwi mcountinhibit, 0; MIE_ON; sub a1, a1, a0 )
  TEST_CASE(43, a2, 1,          csrr a0, time; nop; nop; csrr a1, time; sltu a2, a0, a1 )
  TEST_CASE(44, a1, 0,          csrr a1, timeh )

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
