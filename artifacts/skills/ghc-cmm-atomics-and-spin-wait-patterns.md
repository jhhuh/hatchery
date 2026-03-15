# GHC Cmm Atomics and Spin-Wait Patterns

## Cmm Memory Ordering

GHC Cmm supports `%acquire`, `%release`, `%relaxed` annotations on memory accesses, but **only with `W_` (machine word) type**:

```cmm
x = %acquire W_[addr];      // works
x = %acquire bits32[addr];   // PARSE ERROR
x = bits32[addr];            // works (plain load, no ordering annotation)
```

On x86_64 this is fine — plain loads/stores are naturally acquire/release (TSO). On ARM, you'd need to load as `W_` and mask for sub-word acquire semantics.

## GHC RTS Atomic Primitives (stg/SMP.h)

The RTS provides C macros for atomics:
- `ACQUIRE_LOAD(ptr)`, `RELEASE_STORE(ptr,val)` — acquire/release
- `RELAXED_LOAD(ptr)`, `RELAXED_STORE(ptr,val)` — relaxed
- `SEQ_CST_LOAD(ptr)`, `SEQ_CST_STORE(ptr,val)` — seq_cst
- `busy_wait_nop()` — `rep; nop` (PAUSE on x86)
- `cas()`, `xchg()` — CAS and exchange

**These are guarded by `#if !IN_STG_CODE`** — they cannot be used directly from Cmm. Cmm can call them via `ccall` but that adds function call overhead.

## ghc-prim C Fallbacks (stg/Prim.h)

For sub-word atomics, ghc-prim provides C functions callable from Cmm:
- `hs_atomicread32(addr)` — seq_cst 32-bit atomic read
- `hs_atomicwrite32(addr, val)` — seq_cst 32-bit atomic write
- Also 8/16/64-bit variants

These are **seq_cst** only. Overkill for spin loops on x86 but correct everywhere.

## PAUSE Instruction

`busy_wait_nop()` emits `rep; nop` (= PAUSE). On Intel:
- Pre-Skylake: ~10 cycles
- Skylake+: ~140 cycles

**PAUSE is expensive.** For ultra-low-latency spin loops, omitting PAUSE gives better latency at the cost of:
1. Higher power consumption
2. Worse behavior on hyperthreaded cores (steals pipeline resources from sibling thread)
3. May cause memory ordering pipeline flushes when the waited-on value changes

For hatchery's pre-loaded worker dispatch (~500ns target), PAUSE would dominate the loop. Omitting it is the right call when latency matters more than power.

## inline-cmm Patterns

### Multi-return values
`[cmm|...|]` quasiquoter only parses single return type. For multiple returns, use `verbatim` + manual `foreign import prim`:

```haskell
verbatim "my_func (W_ a, W_ b) { return (a + b, a - b); }"
foreign import prim "my_func" my_func# :: Addr# -> Word# -> (# Word#, Word# #)
```

### Cmm.h include
`W_` is defined by `Cmm.h`. Without it, use `bits32`/`bits64`/`W_` directly.
```haskell
include "\"Cmm.h\""  -- must come before verbatim blocks
```
