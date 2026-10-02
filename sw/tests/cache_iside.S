# =============================================================================
# cache_iside.S - I-cache: FENCE.I and conflict misses (architecture.md P4.4)
# -----------------------------------------------------------------------------
#   2  FENCE.I: the instruction right after a `fence.i` (label 2, word 0 of
#      its cache line) is rewritten 16 times (addi a0, zero, i); each new
#      value must execute. Each iteration:
#        * starts with a `fence.i`, so every line of the block is cold and the
#          cache line of label 2 is prefetched right behind the second
#          `fence.i`: its refill is typically in flight when that FENCE.I
#          commits, and must not be validated (P4.4);
#        * stores a burst of 3 words just before the rewriting `sw`, which is
#          followed at once by `fence.i`: the rewrite is still queued in the
#          D-cache write buffer when FENCE.I commits, so the refetch of label
#          2 must wait for the buffer (P4.4).
#      Checked by the cache mutants CAM2 and CAM5 (architecture.md P4.7).
#   4  as 2, but without the leading `fence.i`: from the second iteration
#      every line of the loop is cached (refetched after the previous
#      iteration's FENCE.I), so no refill is in flight when FENCE.I commits
#      and the I-cache is free to refill label 4's line at once. The burst
#      keeps the rewrite queued in the write buffer, so only the write-buffer
#      sync (P4.4) makes the refill see it (cache mutant CAM2).
#   3  f1 and f2 lie 2 KB apart (same index, other tag) and are called
#      alternately 20 times: every call misses, and the `ret` after each
#      function's first instruction hits in the line just refilled.
#
# Derived floors (ideal memory, cache model):
#   ic_miss >= 136: case 2: the block is 4 cache lines; after the first
#                  FENCE.I of an iteration its lines 0-2 are refetched, after
#                  the second its line 3 (label 2): 4 x 16; case 4: after its
#                  FENCE.I every iteration refetches the line of label 4 and,
#                  after the backward branch, the loop's first line: 2 x 16;
#                  case 3: 40 calls, each to a line the previous call evicted
#   ic_hit  >= 40: case 3: the `ret` of each call
# CACHE-EXPECT: ic_miss>=136 ic_hit>=40
#
# Stock environment + sw/common/irq_handler.h, interrupts enabled. Registers
# t5/t6 and s5-s11 belong to the trap handler.
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"
#include "irq_handler.h"

#define INSN_ADDI_A0_ZERO 0x00000513     /* addi a0, zero, 0 */

RVTEST_RV32M
RVTEST_CODE_BEGIN

  .option norvc
  DIRECTED_TRAP_INSTALL(trap_handler)
  IRQ_ENABLE_ALL

  # --- 2: rewrite the instruction after fence.i, 16 times ---------------------
  # The block from label 1 to the end of the loop is 4 cache lines (16
  # instructions from a 16-byte boundary); label 2 starts line 3.
  li   TESTNUM, 2
  li   s2, 1                             # iteration = the new immediate
  li   s3, 17
  la   s1, 2f
  la   s4, scratch
  .balign 16
1:fence.i                                # line 0: everything cold
  li   t0, INSN_ADDI_A0_ZERO
  slli t1, s2, 20
  or   t0, t0, t1
  sw   t1, 0(s4)                         # line 1: burst into the write buffer
  sw   t1, 4(s4)
  sw   t1, 8(s4)
  sw   t0, 0(s1)                         # the rewrite, queued behind the burst
  nop                                    # line 2
  nop
  nop
  fence.i
2:addi a0, zero, 0                       # line 3: rewritten on every iteration
  bne  a0, s2, fail
  addi s2, s2, 1
  bne  s2, s3, 1b

  # --- 4: as 2, with the loop cached (no refill in flight at FENCE.I) ---------
  li   TESTNUM, 4
  li   s2, 1
  li   s3, 17
  la   s1, 4f
  .balign 16
3:li   t0, INSN_ADDI_A0_ZERO             # first line of the loop
  slli t1, s2, 20
  or   t0, t0, t1
  sw   t1, 0(s4)                         # burst into the write buffer
  sw   t1, 4(s4)
  sw   t1, 8(s4)
  sw   t0, 0(s1)                         # the rewrite, queued behind the burst
  fence.i
4:addi a0, zero, 0                       # rewritten on every iteration
  bne  a0, s2, fail
  addi s2, s2, 1
  bne  s2, s3, 3b

  # --- 3: two functions at the same index, called alternately -----------------
  li   TESTNUM, 3
  li   s2, 20
  li   a0, 0
3:jal  ra, f1
  jal  ra, f2
  addi s2, s2, -1
  bnez s2, 3b
  li   t0, 60                            # 20 x (1 + 2)
  bne  a0, t0, fail

  TEST_PASSFAIL

  .align 2
trap_handler:
  DIRECTED_TRAP_HANDLER

RVTEST_CODE_END

  # f1 and f2 in .text (which the link script aligns to 4 KB), 2 KB apart.
  .pushsection .text
  .balign 2048
f1:
  addi a0, a0, 1
  ret
  .balign 2048
f2:
  addi a0, a0, 2
  ret
  .popsection

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
  IRQ_DATA

scratch:
  .skip 16

RVTEST_DATA_END
