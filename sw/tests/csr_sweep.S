# =============================================================================
# csr_sweep.S - every CSR address, read and write-intent (D-039, P3.4)
# -----------------------------------------------------------------------------
# For each address 0x000-0xFFF the test builds one CSR instruction in a code
# slot (self-modifying code, then FENCE.I) and executes it with an expected
# exception armed (s11 = 1, resume at mepc + 4):
#   pass 1  csrrs a0, csr, x0   read only: must trap exactly when the CSR does
#                               not exist
#   pass 2  csrrc a0, csr, t1   write intent with t1 = 0, so the value is
#                               unchanged: must also trap on read-only CSRs
# Self-check: the number of addresses that did not trap is 118 in pass 1 (the
# P2.2 set plus D-037/D-038, including 87 HPM registers) and 105 in pass 2
# (118 minus the 11 read-only CSRs and the 2 skipped below).
#
# Under co-simulation every one of the 8190 accesses is compared with Spike:
# existence, read-only-ness, the value read and the value written back. That
# covers the whole CSR map, and in particular misa (0x301) and the PMP CSRs
# (pmpcfg0-15 at 0x3A0, pmpaddr0-63 at 0x3B0): if the device tree given to
# Spike drifted from this core (another ISA string, or PMP regions), misa's
# value or the PMP traps would differ and co-simulation fails.
#
# Skipped by name: mcontext (0x7A8) in both passes, which Spike implements
# and this core does not (D-037, D1c); mcycle and mcycleh (0xB00, 0xB80) in
# pass 2, because the value written back is a cycle count, which differs from
# Spike's by design (R4).
#
# SIM-TIMEOUT: 8000000
# (cycle budget for hang detection: the SoC model needs 4.52M cycles with
# random latency, because each of the 8190 FENCE.I refills the I-cache over
# the AXI4-Lite bus; the core model needs 1.4M-2.6M)
#
# Stock environment + sw/common/irq_handler.h, interrupts enabled. Registers
# t5/t6 and s5-s11 belong to the trap handler.
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"
#include "irq_handler.h"

#define CSR_MCONTEXT      0x7a8
#define CSR_MCYCLE_ADDR   0xb00
#define CSR_MCYCLEH_ADDR  0xb80
#define INSN_CSRRS_A0_X0  0x00002573    /* csrrs a0, 0, x0 */
#define INSN_CSRRC_A0_T1  0x00033573    /* csrrc a0, 0, t1 */
#define N_EXIST           118
#define N_WRITABLE        105

RVTEST_RV32M
RVTEST_CODE_BEGIN

  DIRECTED_TRAP_INSTALL(trap_handler)
  IRQ_ENABLE_ALL

  la   s0, slot
  li   t1, 0                        # pass 2 operand: clear no bits

  # --- Pass 1: read every address ------------------------------------------
  li   s2, 0                        # accesses that did not trap
  li   s1, 0                        # CSR address
  li   s4, INSN_CSRRS_A0_X0
1:li   t0, CSR_MCONTEXT
  beq  s1, t0, 3f
  slli t0, s1, 20
  or   t0, t0, s4
  sw   t0, 0(s0)
  fence.i
  li   s11, 1                       # expect an exception; cleared if one is taken
  jalr ra, 0(s0)
  beqz s11, 3f                      # it trapped
  addi s2, s2, 1
  li   s11, 0
3:addi s1, s1, 1
  li   t0, 4096
  bne  s1, t0, 1b

  # --- Pass 2: write intent, value unchanged --------------------------------
  li   s3, 0
  li   s1, 0
  li   s4, INSN_CSRRC_A0_T1
1:li   t0, CSR_MCONTEXT
  beq  s1, t0, 3f
  li   t0, CSR_MCYCLE_ADDR
  beq  s1, t0, 3f
  li   t0, CSR_MCYCLEH_ADDR
  beq  s1, t0, 3f
  slli t0, s1, 20
  or   t0, t0, s4
  sw   t0, 0(s0)
  fence.i
  li   s11, 1
  jalr ra, 0(s0)
  beqz s11, 3f
  addi s3, s3, 1
  li   s11, 0
3:addi s1, s1, 1
  li   t0, 4096
  bne  s1, t0, 1b

  # --- Checks ----------------------------------------------------------------------
  li   TESTNUM, 2
  li   t0, N_EXIST
  bne  s2, t0, fail
  li   TESTNUM, 3
  li   t0, N_WRITABLE
  bne  s3, t0, fail
  TEST_CASE(4, a0, 0x40000100, csrr a0, misa )
  j    8f

  # The code slot: one CSR instruction, then return. It lies before `fail`, so
  # the handler treats its traps as test exceptions (D-041).
  .align 2
slot:
  nop
  ret

8:
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
