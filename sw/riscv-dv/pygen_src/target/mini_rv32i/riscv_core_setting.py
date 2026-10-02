# =============================================================================
# riscv_core_setting.py - riscv-dv (pygen) target for this project's core
# -----------------------------------------------------------------------------
# docs/architecture.md P7.4, D-049. A copy of riscv-dv's target/rv32i setting
# (third_party/riscv-dv/pygen/pygen_src/target/rv32i, Apache-2.0, header
# below), changed to match the core: direct-mode mtvec only, no mcounteren,
# misaligned loads/stores trap. It is found through PYTHONPATH as the
# namespace package pygen_src.target.mini_rv32i (make riscv-dv), so
# third_party/ is not modified.
# =============================================================================
"""
Copyright 2020 Google LLC
Copyright 2020 PerfectVIPs Inc.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
"""

import math
from pygen_src.riscv_instr_pkg import (privileged_reg_t, satp_mode_t,
                                       riscv_instr_group_t, mtvec_mode_t,
                                       privileged_mode_t)


# -----------------------------------------------------------------------------
# Processor feature configuration
# -----------------------------------------------------------------------------

# XLEN
XLEN = 32

# set to BARE if address translation is not supported
SATP_MODE = satp_mode_t.BARE

# Supported Privileged mode
supported_privileged_mode = [privileged_mode_t.MACHINE_MODE]

# Unsupported instructions
unsupported_instr = []

# ISA supported by the processor
supported_isa = [riscv_instr_group_t.RV32I]

# Interrupt mode support
# mini-riscv: mtvec is direct mode only (D-024)
supported_interrupt_mode = [mtvec_mode_t.DIRECT]

# The number of interrupt vectors to be generated, only used if VECTORED
# interrupt mode is supported
max_interrupt_vector_num = 16

# Physical memory protection support
support_pmp = 0

# Debug mode support
support_debug_mode = 0

# Support delegate trap to user mode
support_umode_trap = 0

# Support sfence.vma instruction
support_sfence = 0

# Support unaligned load/store
# mini-riscv: misaligned loads and stores trap (D-015)
support_unaligned_load_store = 0

# GPR Setting
NUM_FLOAT_GPR = 32
NUM_GPR = 32
NUM_VEC_GPR = 32

# -----------------------------------------------------------------------------
# Vector extension configuration
# -----------------------------------------------------------------------------

# Parameter for vector extension
VECTOR_EXTENSION_ENABLE = 0

VLEN = 512

# Maximum size of a single vector element
ELEN = 32

# Minimum size of a sub-element, which must be at most 8-bits.
SELEN = 8

# Maximum size of a single vector element (encoded in vsew format)
VELEN = int(math.log(ELEN) // math.log(2)) - 3

# Maxium LMUL supported by the core
MAX_LMUL = 8


# -----------------------------------------------------------------------------
# Multi-harts configuration
# -----------------------------------------------------------------------------

# Number of harts
NUM_HARTS = 1

# -----------------------------------------------------------------------------
# Previleged CSR implementation
# -----------------------------------------------------------------------------

# Implemented previlieged CSR list
implemented_csr = [privileged_reg_t.MVENDORID,  # Vendor ID
                   privileged_reg_t.MARCHID,  # Architecture ID
                   privileged_reg_t.MIMPID,  # Implementation ID
                   privileged_reg_t.MHARTID,  # Hardware thread ID
                   privileged_reg_t.MSTATUS,  # Machine status
                   privileged_reg_t.MISA,  # ISA and extensions
                   privileged_reg_t.MIE,  # Machine interrupt-enable register
                   privileged_reg_t.MTVEC,  # Machine trap-handler base address
                   privileged_reg_t.MSCRATCH,  # Scratch register for machine trap handlers
                   privileged_reg_t.MEPC,  # Machine exception program counter
                   privileged_reg_t.MCAUSE,  # Machine trap cause
                   privileged_reg_t.MTVAL,  # Machine bad address or instruction
                   privileged_reg_t.MIP  # Machine interrupt pending
                   ]

# Implementation-specific custom CSRs
custom_csr = []
