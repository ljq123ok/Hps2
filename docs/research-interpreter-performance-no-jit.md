# Interpreter Performance Without a JIT — Research Report

**Scope**: how emulators make interpreters fast, and measured data on interpreter-vs-JIT gaps.
**Date**: 2026-09-26
**Context**: HPS2 (HarmonyOS PS2 emulator, ARMSX2/PCSX2 fork) — evaluating the no-JIT fallback path.

---

## Bottom line

**A playable PS2 emulator without a JIT is not achievable today, and the published evidence says the gap is
structural rather than a matter of tuning.** The concrete numbers:

| Emulator | Hardware being emulated | Best no-JIT result | Verdict |
|---|---|---|---|
| **Dolphin** (GameCube/Wii, PowerPC) | GameCube/Wii | Cached Interpreter; maintainer calls the approach **"flawed"**; UI literally labels it `Cached Interpreter (slower)` vs `JIT Recompiler (recommended)` | Not playable; wiki says interpreter costs **"tenfold or more"** |
| **PPSSPP** (PSP, MIPS32) | PSP (333 MHz MIPS) | **Ship-quality on the App Store** — "nearly all PSP games at full speed" | **Playable — this is the one real success case** |
| **Dolphin iOS** (same as above) | GameCube/Wii | "basically unplayable" on an **iPhone 15 Pro Max** | Not playable |
| **Flycast** (Dreamcast) | Dreamcast | "Performance on complex Dreamcast games suffers" | Not playable for complex titles |
| **ARMSX2 / PCSX2** (PS2, MIPS R5900 + 2×VU) | PS2 | EE block cache: **37.55 ms → 30.55 ms (−18.6%)** | **Not playable**; commit itself says "materially slower… not parity with JIT" |

The pattern is **guest-CPU emulation workload**, not interpreter quality:

- PSP's CPU is a **single 333 MHz MIPS32** with a small feature set → a modern ARM core can interpret it
  faster than real-time.
- The **PS2 EE is a 294 MHz MIPS R5900 with 128-bit MMI SIMD**, plus **two VU vector coprocessors**,
  a DMA/VIF engine, and the IOP. The interpreter must also emulate the VU0/VU1 macro-mode ops. That is
  roughly *two orders of magnitude* more host work per guest cycle than PSP.

Every published no-JIT success story emulates a **simple, slow** guest CPU on **fast modern host hardware**.
The PS2 is neither.

**Concrete actionable recommendation for HPS2** — the ARMSX2 no-JIT work is real, correct, and worth
keeping as a **safety net for booting and menus**, but it should not be presented to users as a way to play
games. The honest product framing is: JIT required for gameplay; interpreter-only is a diagnostic/fallback
mode that boots and may render menus. HPS2's current "refuse to boot without JIT" policy is more honest than
a fallback that silently produces 3 fps.

---

## 1. Dolphin (GameCube/Wii) — "Cached Interpreter"

### 1.1 How it works (verified from source)

Dolphin has four CPU cores
([`AdvancedPane.cpp`](https://raw.githubusercontent.com/dolphin-emu/dolphin/master/Source/Core/DolphinQt/Settings/AdvancedPane.cpp)):

```cpp
{PowerPC::CPUCore::Interpreter,       QT_TR_NOOP("Interpreter (slowest)")},
{PowerPC::CPUCore::CachedInterpreter, QT_TR_NOOP("Cached Interpreter (slower)")},
{PowerPC::CPUCore::JIT64,             QT_TR_NOOP("JIT Recompiler for x86-64 (recommended)")},
{PowerPC::CPUCore::JITARM64,          QT_TR_NOOP("JIT Recompiler for ARM64 (recommended)")},
```

Note the first-party labels. Dolphin itself calls the interpreter **"slowest"** and cached interpreter
**"slower"**, and marks only the JITs as "recommended".

**Plain interpreter** (`Interpreter::Run` → `SingleStepInner`) decodes and executes **one instruction at a
time**, every time:
[`Interpreter.cpp`](https://raw.githubusercontent.com/dolphin-emu/dolphin/master/Source/Core/Core/PowerPC/Interpreter/Interpreter.cpp)

```cpp
m_ppc_state.npc = m_ppc_state.pc + sizeof(UGeckoInstruction);
m_prev_inst.hex = m_mmu.Read_Opcode(m_ppc_state.pc);
const GekkoOPInfo* opinfo = PPCTables::GetOpInfo(m_prev_inst, m_ppc_state.pc);
```

Every instruction pays: memory read of the instruction word + opcode-table lookup + dispatch + handler.

**Cached Interpreter** is architecturally a *JIT that emits no machine code*. It inherits `JitBase` and
reuses the JIT's block cache and `PPCAnalyst` block analysis, but instead of emitting ARM/x86 it emits a
**linear stream of `(callback function pointer, payload struct)` pairs** into an executable buffer:

```cpp
struct InterpretOperands {
  Interpreter& interpreter;
  void (*func)(Interpreter&, UGeckoInstruction);  // Interpreter::Instruction
  u32 current_pc;
  UGeckoInstruction inst;
};
```

`DoJit` walks the analyzed block and for each instruction writes a callback:
`Interpret<true>` if the instruction can end the block, else `Interpret<false>`. Execution walks the buffer:

```cpp
const auto callback = *reinterpret_cast<const AnyCallback*>(normal_entry);
const u8* payload = normal_entry + sizeof(callback);
if (callback == AnyCallbackCast(Interpret<false>)) [[likely]] { ... }
```

So the win versus the plain interpreter is: **decode and opcode-table lookup are hoisted out of the execute
loop** (done once per block compile instead of once per execution), and block boundaries let the JIT's block
cache be reused.

Design details worth noting:
- Blocks are found/compiled through the standard JIT block cache (`CachedInterpreterBlockCache`,
  derived from `JitBaseBlockCache`) — so the same block-linking, invalidation and profiling infrastructure
  applies.
- `jo.enableBlocklink = false` — **block linking is disabled**, i.e. it does not chain blocks to avoid
  dispatch.
- 2024's "Cached Interpreter 2.0" ([PR #12723](https://github.com/dolphin-emu/dolphin/pull/12723), mitaclaw,
  merged 2024-07-24) added variable-sized payloads and memory-range freeing using
  `Common::AllocateMemoryPages` instead of executable memory.

### 1.2 Measured performance

| Source | Number |
|---|---|
| [Dolphin wiki, Configuration Guide](https://web.archive.org/web/2024id_/https://wiki.dolphin-emu.org/index.php?title=Performance_Guide) | CPU Emulation Engine: "set to the fastest option by default… Changing this option alone may slowdown your performance by **tenfold or more**." |
| [PR #2784](https://github.com/dolphin-emu/dolphin/pull/2784) (sigmabeta, merged 2015-07-28) | "Roughly **10fps** in Twilight Princess intro, versus **3fps** in the standard interpreter" → cached interp ≈ **3.3× the plain interpreter** |
| [PR #12723](https://github.com/dolphin-emu/dolphin/pull/12723) (2024) | User report: "**~2 FPS faster** than latest dev"; another: "**+1.5-2.0 FPS increase** on a Retroid Pocket 2S" |
| [PR #13951](https://github.com/dolphin-emu/dolphin/pull/13951) (TellowKrinkle, merged 2025-09-26) | Speculative devirtualization of the `Interpret` callback: "**~10% better performance** for the cached interpreter on both the M1 and Skylake" |

So the realistic ladder is: **plain interpreter → cached interpreter ≈ 2-3.5×**, and then only single-digit
to ~10% incremental wins afterward. That is nowhere near closing a gap the wiki describes as "tenfold or
more" versus the JIT.

### 1.3 The decisive maintainer assessment

From [PR #12723](https://github.com/dolphin-emu/dolphin/pull/12723), mitaclaw (the author of Cached
Interpreter 2.0, now merged into Dolphin master) wrote:

> "Sam Belliveau's tests taught me that **the primary bottleneck of the Cached Interpreter appears to be the
> number of function pointers emitted.** That is to say, **the unpredictable branch every few tens of host
> instructions is cratering the performance.** So my takeaway from this fun distraction project … is that
> **the concept of the Cached Interpreter itself is flawed.**"

And, critically for planning purposes:

> "**No-JIT remains materially slower than a valid ARM64 recompiler.**"

(That last quote is from the ARMSX2 commit, see §3 — but the Dolphin maintainer's finding is the same
mechanism, independently discovered.)

Also from PR #12723, a reviewer pushing back on merging:

> "The speed gains are minimal and don't affect the CPU JIT, it adds complexity, and the author themself has
> admitted that they think this approach is ultimately a dead end that cannot be improved further."

And on the function-pointer experiment ([PR #12750](https://github.com/dolphin-emu/dolphin/pull/12750)):
"While this branch is cleaner then #12765, it is **objectively a lot slower**."

**The mechanism matters**: a cached interpreter replaces one hard-to-predict indirect switch jump with a
*sequence* of indirect calls. On modern wide out-of-order cores, each `callback(ppc_state, payload)` is an
indirect branch the predictor must get right. This is the same problem that makes switch dispatch slow — it
is not solved, only relocated.

TellowKrinkle's PR #13951 confirms it quantitatively: making the *most common* callback (`Interpret`)
inlinable — i.e. **removing** one indirect branch class — was worth ~10%, and the dominant observed effect
was a drop in branch mispredictions.

### 1.4 Is it playable? — No

From **OatmealDome** (DolphiniOS maintainer), [*Why Dolphin Isn't Coming to the App Store*](https://oatmealdome.me/blog/why-dolphin-isnt-coming-to-the-app-store/),
2024-04-19 — the single most directly relevant primary source for the iOS question:

> "It is technically possible to run Dolphin without its JIT recompiler. When doing so, Dolphin uses
> something called an 'interpreter'… **Unfortunately, the interpreter is many times slower than the JIT
> recompiler.** … As you can see, **it is basically unplayable**. These clips were even recorded on an
> **iPhone 15 Pro Max, the highest end iPhone currently available.**"

He also notes: "While we could submit DolphiniOS to the App Store with just the interpreter, we would likely
get endless complaints from users about the poor performance. **App Review might also just reject us anyway
because the app is unusable.**"

That is the definitive answer for GameCube/Wii-class workload on the best available mobile silicon.

---

## 2. PPSSPP (PSP) — IR interpreter on iOS

### 2.1 Structure (verified from source)

PPSSPP has **four** CPU cores ([`ConfigValues.h`](https://raw.githubusercontent.com/hrydgard/ppsspp/master/Core/ConfigValues.h)):

```cpp
enum class CPUCore {
	INTERPRETER = 0,     // plain MIPS interpreter
	JIT = 1,             // native JIT (ARM64/x86)
	IR_INTERPRETER = 2,  // IR interpreter — the iOS path
	JIT_IR = 3,          // IR frontend + native backend
};
```

The pipeline: **MIPS → IR (frontend) → either native code (JIT_IR) or direct IR execution (IR_INTERPRETER)**.
Key detail from [`MIPS.cpp`](https://raw.githubusercontent.com/hrydgard/ppsspp/master/Core/MIPS/MIPS.cpp):
the IR interpreter is constructed as an `IRJit` with `actualJit = false`:

```cpp
} else if (PSP_CoreParameter().cpuCore == CPUCore::IR_INTERPRETER) {
    MIPSComp::jit = new MIPSComp::IRJit(this, false);
```

...and that flag only changes an optimization hint:
```cpp
// If this IRJit instance will be used to drive a "JIT using IR", don't optimize for interpretation.
jo.optimizeForInterpreter = !actualJit;
```

So the IR interpreter reuses the **same block cache, same IR, same frontend** as the JIT — only the backend
differs. Blocks are stored in an arena and marked in guest memory with an `MIPS_EMUHACK_OPCODE`, and the
dispatcher jumps straight to the block's IR:

```cpp
u32 inst = Memory::ReadUnchecked_U32(mips->pc);
if (opcode == MIPS_EMUHACK_OPCODE) {
    u32 offset = inst & 0x00FFFFFF;
    const IRInst *instPtr = blocks_.GetArenaPtr() + offset;
    ...
    mips->pc = IRInterpret(mips, instPtr);
```

**Crucially, PPSSPP's IR interpreter uses computed-goto direct threading**, not a switch
([`IRInterpreter.cpp`](https://raw.githubusercontent.com/hrydgard/ppsspp/master/Core/MIPS/IR/IRInterpreter.cpp)):

```cpp
// With GCC and Clang, each op jumps straight to the next op's handler through a table ("threaded"
// dispatch), which predicts much better than the one shared indirect jump of a switch. Other
// compilers get the switch. Ops missing from the table fall back to the switch, so they still work.
#define IR_THREADED_DISPATCH 1
#define IR_NEXT do { IR_CHECK_ZERO_REG(); inst++; goto *dispatch[(int)inst->op]; } while (false)
```

with a 256-entry `dispatch[]` table built at first call, defaulting unlisted ops to `&&L_switch`.
`IR_NEXT` appears **163 times** — it is the real dispatch mechanism.

Note also this dispatcher optimization, which is a general lesson:

```cpp
// First op is always, except when using breakpoints, downcount, to save one dispatch inside IRInterpret.
// This branch is very cpu-branch-predictor-friendly so this still beats the dispatch.
if (instPtr->op == IROp::Downcount) { mips->downcount -= instPtr->constant; instPtr++; }
```

### 2.2 Measured performance — the one genuine success story

From Henrik Rydgård (PPSSPP author), [*PPSSPP is live on the App Store!*](https://www.ppsspp.org/news/live-on-app-store/),
2024-05-15:

> "The JIT recompiler is not supported… **the JIT compiler cannot be restored without a change in Apple's
> rules.** The loss of the JIT is unfortunate since without it, our CPU emulation performance is reduced.
> Fortunately, **iOS devices are generally fast enough to run nearly all PSP games at full speed anyway, as
> the PSP CPU is not that expensive to emulate**, thanks to our **efficient IR-based caching interpreter**,
> which also has further room for improvement."

This is the **only** documented case I found of a shippable, App-Store-accepted, interpreter-only emulator
running a large game library at full speed.

**Honesty note**: I could **not** find a published numerical ratio of PPSSPP IR-interpreter vs JIT
(e.g. "N% of JIT speed"). Rydgård's statement is qualitative ("performance is reduced") but with the
operational claim that full speed is still reached. The reason no ratio is published is likely that it
doesn't matter much — the interpreter is fast enough on target hardware, so nobody benchmarks the delta.
**Do not quote a specific PPSSPP interpreter/JIT ratio; none is published.**

The key sentence to internalize is Rydgård's own explanation of *why* it works: **"the PSP CPU is not that
expensive to emulate."** That is the whole story. It is a property of the guest, not of the interpreter.

---

## 3. PS2 specifically (PCSX2 / ARMSX2 / AetherSX2 / NetherSX2)

### 3.1 ARMSX2's no-JIT work — verified from the actual commit

I inspected the ARMSX2 tree directly. The commit is:

```
commit 45368481be56989c642ae6540dae709aa22526aa
Author: Brandon <henyckma@gmail.com>
Date:   Fri Jul 31 04:00:14 2026 -0600
Title:  iOS Hybrid JIT Safety, No-JIT Fallback, and Interpreter Performance
```

It is an **ancestor of HPS2's current HEAD**, so HPS2 already ships this code.

#### The reported number, in the commit's own words

> "The user-observed EE time changed from **37.55 ms to 30.55 ms** after the conservative cache and ThinLTO
> baseline was introduced.
> That is: **7.00 ms less EE time** in the observed workload. Approximately **18.6% lower EE processing
> time** for that workload. Approximately **1.23x the previous EE throughput**, if all other conditions are
> equal.
> **This is an observed device result supplied with the change, not a benchmark performed during this
> packaging step.** Results remain game-, scene-, device-, thermal-, and settings-dependent."

Two caveats the commit is careful to state, which you should preserve when quoting it:
1. It is a **user-observed device result**, not a controlled benchmark.
2. The 1.23× is explicitly conditional ("if all other conditions are equal").
3. The gain is **partly ThinLTO**, not purely the block cache — the two were introduced together, so the
   block cache alone is *less* than 18.6%.

And the framing sentence that answers the playability question outright:

> "**No-JIT remains materially slower than a valid ARM64 recompiler. The purpose is safe boot plus a
> measurable reduction in interpreter overhead, not parity with JIT.**"

#### What else the commit does for the no-JIT path

This is broader than the block cache. The commit makes **executable code memory an explicit capability**
(`SysMemory::HasCodeMemory()`) and gates every code-generating subsystem on it. From the commit message
and the `Behavior matrix`:

| Runtime state | EE/IOP | VU0/VU1 | Code cache | Fastmem | MTVU | VIF | SW GS | Keep-alive |
|---|---|---|---|---|---|---|---|---|
| Valid JIT grant | Recompiler | microVU | Allocated | Configured | Configured | Generated | Generated | Idle only |
| No `CS_DEBUGGED` grant | Interpreter | Interpreter | None | Off | Off | Precompiled | C functions | Off |
| Executable allocation failure | Interpreter | Interpreter | None | Off | Off | Precompiled | C functions | Off |

No-JIT mode therefore also:
- Skips the **4 GB fastmem virtual-address reservation** (the interpreter emits no fastmem accesses).
- **Disables MTVU**, because its VIF path depends on generated unpack execution.
- Falls back to **precompiled C VIF unpack functions** instead of generated mode-zero tables.
- Uses **`CSetupPrim` / `CDrawScanline` / `CDrawEdge`** for the software GS renderer instead of the
  scanline JIT.
- **Does not create the JIT keep-alive timer** (interpreter-only sessions have no grant to preserve).
- Clamps runtime config to the providers that actually exist, **without overwriting the user's saved
  recompiler preferences**, so a later boot with valid JIT uses the accelerated path again.

It also fixes a real pre-existing bug: previously a JIT-less boot could reach recompiler paths with null
code-cache memory and crash or hang on a black screen. It now performs a **complete CPU-worker teardown and
recreation** on backend change rather than mutating an initialized worker in place.

#### The EE block cache, in detail

`pcsx2/no-jit-improvements.{h,cpp}` (new files) — I read the full source. Design:

- **4,096 direct-mapped slots**, **up to 16 EE instructions per slot**, `alignas(64)` to reduce false sharing.
- Fixed process-lifetime allocation (`std::array<EEBlock, 4096>`) — **no heap allocation in the execution
  loop**. Commit says ~**1 MiB static memory** on 64-bit builds.
- Each entry stores the **raw instruction words** *and* **pointers to their predecoded `R5900::OPCODE`
  descriptors**. This is the actual win: `GetCurrentInstruction()`'s subclass-walking decode
  (`Interpreter.cpp` / `R5900OpcodeImpl.cpp`) is skipped on a cache hit.
- Hash: `(addr ^ (addr >> 11) ^ (addr >> 19)) & 4095`.
- **Correctness**: cached bytes are `memcmp`-validated against emulated RAM before *every* reuse
  (`vtlb_memSafeCmpBytes`). This is a self-modifying-code safety mechanism, and it is *not* free — it is a
  per-reuse cost. The commit acknowledges this: "It trades that bounded allocation and **per-block RAM
  validation** for fewer repeated instruction decodes."
- Blocks **terminate after branches, stores, and COP0 ops** (which can change memory or address-translation
  state). Branch delay slots deliberately stay on the original interpreter path.
- Disabled under `PCSX2_DEVBUILD`/`PCSX2_RECOMPILER_TESTS` (debug stepping and the interpreter oracle need
  the one-instruction path), and when EE cache emulation is active (`CHECK_CACHE`), because cached bytes
  could differ from RAM.
- Integration point is a single line in `intExecute`:
  ```cpp
  if (!NoJITImprovements::ExecuteEEBlock(cpuRegs.pc, execCachedI))
      execI();
  ```
  `execCachedI` stops the block when `cpuRegs.pc` diverges from the expected next PC (exception or control
  transfer) or on any branch flag.

#### What the commit explicitly did NOT do

This is important — these are the higher-value techniques, deliberately deferred:

> "The subsequently evaluated POC's are absent from this PR:
> - **Direct-threaded EE dispatch.**
> - **EE superinstructions.**
> - New ARM64 NEON MMI implementations.
> - New ARM64 NEON VU implementations."

and

> "This is intentionally conservative. It does **not add direct-threaded dispatch, superinstructions, or new
> MMI/VU NEON implementations.**"

and

> "It does not change the JIT execution architecture… No interpreter cache lookup is performed by
> `recExecute()`." (i.e. **zero JIT-path cost** — the cache is only reachable from `intExecute`.)

So ARMSX2's own author evaluated direct threading and superinstructions as the next steps and found them
worth *prototyping* but not yet landing. That is a strong signal: the team that wrote the no-JIT path does
not consider it finished, and the remaining headroom is exactly the general techniques in §4.

### 3.2 Related ARMSX2 no-JIT work

- **`fb2c07eb6`** "iOS: add JIT resilience layer with keepalive, interpreter fallback, and boot watchdog"
  (2026-07-12) — the precursor. iOS revokes the `CS_DEBUGGED` grant after **~30-60 seconds of inactivity**.
  Adds a 12-second idle `ValidateJITAlive()` dispatch timer (csops re-probe + canary byte write to the RW
  alias), a `JITExpired` notification, and wires up the previously dormant `iPSX2_FORCE_EE_INTERP` flag.
  Notably it fixed `applyFullInterpreterPreset` to actually write `EnableEE = false`, "since CoreType was an
  iOS-UI-only concept the C++ core ignored."
- **`0bfc42d2a`** "Two-stage No-JIT warning and red in-game indicator" (2026-08-04) — user-visible warning
  that the session is running without JIT.

The existence of a *warning UI* is itself evidence about playability: ARMSX2 treats no-JIT as a degraded
state to be surfaced, not a supported gameplay mode.

### 3.3 HPS2-specific finding (from this repo)

`docs/feasibility.md`, `docs/jit-failure-correction.md` and commit `13a8af3a0` establish that **the
"upstream will auto-fall-back to interpreter" assumption is false on HarmonyOS**. On non-Apple platforms
(including OHOS), `SysMemory::Allocate` returned `false` outright when code memory allocation failed, so
`VMManager::UpdateCPUImplementations` — the code that selects interpreter providers — was **never reached**.
Only the Apple branch had the `iPSX2_FORCE_EE_INTERP` escape hatch. HPS2 added an equivalent
`HPS2_FORCE_INTERP` gate (`pcsx2/Memory.cpp`, 22 insertions) so the fallback can actually be exercised.

Good news recorded in that commit: once past the code-memory gate, **the downstream interpreter path is
functional** — `vtlb_Core_Alloc` (vtlb.cpp:1387) already handles `HasCodeMemory() == false` for fastmem and
vtlb.

### 3.4 PCSX2 upstream / AetherSX2 / NetherSX2

- **PCSX2's interpreter is a debugging/compatibility oracle, not a performance option.** The ARMSX2 README
  states the relevant architectural fact directly: "The upstream PCSX2 project ships an ARM64 *interpreter*
  build for ARM, but its high-performance **JIT recompilers** (EE, IOP, VU0, VU1, and vtlb fast memory) are
  **x86-64 only**." That is precisely why ARMSX2 exists as a fork.
- **AetherSX2 / NetherSX2**: these are Android PS2 emulators targeting devices where a JIT is available;
  I found **no evidence** they shipped or documented an interpreter-only gameplay mode. *I was unable to
  complete an exhaustive search of their documentation before this report was due — treat this as
  "no evidence found", not "proven absent."*
- **`pcsx2-eerunner`** exists in the ARMSX2 tree (a standalone EE runner) and has interpreter-related
  bisecting tooling (`--rec-fallback` opcode filters, `--liverun`, EE cycle-rate scripting). It is a
  **developer tool for differential testing JIT vs interpreter, not a benchmark of playable performance.**

### 3.5 The honest answer on PS2 no-JIT

**No playable no-JIT path exists.** The ARMSX2 commit says so itself. The best measured improvement is
**−18.6% EE time** (partly ThinLTO), on top of a baseline that is already unplayable. Even a hypothetical
2× further improvement would not reach playability, because the host work per guest cycle for R5900
(128-bit MMI) + VU0 + VU1 + IOP is simply too large.

---

## 4. General interpreter speedup techniques

### 4.1 Computed goto / direct threading — the best-evidenced single technique

**Mechanism** (CPython's own explanation, [`ceval_macros.h`](https://raw.githubusercontent.com/python/cpython/main/Python/ceval_macros.h)):

> "The traditional bytecode evaluation loop uses a 'switch' statement, which decent compilers will optimize
> as a single indirect branch instruction combined with a lookup table of jump addresses. **However, since
> the indirect jump instruction is shared by all opcodes, the CPU will have a hard time making the right
> prediction for where to jump next** (actually, it will be always wrong except in the uncommon case of a
> sequence of several identical opcodes).
>
> 'Threaded code' in contrast, **uses an explicit jump table and an explicit indirect jump instruction at
> the end of each opcode. Since the jump instruction is at a different address for each opcode, the CPU will
> make a separate prediction for each of these instructions** … These predictions have a much better chance
> to turn out valid, especially in small bytecode loops.
>
> At the time of this writing, the 'threaded code' version is **up to 15-20% faster** than the normal
> 'switch' version, depending on the compiler and the CPU architecture."

**Published measurements:**

| Source | Finding |
|---|---|
| [CPython](https://raw.githubusercontent.com/python/cpython/main/Python/ceval_macros.h) | **up to 15-20% faster** than switch |
| [Lua / OpenWrt commit 62333da](https://git.openwrt.org/?p=openwrt/staging/jogo.git;a=commit;h=62333dabe1991261a58fe127844f1f152d242d7f) | computed goto instead of switch/case — "**improves performance by about 10%** in a simple loop test" |
| PPSSPP [IRInterpreter.cpp](https://raw.githubusercontent.com/hrydgard/ppsspp/master/Core/MIPS/IR/IRInterpreter.cpp) | implements it, with the stated rationale that threaded dispatch "predicts much better than the one shared indirect jump of a switch" (**no % published**) |
| Ertl's dispatch benchmark (below) | architecture-dependent; the *ratio* varies enormously |

**Ertl's benchmark** — [*Speed of various interpreter dispatch techniques V2*](https://www.complang.tuwien.ac.at/forth/threading/),
cycles per dispatch, columns = `subroutine | direct | indirect | switch | repl. switch(?) | call`:

Selected AArch64 (most relevant to HPS2's ARM target):

| CPU | subroutine | direct | indirect | switch |
|---|---|---|---|---|
| Cortex-A76 (Rock5B) | 2.24 | **2.7** | 2.7 | **5.4** |
| Cortex-A73 | 5.7 | **3.2** | 3.9 | **7.0** |
| Cortex-A72 | 4.2 | **4.1** | 4.0 | **9.0** |
| Cortex-A55 | 3.9 | **4.8** | 5.6 | **7.4** |
| Cortex-A53 | 6.6 | **5.1** | 6.1 | **12.5** |

On Cortex-A53, switch is ~**2.4×** the cost of direct threading; on A76 ~**2×**. Ertl's methodology note is
important and worth quoting in any citation:

> "the benchmarks are designed to produce **50% mispredictions for direct and indirect threaded code, and
> 100% indirect branch mispredictions for switch dispatch** on machines with a simple BTB; this corresponds
> to the prediction accuracies of these dispatch techniques on various large benchmarks on several virtual
> machines"

So Ertl deliberately models *realistic* misprediction rates — this is why switch looks catastrophically bad
here vs. the 10-20% figures elsewhere. The difference is whether the benchmark's opcode sequence is
predictable. **Do not quote Ertl's 2× as a guaranteed win.** Real gains depend on the opcode stream's
predictability.

Also relevant from Ertl's page: gcc's **cross-jumping optimization can "cost lots of performance for direct
and indirect threaded code"** (disable with `-fno-crossjumping`/`-fno-gcse`). CPython repeats this warning:
"care must be taken that the compiler doesn't try to 'optimize' the indirect jumps by sharing them between
all opcodes."

**Practical takeaway for a R5900 interpreter**: expect roughly **10-20%** on a well-behaved stream, up to
~2× on misprediction-heavy streams vs a naive switch. It is the highest-value/lowest-risk technique
available, and ARMSX2 has it on the "evaluated but not landed" list.

**Compatibility note for HPS2**: computed goto relies on GCC/Clang `&&label` (labels-as-values). That is
available in the OHOS LLVM/clang 15.0.4 toolchain. MSVC does not support it, which is why PPSSPP's code has
the `#if defined(__GNUC__) || defined(__clang__)` guard and falls back to switch.

### 4.2 Predecoded blocks / block caches — measured, modest

Two independent real-world measurements, and they agree on the order of magnitude:

| System | Technique | Measured |
|---|---|---|
| **ARMSX2** (EE block cache) | 4096 slots × 16 instrs, predecoded `OPCODE*` + byte validation on reuse | **37.55 → 30.55 ms EE time (−18.6%)**, *including* ThinLTO; not a controlled benchmark |
| **Dolphin** (Cached Interpreter) | hoist decode/opinfo out of the loop; function-pointer callback stream | **3fps → ~10fps** for Twilight Princess intro (**≈3.3×**) vs *plain* interpreter, but the maintainer judges the design "flawed" and it remains far slower than JIT |
| **Dolphin** PR #13951 (devirtualization) | inline the single hottest callback | **~10%** |

The distinction between the two is important:
- ARMSX2's cache **keeps the interpreter's direct `opcode.interpret()` virtual call** and only removes the
  *decode* work. Gain: ~19% (bundled with LTO).
- Dolphin's cached interpreter **replaces the interpreter loop with a callback stream**, which adds a new
  indirect call per interpreter step. Gain vs plain interpreter: ~3.3×, but the author concludes the
  per-instruction indirect branch caps it.

**Lesson**: predecoding is worth ~10-20%; restructuring into a callback stream buys more but caps out
because of dispatch misprediction. Neither closes a JIT-sized gap.

### 4.3 Avoiding redundant memory translation

Not independently measured in the sources I found, but the mechanism is well established in the code I read:

- **Fastmem / 4 GB virtual-address reservation**: lets guest→host translation be inlined as a load/store
  with no per-access software check. ARMSX2's no-JIT mode **cannot use it** ("No-JIT execution does not emit
  fastmem accesses, so interpreter-only sessions skip the 4 GB virtual-address reservation and force fastmem
  off"). So the interpreter pays software TLB cost on *every* memory access that the JIT does not.
- **`vtlb_memSafeCmpBytes`** (`vtlb.cpp:384`) is the interpreter's safe way to peek at guest memory — it
  walks `vtlbdata.vmap[mem >> VTLB_PAGE_BITS]` page by page and `memcmp`s. The ARMSX2 block cache calls this
  **per block reuse**, i.e. it is a per-iteration software TLB walk that a JIT would not pay. This is a
  concrete reason the block cache's gain is limited, and a candidate for optimization (e.g. a validated-but-
  not-revalidated scheme gated on a memory-write epoch counter).
- PCSX2's `intMemcheck` / `MEMTYPE_*` switch (`Interpreter.cpp:147`) adds another per-load/store branch
  layer that the JIT resolves at compile time.
- PCSX2's own source comment quantifies the cost of adding debug instrumentation to the hot path:
  > "execI is called for every instruction so it must remains as light as possible. If you enable the next
  > define, Interpreter will be much slower (around **~4fps on 3.9GHz Haswell vs ~8fps** (even 10fps on dev
  > build))"
  → a **~2× penalty** from adding breakpoint/memcheck logic per instruction. This is direct primary-source
  evidence of how sensitive the interpreter loop is to per-instruction overhead.

### 4.4 Register allocation / caching

No published interpreter-specific numbers found in the sources surveyed. The general principle (keep guest
registers in host registers or in a hot cache line; avoid struct round-trips) is standard, but I have **no
measured figure** to cite and will not invent one. PPSSPP's IR gives each op explicit register operands
(`IRInst` carries op + regs + constant), which is the standard enabler; the JIT allocates host registers
from it, the interpreter does not.

### 4.5 Superinstructions / instruction fusion

ARMSX2 lists "EE superinstructions" as an **evaluated POC that was not landed**. Dolphin's PR title
"Combine instructions if possible" appears in the (closed, "objectively a lot slower") #12750 branch.
**No published positive measured gain found.** Flag as unproven for this workload.

### 4.6 Published JIT-vs-interpreter ratios (emulation-specific)

| Source | Ratio |
|---|---|
| Dolphin wiki | interpreter costs **"tenfold or more"** vs the fastest option (JIT) |
| DolphiniOS (OatmealDome) | "**many times slower** than the JIT recompiler… basically unplayable" |
| Dolphin PR #2784 | cached interp ~10fps vs plain interp 3fps (cached ≈ 3.3× plain) → implies plain interp is far below 10fps where JIT plays at 30/60 |
| ARMSX2 commit | "**materially slower** than a valid ARM64 recompiler… not parity with JIT" |
| PPSSPP | **no ratio published**; instead "fast enough… the PSP CPU is not that expensive to emulate" |

**Rule of thumb, labeled as such**: for non-trivial guests, expect an interpreter to be **≈10× slower than a
good JIT**, and the ceiling achievable through interpreter micro-optimization to be roughly **1.2-3.5×** over
a naive interpreter. That leaves an unfilled gap of roughly **3-8×** — which is why the PSP case works
(absolute speed sufficient) and the GameCube/Wii/PS2 case does not.

---

## 5. iOS / blocked-JIT workarounds

### 5.1 The rule and its current state

- Apple's App Review Guidelines restrict dynamically generated executable code; App Store apps generally
  cannot use JIT. DolphiniOS: *"Apple generally does not allow apps to use JIT recompilers on iOS. The only
  exceptions are Safari and alternative web browsers in Europe."* OatmealDome submitted a **DMA
  interoperability request** for JIT and **Apple denied it**.
- **`com.apple.developer.kernel.allow-jit`** is the formal entitlement; per the [Provenance Flycast issue
  #2799](https://github.com/Provenance-Emu/Provenance/issues/2799): *"The iOS 26 SDK introduces a more formal
  path for JIT via `com.apple.developer.kernel.allow-jit`. This should be evaluated and used where
  possible."* **Note**: I could not fetch Apple's entitlement documentation page (request timed out), so I
  am reporting the entitlement name as cited by Provenance, not as verified against Apple's docs. Treat its
  practical availability to third parties as **unconfirmed** — the same issue notes the entitlement approach
  is under evaluation, and Flycast remains interpreter-only.
- The situation is **version-dependent and changes frequently**. StikDebug's compatibility table
  ([README](https://raw.githubusercontent.com/StikDebug/StikDebug/main/README.md)) shows iOS 17.4-18.x
  "fully supported", iOS 26.0+ "Supported — Limited App Availability (Developers need to update their apps
  to work.)", and 1.0-17.3.x "Not supported". Date all claims.

### 5.2 The debugger-attach workaround (the main practical route)

**StikDebug** ([GitHub](https://github.com/StikDebug/StikDebug)): *"Enable Just In Time compilation for
sideloaded apps that have the `get-task-allow` entitlement."* It works by attaching as a debugger to a
**sideloaded** (development-signed) app — a debugger can mark memory executable on the target's behalf — so
apps with `get-task-allow` get JIT without a jailbreak. Requirements: a pairing file, a loopback VPN
(LocalDevVPN), and a sideload tool (SideStore/AltStore) for refreshing. It also has "Scripts: Manage
automation scripts (mainly used for **iOS 26 JIT**)."

**This is exactly the mechanism ARMSX2 relies on** — ARMSX2's JIT gate checks `CS_DEBUGGED`, which is the
flag a debugger attach sets. Hence ARMSX2's ~30-60s idle revocation problem and its keep-alive canary.

**Limitation**: this works only for sideloaded/development-signed apps, **not** for App Store distribution.
It cannot be the basis of a commercial App Store release.

**HPS2 parallel**: the HPS2 project's own `docs/jit-verdict.md` shows the equivalent question for HarmonyOS
was settled by **direct on-device experiment** — `mmap(RW)` → write AArch64 → `mprotect(RX)` → icache flush
→ execute, returning 123, with zero AVC denials across 3 runs, code re-patching (RX→RW→RX) working, and
cross-thread execution working. Critically it also found `MAP_JIT`/FORT returns **`EINVAL` on real hardware**
(the policy predicts `hap_domain` is allowed anonymous executable memory). The open caveat recorded there
is that this was verified under a **debug-signed** build (`type=debug`, `apl=normal`); **release-signature JIT
availability is still unverified.** That is the single most important open question for HPS2, and it mirrors
the iOS `get-task-allow` situation closely.

### 5.3 Cases of shipped interpreter-only emulators on iOS

| Emulator | Status | Performance |
|---|---|---|
| **PPSSPP** | **On the App Store, interpreter-only** | Full speed for nearly all PSP games |
| **Flycast** (via Provenance) | Interpreter-only; JIT issue open and labelled **blocker** | "Performance on complex Dreamcast games suffers" |
| **Dolphin / DolphiniOS** | Not on App Store; maintainer explains why | Interpreter "basically unplayable" on iPhone 15 Pro Max |
| **Provenance** (multi-system) | Ships cores in whatever mode is available | Varies by core; has `PVJITRequirement` / `DOLJitManager` infrastructure |

**The lesson is consistent**: interpreter-only ships successfully **only** where the guest CPU is cheap to
emulate (PSP). Where the guest is expensive (GameCube/Wii, Dreamcast's SH-4 + PowerVR, PS2), interpreter-only
is either not shipped or shipped as a known-bad experience.

**Note on file-backed executable mappings**: I found **no documented case** of an emulator obtaining
executable memory via a file-backed mapping of an already-signed binary as a general workaround. The
practical routes are the debugger-attach route (§5.2) and the formal entitlement (§5.1). AOT/precompilation
at install time was **not** documented in the sources surveyed. Do not present either as an available option
without further verification.

---

## 6. Direct answer: is a playable PS2 emulator without JIT feasible?

**No — not with any currently published technique, and the gap is too large to close by interpreter tuning.**

Reasoning chain, all grounded in the sources above:

1. **The workload is the problem, not the interpreter.** PPSSPP succeeds because, in its author's words,
   "the PSP CPU is not that expensive to emulate." The PS2 EE is a 294 MHz MIPS R5900 with 128-bit MMI SIMD,
   plus VU0 and VU1 vector coprocessors, plus the IOP, plus DMA/VIF. That is a much larger per-cycle host
   workload.
2. **Empirically, no-JIT PS2 is already unplayable and only marginally improvable.** ARMSX2's own commit
   states "No-JIT remains materially slower than a valid ARM64 recompiler… not parity with JIT." Its best
   measured win is **−18.6% EE time** (bundled with ThinLTO).
3. **Known remaining techniques are small relative to the gap.** ARMSX2 evaluated and did **not** land
   direct threading and superinstructions. Published numbers for these on other interpreters:
   computed goto **+10-20%** (CPython: up to 15-20%; Lua: ~10%); devirtualization **~10%** (Dolphin #13951).
   Even stacking all of them optimistically gives maybe **1.5-2×** on top of ARMSX2's baseline — against a
   gap the Dolphin wiki calls "tenfold or more."
4. **The structural ceiling is dispatch misprediction.** Dolphin's own Cached Interpreter author concluded
   the approach is "flawed" because "the unpredictable branch every few tens of host instructions is
   cratering the performance." More aggressive interpreter designs hit this wall.

### Concrete techniques, ranked by measured gain (for a R5900 interpreter in C++)

| Rank | Technique | Measured gain | Risk / notes |
|---|---|---|---|
| 1 | **Computed goto / direct threading** | **+10-20%** typical (CPython 15-20%, Lua 10%); up to ~2× vs switch on misprediction-heavy streams (Ertl) | Low risk; needs GCC/Clang `&&label` (available on OHOS clang 15). Avoid compiler cross-jumping. **ARMSX2 has this on its not-landed list.** |
| 2 | **Predecoded block cache** | **−18.6% EE time** (ARMSX2, incl. ThinLTO); **~3.3×** vs *plain* interp for Dolphin's callback-stream variant | Already landed in HPS2. Watch the per-reuse RAM-validation cost (`vtlb_memSafeCmpBytes`). |
| 3 | **Remove per-instruction overhead from the hot loop** | **~2× penalty** when added (PCSX2's own comment: 8fps → 4fps with debug checks) | Pure win if any such checks are conditionally compiled out in release. |
| 4 | **Devirtualize the hottest opcode handler** | **~10%** (Dolphin PR #13951) | Low risk, targeted. |
| 5 | **ThinLTO / interprocedural optimization of the core** | Bundled into ARMSX2's 18.6%; no isolated figure | Low risk. |
| 6 | **Superinstructions / fusion** | **No published positive gain**; ARMSX2 evaluated and did not land | Unproven. Label as speculative. |
| 7 | **Cheaper block validation (epoch/generation counter instead of per-reuse memcmp)** | Not published | Plausible but **speculative**; would need measurement. |

### Recommended framing for HPS2

- Keep the no-JIT path as a **boot/menu/diagnostic fallback with an explicit user-visible warning** —
  which is precisely what ARMSX2 shipped (`0bfc42d2a`, "Two-stage No-JIT warning and red in-game
  indicator"). Do not market it as gameplay.
- The ARMSX2 commit's capability-gating design (`SysMemory::HasCodeMemory()` gating EE/IOP/VU/VIF/SW-GS/
  fastmem/MTVU) is **correct engineering** and worth keeping regardless of playability — it converts a
  crash/black-screen into a graceful degraded boot.
- The highest-leverage uncertainty for HPS2 is **not** interpreter performance — it is whether
  **release-signed** builds retain JIT on target devices. `docs/jit-verdict.md` verified JIT only under
  `type=debug`. That question dominates everything in this report: if release-signature JIT works, no-JIT
  performance is nearly irrelevant; if it does not, no amount of interpreter tuning makes PS2 playable.
- If no-JIT must be improved anyway, the ordered, low-risk wins are: **(1) direct threading**,
  **(2) strip per-instruction debug overhead**, **(3) devirtualize hot handlers**, **(4) ThinLTO**.

---

## Appendix: source quality notes

- **Measured, primary, with numbers**: ARMSX2 commit `45368481b` (read directly from the repo);
  Dolphin wiki "tenfold or more"; Dolphin PR #2784 (3→10 fps); Dolphin PR #13951 (~10%); Dolphin PR #12723
  (+1.5-2 fps user reports); CPython 15-20%; Lua ~10%; Ertl cycles-per-dispatch tables; PCSX2 source comment
  (8fps→4fps).
- **Measured but not controlled**: ARMSX2's 37.55→30.55 ms — self-described as a user-observed device
  result, not a benchmark.
- **Qualitative primary**: PPSSPP App Store post; DolphiniOS App Store post; ARMSX2 commit's "not parity
  with JIT".
- **Not found / could not verify before deadline** (do not assert either way):
  - A numeric PPSSPP IR-interpreter-vs-JIT ratio (none appears to be published).
  - AetherSX2 / NetherSX2 documentation on interpreter-only modes.
  - Apple's `com.apple.developer.kernel.allow-jit` doc page (fetch timed out); entitlement name is cited
    from the Provenance issue.
  - Any published interpreter register-allocation speedup figure.
  - Whether `pcsx2-eerunner` has been used to produce a published JIT-vs-interp benchmark table.
- **Speculation, explicitly labeled**: that a generation-counter scheme would beat per-reuse `memcmp`
  validation (§6 row 7); that stacking the ranked techniques would yield ~1.5-2× (arithmetic on individual
  published figures, not a measured combined result).
