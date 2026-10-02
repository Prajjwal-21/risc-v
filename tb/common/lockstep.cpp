// =============================================================================
// lockstep.cpp - Spike lockstep co-simulation over DPI (testbench only)
// -----------------------------------------------------------------------------
// docs/architecture.md P7.1. Spike's processor_t runs inside the simulation
// behind a custom simif_t: main memory is RAM (loaded from the same +hex
// file as the testbench's memory), everything else is MMIO whose answers come
// from the core's own retirement record. For every record of the core's
// retirement trace (tb/common/lockstep.sv), lockstep_step() steps Spike by one
// instruction and compares the architectural effects; interrupts the core took
// are injected into Spike through mip's backdoor. Values that come from
// outside the ISA (mcycle, cycle, time, marchid and the interrupt lines in
// mip) are injected into Spike's destination register instead of compared.
// The first mismatch is kept in lockstep_error().
//
// Configuration as offline co-simulation (P3.3): rv32i_zicsr_zifencei_zicntr,
// M-mode only, no PMP, no triggers, WFI as NOP, pc starting at 0x8000_0000.
// =============================================================================
#include <cinttypes>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "svdpi.h"
#include "cfg.h"
#include "encoding.h"
#include "mmu.h"
#include "processor.h"
#include "simif.h"

namespace {

constexpr uint32_t kResetPc = 0x80000000;
constexpr int      kOpSystem = 0x73;

// RV32 Spike keeps XLEN-wide values sign-extended in 64 bits: compare the low
// 32 bits, and hand it sign-extended values.
inline uint32_t u32(reg_t v) { return uint32_t(v); }
inline reg_t sext(uint32_t v) { return reg_t(int64_t(int32_t(v))); }

// Statistics, read by lockstep_stat()
enum { ST_RECORDS, ST_IRQ, ST_MMIO_LD, ST_MMIO_ST, ST_INJECT, ST_TRAPS, ST_N };

class lockstep_sim_t : public simif_t {
 public:
  lockstep_sim_t(reg_t base, reg_t size) : base_(base), ram_(size, 0) {
    cfg_.isa           = "rv32i_zicsr_zifencei_zicntr";
    cfg_.priv          = "M";
    cfg_.pmpregions    = 0;
    cfg_.trigger_count = 0;
    cfg_.wfi_as_nop    = true;
    cfg_.mem_layout    = std::vector<mem_cfg_t>({mem_cfg_t(base, size)});
    cfg_.hartids       = std::vector<size_t>({0});
    null_log_ = fopen("/dev/null", "w");
    proc_ = new processor_t(cfg_.isa, cfg_.priv, &cfg_, this, 0, false, null_log_, std::cout);
    harts_[0] = proc_;
    proc_->enable_log_commits();          // fills the commit-log containers
    proc_->reset();
    proc_->get_state()->pc = sext(kResetPc);
  }

  ~lockstep_sim_t() override {
    delete proc_;
    if (null_log_) fclose(null_log_);
  }

  // --- simif_t ------------------------------------------------------------------
  char* addr_to_mem(reg_t a) override {
    return in_ram(a) ? &ram_[u32(a) - base_] : nullptr;
  }
  // Instructions are fetched from main memory only (architecture.md 3.1).
  bool mmio_fetch(reg_t, size_t, uint8_t*) override { return false; }
  bool mmio_load(reg_t a, size_t len, uint8_t* bytes) override {
    if (io_refuse_) return false;
    if (!io_load_ || io_load_used_ || u32(a) != u32(io_addr_)) {
      fail("Spike loads %zu bytes from MMIO address %08" PRIx64
           " that the core's record does not show", len, a);
      return false;
    }
    uint32_t v = io_rdata_ >> (8 * (a & 3));
    for (size_t i = 0; i < len; i++) bytes[i] = uint8_t(v >> (8 * i));
    io_load_used_ = true;
    stat_[ST_MMIO_LD]++;
    return true;
  }
  bool mmio_store(reg_t a, size_t len, const uint8_t* bytes) override {
    if (io_refuse_) return false;
    uint64_t v = 0;
    for (size_t i = 0; i < len; i++) v |= uint64_t(bytes[i]) << (8 * i);
    io_st_seen_ = true;
    io_st_addr_ = u32(a);
    io_st_len_  = len;
    io_st_data_ = v;
    stat_[ST_MMIO_ST]++;
    return true;
  }
  void proc_reset(unsigned) override {}
  const cfg_t& get_cfg() const override { return cfg_; }
  const std::map<size_t, processor_t*>& get_harts() const override { return harts_; }
  const char* get_symbol(uint64_t) override { return nullptr; }

  // --- lockstep -----------------------------------------------------------------
  bool load_hex(const std::string& path);
  int step(const svBitVecVal* rec);
  const std::string& error() const { return err_; }
  long long stat(int which) const { return (which >= 0 && which < ST_N) ? stat_[which] : -1; }

 private:
  bool in_ram(reg_t a) const { return u32(a) >= base_ && u32(a) - base_ < ram_.size(); }

  template <typename... Args>
  void fail(const char* fmt, Args... args) {
    if (!err_.empty()) return;
    char buf[512];
    snprintf(buf, sizeof buf, fmt, args...);
    err_ = buf;
  }

  uint32_t csr(int which) { return u32(proc_->get_csr(which)); }

  reg_t base_;
  std::vector<char> ram_;
  cfg_t cfg_;
  std::map<size_t, processor_t*> harts_;
  processor_t* proc_ = nullptr;
  FILE* null_log_ = nullptr;
  std::string err_;
  long long stat_[ST_N] = {};

  // MMIO expectations for the step in progress
  bool io_refuse_ = false, io_load_ = false, io_load_used_ = false, io_st_seen_ = false;
  uint32_t io_addr_ = 0, io_st_addr_ = 0;
  uint32_t io_rdata_ = 0;
  size_t io_st_len_ = 0;
  uint64_t io_st_data_ = 0;
};

bool lockstep_sim_t::load_hex(const std::string& path) {
  // objcopy -O verilog output with addresses relative to base_: "@hhhhhhhh"
  // lines set the address, other tokens are bytes.
  std::ifstream in(path);
  if (!in) return false;
  std::string tok;
  reg_t off = 0;
  while (in >> tok) {
    if (tok[0] == '@') {
      off = std::stoull(tok.substr(1), nullptr, 16);
    } else {
      if (off >= ram_.size()) return false;
      ram_[off++] = char(std::stoul(tok, nullptr, 16));
    }
  }
  return true;
}

// Unpacked view of the record lockstep.sv passes (see its packing order).
struct rec_t {
  uint32_t insn, pc_rdata, pc_wdata, rd_addr, rd_wdata, mem_addr, mem_rmask, mem_wmask,
           mem_wdata, mem_rdata, csr_we, csr_addr, csr_wdata, trap, trap_cause, trap_tval,
           intr, intr_cause, intr_epc;
};

int lockstep_sim_t::step(const svBitVecVal* w) {
  if (!err_.empty()) return 1;
  rec_t r;
  uint32_t* f = &r.insn;
  for (int i = 0; i < 19; i++) f[i] = w[i];
  state_t* s = proc_->get_state();
  stat_[ST_RECORDS]++;

  if (u32(s->pc) != r.pc_rdata) {
    fail("pc: core %08x, Spike %08x", r.pc_rdata, u32(s->pc));
    return 1;
  }

  // MMIO answers for this instruction
  bool ld = r.mem_rmask != 0, st = r.mem_wmask != 0;
  io_refuse_    = r.trap && (r.trap_cause == 1 || r.trap_cause == 5 || r.trap_cause == 7);
  io_load_      = !r.trap && ld && !in_ram(r.mem_addr);
  io_load_used_ = false;
  io_addr_      = r.mem_addr;
  io_rdata_     = r.mem_rdata;
  io_st_seen_   = false;

  proc_->step(1);
  if (!err_.empty()) return 1;

  if (r.trap) {
    stat_[ST_TRAPS]++;
    uint32_t mcause = csr(CSR_MCAUSE), mepc = csr(CSR_MEPC), mtval = csr(CSR_MTVAL);
    if (mcause != r.trap_cause || mepc != r.pc_rdata || mtval != r.trap_tval || u32(s->pc) != r.pc_wdata)
      fail("exception at %08x: core cause %u tval %08x -> %08x; Spike mcause %x mepc %08x"
           " mtval %08x -> %08x", r.pc_rdata, r.trap_cause, r.trap_tval, r.pc_wdata, mcause,
           mepc, mtval, u32(s->pc));
    return err_.empty() ? 0 : 1;
  }

  // --- retired instruction ---
  // Next pc: with an interrupt, pc_wdata is mtvec and the successor is intr_epc.
  uint32_t want_pc = r.intr ? r.intr_epc : r.pc_wdata;
  if (u32(s->pc) != want_pc) {
    fail("next pc after %08x (insn %08x): core %08x, Spike %08x (Spike trapped? mcause %x)",
         r.pc_rdata, r.insn, want_pc, u32(s->pc), csr(CSR_MCAUSE));
    return 1;
  }

  // Values from outside the ISA are injected, not compared.
  uint32_t opc = r.insn & 0x7f, f3 = (r.insn >> 12) & 7, csrno = r.insn >> 20;
  bool csr_insn = opc == kOpSystem && f3 != 0 && f3 != 4;
  bool inject = csr_insn &&
      (csrno == CSR_MCYCLE || csrno == CSR_MCYCLEH || csrno == CSR_CYCLE || csrno == CSR_CYCLEH ||
       csrno == CSR_TIME || csrno == CSR_TIMEH || csrno == CSR_MARCHID || csrno == CSR_MIP);

  // Register write
  const auto& regs = s->log_reg_write;
  uint32_t spike_rd = 0, spike_val = 0;
  for (const auto& kv : regs) {
    if ((kv.first & 0xf) == 0 && (kv.first >> 4) != 0) {
      spike_rd = uint32_t(kv.first >> 4);
      spike_val = uint32_t(kv.second.v[0]);
    }
  }
  if (inject) {
    if (csrno == CSR_MIP) {
      const uint32_t lines = MIP_MSIP | MIP_MTIP | MIP_MEIP;
      if ((spike_val & ~lines) != (r.rd_wdata & ~lines) && r.rd_addr != 0)
        fail("mip read at %08x: core %08x, Spike %08x (bits other than MSIP/MTIP/MEIP)",
             r.pc_rdata, r.rd_wdata, spike_val);
    }
    if (r.rd_addr != 0) {
      s->XPR.write(r.rd_addr, sext(r.rd_wdata));
      spike_val = r.rd_wdata;
    }
    stat_[ST_INJECT]++;
  }
  if (spike_rd != r.rd_addr || (r.rd_addr != 0 && spike_val != r.rd_wdata))
    fail("register write at %08x (insn %08x): core x%u=%08x, Spike x%u=%08x",
         r.pc_rdata, r.insn, r.rd_addr, r.rd_wdata, spike_rd, spike_val);

  // Memory accesses
  auto popcount = [](uint32_t m) { int n = 0; for (; m; m &= m - 1) n++; return n; };
  if (ld) {
    bool ok = false;
    for (const auto& t : s->log_mem_read)
      ok = ok || (uint32_t(std::get<0>(t)) == r.mem_addr && std::get<2>(t) == popcount(r.mem_rmask));
    if (!ok && in_ram(r.mem_addr))
      fail("load at %08x: core reads %d bytes at %08x, Spike's log has %zu reads",
           r.pc_rdata, popcount(r.mem_rmask), r.mem_addr, s->log_mem_read.size());
    if (!in_ram(r.mem_addr) && !io_load_used_)
      fail("MMIO load at %08x from %08x: Spike did not load", r.pc_rdata, r.mem_addr);
  } else if (!s->log_mem_read.empty()) {
    fail("Spike loads at %08x, the core does not", r.pc_rdata);
  }
  if (st) {
    int n = popcount(r.mem_wmask);
    uint64_t mask = (n >= 8) ? ~0ull : ((1ull << (8 * n)) - 1);
    uint64_t want = (r.mem_wdata >> (8 * (r.mem_addr & 3))) & mask;
    bool ok = false;
    if (in_ram(r.mem_addr)) {
      for (const auto& t : s->log_mem_write)
        ok = ok || (uint32_t(std::get<0>(t)) == r.mem_addr && std::get<2>(t) == n &&
                    (std::get<1>(t) & mask) == want);
    } else {
      ok = io_st_seen_ && io_st_addr_ == r.mem_addr && io_st_len_ == size_t(n) &&
           (io_st_data_ & mask) == want;
    }
    if (!ok)
      fail("store at %08x: core writes %d bytes %0" PRIx64 " at %08x; Spike differs",
           r.pc_rdata, n, want, r.mem_addr);
  } else if (!s->log_mem_write.empty() || io_st_seen_) {
    fail("Spike stores at %08x, the core does not", r.pc_rdata);
  }

  // CSR written by the instruction (counters excluded: R4)
  if (r.csr_we && !inject && r.csr_addr != CSR_MCYCLE && r.csr_addr != CSR_MCYCLEH) {
    uint32_t v = csr(int(r.csr_addr));
    if (v != r.csr_wdata)
      fail("CSR %03x after %08x: core %08x, Spike %08x", r.csr_addr, r.pc_rdata, r.csr_wdata, v);
  }
  if (!err_.empty()) return 1;

  // --- interrupt taken after this instruction ---
  if (r.intr) {
    stat_[ST_IRQ]++;
    reg_t bit = reg_t(1) << r.intr_cause;
    s->mip->backdoor_write_with_mask(bit, bit);
    proc_->step(1);
    s->mip->backdoor_write_with_mask(bit, 0);
    uint32_t mcause = csr(CSR_MCAUSE), mepc = csr(CSR_MEPC);
    if (u32(s->pc) != r.pc_wdata || mcause != (0x80000000u | r.intr_cause) || mepc != r.intr_epc)
      fail("interrupt %u after %08x: core epc %08x -> %08x; Spike mcause %x mepc %08x pc %08x"
           " (Spike did not take it?)", r.intr_cause, r.pc_rdata, r.intr_epc, r.pc_wdata,
           mcause, mepc, u32(s->pc));
  }
  return err_.empty() ? 0 : 1;
}

lockstep_sim_t* g_sim = nullptr;

}  // namespace

extern "C" {

int lockstep_init(const char* hexfile, int mem_base, int mem_size) {
  delete g_sim;
  g_sim = new lockstep_sim_t(reg_t(uint32_t(mem_base)), reg_t(uint32_t(mem_size)));
  return g_sim->load_hex(hexfile) ? 0 : 1;
}

// rec: 19 words, in the order of rec_t (lockstep.sv packs them).
int lockstep_step(const svBitVecVal* rec) { return g_sim ? g_sim->step(rec) : 1; }

const char* lockstep_error() { return g_sim ? g_sim->error().c_str() : "lockstep not initialised"; }

long long lockstep_stat(int which) { return g_sim ? g_sim->stat(which) : -1; }

}
