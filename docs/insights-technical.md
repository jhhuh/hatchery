# Design Insights & Reasoning Chains

These are the insights, rejected alternatives, and reasoning chains from the design session that produced the Egg/Object architecture. Not structured as a spec — structured as a thinking trail for future sessions.

## The Starting Problem

Hatchery v1 baked too much into the core. Workers executed `int fn(void)` — no arguments, no structured I/O. The ring buffer had hardcoded fields (exit_code, result bytes). The only axis of variation was injection method (process_vm_writev vs memfd). Everything about "what does the payload look like" and "how do I pass input and read output" was left to the consumer with no abstraction.

The core insight: **hatchery should be payload-agnostic**. A specific strategy of handling input and output should be addressed at a higher abstraction. But the low-level library should "open the hatch" for such possibilities.

## The Type Signature That Started Everything

Early in the discussion, this type was proposed:

```haskell
_ :: Image -> (in -> (Image -> m Image)) -> (Image -> m (out, Image)) -> m (in -> m out)
```

Reading this: given an initial Image, an injector (that encodes input into the Image), and an extractor (that decodes output from the Image), produce a callable function.

This was the seed. It implied:
- Image is mutable state
- Injector and extractor are strategies provided by the consumer
- The current hardcoded approach is just one strategy among many

## Image Has Three Components

Image isn't just "a pointer to some memory." It has structure:

1. **Execution context** — registers, stack pointer. The CPU state of the worker.
2. **Opaque blob** — a small shared memory region. The I/O channel.
3. **Polymorphic `s`** — everything else about the worker state that hatchery doesn't know about yet.

The third component was important: it keeps Image open for extension without modifying hatchery's core types. But we eventually decided `s` should be the PrimMonad state token (like in `MutableByteArray s` or `STRef s`), and extra consumer state should live in the monad (via `ReaderT` etc.), not in Image. This is simpler and prevents Image from becoming a kitchen-sink type.

## "Observation Mutates" — The Key Semantic Insight

This was the turning point that killed the `Ref`/`IORef` analogy.

In a sandbox backed by a live process, there is no such thing as a pure read. Reading a register might require stopping the process. Reading memory might involve a syscall with side effects. Even checking if the worker is alive can reap a zombie (changing process table state). Probing shared memory has cache-line effects.

This isn't just an implementation detail — it's a fundamental property of the system. The abstraction should reflect it. Any interface that separates "read" from "write" (like `readRef`/`writeRef`) is lying about the semantics.

This insight killed several candidate abstractions:
- `data Ref m a = Ref { readRef :: m a, writeRef :: a -> m () }` — pretends read is non-destructive
- Traditional lens (`Lens' s a`) — too pure
- Even `IORef`-style mutable refs — they don't capture the entanglement between different parts of state

### What "Observation Mutates" Means for the API

Every interaction with the system is a **step** that:
1. Takes input (what you're asking/sending)
2. Produces output (what you observe/receive)
3. Transitions the state (the system is different after)

There's no way to "peek" without "stepping." This is Mealy machine semantics.

## The Machine Connection

Edward Kmett's `machines` package defines:

```haskell
newtype MachineT m k o = MachineT { runMachineT :: m (Step k o (MachineT m k o)) }

data Step k o r
  = Stop
  | Yield o r
  | forall t. Await (t -> r) (k t) r
```

This captures stateful step-by-step computation with monadic effects. The `k` parameter is a GADT of requests — each `Await` asks for a value of type `t` via a request `k t`. The existential `t` makes this type-safe: the continuation must accept whatever type the request promises.

Machine was a perfect model for the "observation mutates" semantics: each `step` is an `m` action, and the continuation `r` is the new machine after the interaction. No "peek without advancing."

**But Machine has a fatal flaw for our use case: it has no methods.** Machine's only interface is `step :: m (Step ...)`. You can advance it, but you can't send it typed requests from the outside. Machine is demand-driven (it pulls input via `Await`); we need something call-driven (the user pushes typed commands).

## Object: Machine + Methods = Coalgebra

The fix: take Machine's state semantics but add a typed method interface.

```haskell
data Object f m = Object
  { method :: forall t. f t -> m (t, Object f m)
  }
```

This is a **coalgebraic object**. In coalgebraic semantics, objects are defined not by how you construct them (algebraic) but by how you observe them (coalgebraic). The GADT `f` defines the observations (methods). Each observation transitions the state and produces a result.

The key difference from Machine:
- Machine: `Await` — machine requests input (pull/demand-driven)
- Object: `method` — caller sends request (push/call-driven)
- Same state semantics, opposite control flow

The returned `Object f m` after each call IS the new state. The old object is conceptually gone. This naturally captures "observation mutates" — you literally get a different object back.

### Why Not Just Direct Functions?

We considered just exposing `readReg :: Computer -> Register -> IO Word64` etc. — direct effectful functions on a mutable handle. This works but loses something: the Object type makes the "new state after each interaction" explicit in the types. With direct functions, mutation is hidden inside IO. With Object, the type `m (t, Object f m)` tells you: "you get a result AND a new object." Even if the implementation reuses the same mutable state, the type communicates the semantics.

## The Free Monad Detour (and Why We Came Back)

We briefly explored modeling strategies as free monad programs over the Interaction GADT:

```haskell
data Program a where
  Done :: a -> Program a
  Then :: Interaction t -> (t -> Program a) -> Program a
```

A strategy would be a Program — a script that describes a sequence of interactions with the computer. Hatchery would interpret the script against a real worker.

**Pros**: inspectable (analyze before running), testable (interpret against a mock), composable.

**Why we rejected it**: "We cannot interact with it." A pure Program is a batch script. You write it, hand it off, get the final result. You can't do IO between steps. You can't make Haskell-side decisions based on intermediate results in real time.

Adding `m` via `FreeT Interaction m a` gets interactivity back, but then you lose inspectability (the `Lift` nodes are opaque `m` actions). At that point, `FreeT Interaction m a ≈ ReaderT Computer m a` — the indirection no longer pays for itself.

**The lesson**: the sandbox is something you **interact with**, not something you **program**. The Object model (direct method calls, full IO interleaving) is the right abstraction.

## Egg: The Reification Recipe

The name comes from the project name (hatchery). An Egg is a blueprint that you give to the hatchery; the hatchery hatches it into a live Object.

An Egg carries two things:

1. **The seed** (`eConfig` / `WorkerConfig`) — a concrete, value-level blob describing the initial physical state: memory layout, security policy, resource limits. The material from which the object is born.

2. **The GADT method list** (`f`) paired with its interpreter (`img -> f ~> IO`) — the behavioral specification. The GADT defines WHAT methods exist (at the type level). The interpreter defines HOW each method maps to concrete operations on the backend's Image (at the value level).

```haskell
data Egg img f = Egg
  { eConfig      :: WorkerConfig
  , eInterpreter :: img -> f ~> IO
  }
```

This is a **type-safe object factory**. The GADT ensures method signatures are statically checked. The interpreter provides dynamic behavior. The seed provides the physical substrate.

### Why Egg Is Novel

The standard Haskell pattern for "thing with typed methods" is a typeclass. But typeclasses are:
- Resolved at compile time (no runtime composition)
- One instance per type (no multiple configurations)
- Global (you can't have two different "CCall" instances with different register mappings)

The Egg pattern gives you:
- Runtime composition (combine two Eggs via `:+:`)
- Multiple configurations (same GADT, different interpreters — System V vs Win64)
- First-class values (store in data structures, pass as arguments)
- Type safety (GADT constrains method signatures)

It's a **reified typeclass dictionary** with a factory method. But "reified typeclass dictionary" doesn't capture the full picture — the Egg also carries the seed (configuration), and the hatching process (resource allocation) is part of the abstraction.

## CCall as Concrete Egg — ABI Lives in the Interpreter

The C calling convention (System V AMD64) becomes one concrete Egg. The GADT defines abstract operations (`SetArg 0 value`, `Call`, `GetReturn`). The interpreter maps these to registers:

```
SetArg 0 → RDI
SetArg 1 → RSI
SetArg 2 → RDX
...
```

The ABI knowledge is **entirely in the interpreter**. The GADT doesn't know about registers. This means:
- Same GADT, different interpreter → different ABI (Win64 uses RCX, RDX, R8, R9)
- The GADT is the abstract calling convention; the interpreter is the concrete ABI binding
- You could write a `genericCallEgg :: ArchConfig -> Egg img CCall` that takes ABI parameters

This is also how you'd support stack spill for > 6 integer args: the interpreter checks the arg index and either writes a register or writes to the stack region in shared memory.

## Hatchery as Typeclass — What We Built Is One Backend

Late realization: everything we built in v1 (fork server, seccomp, x86-64 namespaces, memfd, ring buffer, spin-wait) is a **specific isolation mechanism**, not the platform itself. Other mechanisms could provide the same Image-based interface:

- KVM (hardware virtualization)
- WASM runtime
- Remote workers on another machine
- Mock/simulation for testing

Making Hatchery a typeclass with associated types (`HatchPool`, `HatchConfig`, `HatchImage`) means Eggs can be written polymorphically over backends, or tied to specific ones.

The typeclass is appropriate here (unlike for Eggs) because the backend is a **compile-time / deployment-time choice**. You don't dynamically switch between "linux namespace" and "KVM" at runtime. The dynamic flexibility lives in the Egg/Object layer.

## Hybrid Static/Dynamic — Records + Typeclasses

We wanted both:
- **Static dispatch** for known strategies (typeclass, nice syntax, compiler specialization)
- **Dynamic dispatch** for runtime composition (records, first-class values)

The solution: **the core API takes records, the typeclass converts to records**.

```haskell
-- Record: the universal runtime representation
data Egg img f = Egg { ... }

-- Typeclass: sugar for producing records from types
class IsEgg s where
  type Methods s :: * -> *
  toEgg :: s -> Egg (EggImage s) (Methods s)
```

Functions accept `Egg` values. The typeclass just provides a convenient way to produce them from type-level descriptions. This means:
- You can always pass an Egg directly (dynamic)
- You can use the typeclass for ergonomics (static)
- Under the hood, both paths produce the same Egg record

**Why this matters**: typeclasses are resolved at compile time, so you can't compose them at runtime. Records are first-class values — store them, pass them, combine them. By making the record primary, we keep full runtime flexibility.

## Patterns We Explored and Rejected

### Handle Pattern
```haskell
data Sandbox m in out = Sandbox { call :: in -> m out, close :: m () }
```
Closures capture Image internally. Consumer never sees Image. **Rejected because**: the user needs Image access for strategies that touch registers, memory, etc. Hides Image too much.

### Backpack (Module-Level Abstraction)
GHC Backpack: define a module signature, swap implementations at link time. Zero runtime cost. **Rejected because**: purely static — no dynamic dispatch at all. Backpack tooling is also less mature.

### Tagless Final
```haskell
class MonadSandbox m where
  type SIn m; type SOut m
  inject :: SIn m -> Image -> m ()
```
The monad itself carries the strategy. **Rejected because**: forces consumers into a specific effect stack. Doesn't compose dynamically without existentials.

### Lens/Optics for Image Access
Traditional `Lens' Image a` or even monadic lenses. **Rejected because**: "observation mutates" breaks the lens laws (get-put, put-get). Lenses assume a clean separation between reading and writing that doesn't exist here.

### Ref/IORef for Image Fields
```haskell
data Ref m a = Ref { readRef :: m a, writeRef :: a -> m () }
```
**Rejected because**: pretends read is non-destructive. Semantically wrong for a system where probing state changes state.

### Port/Mealy Machine
```haskell
newtype Port m a b = Port { interact :: a -> m b }
```
Every interaction takes input, produces output. Close to the right semantics. **Evolved into Object**: Port doesn't capture the "new state after interaction" aspect. Object adds the returned `Object f m` to make state transitions explicit.

## PrimMonad and the `s` Parameter

Image is tied to its monadic context via `s ~ PrimState m`, the same pattern as `MutableByteArray s` and `STRef s`. This gives:

1. **Safety**: Image can't escape its scope (if we provide a `runSandbox :: (forall s. ...) -> a` entry point)
2. **Polymorphism**: Same operations work in IO and potentially ST (for testing)

We considered making `s` also carry "extra consumer state" (GPU handles, etc.), but decided against it. Extra state lives in the monad (`ReaderT GpuContext IO`). This keeps Image focused on what hatchery owns (process state, shared memory, registers) and doesn't bloat the type.

## Register Access — The Fork Server Change

The biggest concrete change v2 requires: workers need a **register save area** in shared memory. Currently, the worker just calls `fn()` and writes the exit code. For the Object model to support `ReadReg`/`WriteReg`:

1. Before execution: worker loads register values FROM the save area (so Haskell can set up arguments)
2. After execution: worker saves register values TO the save area (so Haskell can read results)

This is conceptually similar to how KVM exposes `struct kvm_regs` — the register file is a shared data structure that the host and guest exchange through.

The save area would include GP registers (RAX through R15), XMM registers (XMM0-XMM7 for floating-point args/returns), RFLAGS, and RSP. Cache-line aligned for performance.

## Composition via Coproduct

Method lists compose via sum type:

```haskell
data (f :+: g) t where
  L :: f t -> (f :+: g) t
  R :: g t -> (f :+: g) t
```

Two Eggs combine into one: `combine :: Egg img f -> Egg img g -> Egg img (f :+: g)`.

This is the coalgebraic analogue of mixin composition. The object supports methods from both `f` and `g`. Each method dispatches to the appropriate interpreter.

Concrete example: `RawX86 :+: DebugOps` — an object that can both execute code AND inspect registers/memory for debugging. Built from two independent Eggs.

**Open question for implementation**: deeply nested `:+:` creates pattern match overhead. For performance-critical paths, a flat sum type (single GADT with all methods) might be better. The `:+:` composition is for modularity; the flat GADT is for performance. Both should be possible.

## The Naming

- **Hatchery**: the incubator / platform / backend
- **Egg**: the blueprint you give to the hatchery
- **Object**: the live thing that hatches out
- **Image**: the object's internal physical state (like a VM image)
- **Seed**: the concrete configuration inside the Egg (like the yolk — the material)
- **Method list**: the GADT — what the object can do (like the DNA — the specification)
- **Interpreter**: maps methods to effects (like gene expression — specification → behavior)

## What the v1 Implementation Becomes

The fork server, seccomp, ring buffer, spin-wait, all the C code — that's `LinuxWorkerPool`, one instance of the `Hatchery` typeclass. The `hatchery-linux` package.

Its Image type (`LinuxImage`) would expose the shared memory regions, register save area, code region, and worker process handle. Its `hatch` implementation would acquire a worker from the pool, wire the Egg's interpreter to the LinuxImage, and return an Object.

The spin-wait (~365ns) and futex (~3100ns) dispatch latency numbers are properties of THIS backend — not inherent to the Object model. Other backends would have different performance characteristics.

## Open Questions for Implementation

1. **Object linearity**: Currently Object returns itself after each call, but nothing prevents the user from using the "old" Object reference. Should we use linear types (`Linear Haskell`) to enforce that each Object is used exactly once? Or is this YAGNI?

2. **Error handling in methods**: What happens when a method fails? Currently `m` is IO so exceptions work. But should the Object type encode failure explicitly? `f t -> m (Either Error t, Object f m)`? Or is that over-engineering?

3. **Worker pool vs single worker**: The current design assumes `hatch` gives you one Object backed by one worker. But the v1 pool auto-selects workers. Should there be a pool-level dispatch that borrows a worker, runs a strategy, returns it? Probably yes — that's the `dispatch` function that takes a Strategy + Egg and handles worker lifecycle internally.

4. **Lifecycle and GC**: When an Object is garbage collected without explicit `destroy`, what happens to the worker? `destroy` should release it back to the pool. A finalizer on the Image could handle this, but GHC finalizers are unreliable for timely cleanup. The bracket pattern (`withComputer`) is safer.

5. **Performance of the Object pattern**: Each method call goes through `method obj msg` → interpreter → concrete operations. For spin-wait dispatch at 365ns, is the Object indirection measurable? Probably not — the cross-process cache-line round-trip dominates. But worth measuring.

6. **Egg validation**: Should `hatch` validate that the Egg's config is compatible with the backend? E.g., requesting XMM register access on a backend that doesn't support it. Static (type-level) validation would be ideal but might require type-level machinery. Runtime validation is simpler.

---

*Session: 2026-03-15, Claude Opus 4.6. Model ID: claude-opus-4-6[1m]. Session ID: 919c38de-05cd-402c-bbf5-e3dba6df4a9c.*
*Conversation flow: payload-agnostic hatchery → Image with three components → opaque effectful lens → observation mutates → Machine type connection → coalgebraic Object → Egg reification → Hatchery typeclass → clean master.*
