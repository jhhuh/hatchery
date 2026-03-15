# hatchery [WIP — redesigning from new foundations]

Type-safe sandboxed computation via coalgebraic objects.

> **Status**: This project is being rebuilt from scratch around a new type-theoretic foundation. The previous implementation (pool of pre-spawned worker processes with ~365ns spin-wait dispatch) is frozen on [`v1-worker-pool`](../../tree/v1-worker-pool). No source code on master yet — only the design document and README below.

Hatchery models isolated execution as an **abstract computer**: you define a blueprint (an Egg), hatch it into a live mutable object, and interact with it through typed methods. The object is backed by process isolation, but the abstraction is general — the same Egg/Object interface can target different backends.

## Core Concepts

### Object: Coalgebraic Mutable Machine

An Object is defined not by its internal state but by its **observable behavior** — a set of typed methods, each of which mutates the object and returns a result.

```haskell
data Object f m = Object
  { method :: forall t. f t -> m (t, Object f m)
  }
```

Every interaction — even observation — mutates. There is no pure read. The returned `Object` is the machine after the state transition. This reflects physical reality: the object is backed by a live process where reading a register or probing memory are effectful operations that transition the system.

The GADT `f` defines the method list. Each constructor is a typed method:

```haskell
data CCall t where
  LoadFunction :: ByteString -> CCall ()
  SetArg       :: Word8 -> Word64 -> CCall ()
  Call         :: CCall ExecStatus
  GetReturn    :: CCall Word64
```

### Egg: Reification Recipe

An Egg is the blueprint for a live object. It fuses two things:

1. **A seed** — concrete configuration for the physical resources (memory layout, security policy, resource limits)
2. **A GADT method list + interpreter** — the abstract behavioral specification paired with its implementation as a natural transformation `f ~> IO`

```haskell
data Egg img f = Egg
  { eConfig      :: WorkerConfig
  , eInterpreter :: img -> f ~> IO
  }
```

The `hatch` operation reifies this into a live `Object f m` by allocating resources from the seed and wiring the interpreter to the mutable Image.

### Hatchery: Backend Typeclass

Hatchery is a typeclass — not a concrete implementation. It defines the capability to incubate eggs into objects. Different backends provide different isolation mechanisms.

```haskell
class Hatchery h where
  type HatchPool h
  type HatchConfig h
  type HatchImage h
  withPool :: HatchConfig h -> (HatchPool h -> IO a) -> IO a
  hatch    :: HatchPool h -> Egg (HatchImage h) f -> IO (Object f IO)
```

### Compositionality

Method lists compose via coproduct. An `(f :+: g)` object supports methods from both `f` and `g`:

```haskell
combine :: Egg img f -> Egg img g -> Egg img (f :+: g)
```

## Example

```haskell
main = withPool defaultConfig $ \pool -> do
  -- Hatch a C-calling-convention computer
  calc <- hatch pool ccallEgg

  -- Load a compiled function, set arguments, call it
  (_, c) <- call calc (LoadFunction addCode)
  (_, c) <- call c (SetArg 0 17)
  (_, c) <- call c (SetArg 1 25)
  (_, c) <- call c Call
  (answer, _) <- call c GetReturn   -- 42
  print answer
```

Or with raw machine code:

```haskell
main = withPool defaultConfig $ \pool -> do
  computer <- hatch pool rawX86Egg

  -- mov eax, 42; ret
  let code = BS.pack [0xb8, 0x2a, 0x00, 0x00, 0x00, 0xc3]
  (_, c) <- call computer (Inject code)
  (status, c) <- call c Run
  (result, _) <- call c Result
  print result  -- (42, Nothing)
```

## Packages

| Package | Description |
|---|---|
| **hatchery** | Core abstractions: `Object`, `Egg`, `Hatchery` typeclass, compositional combinators |
| **hatchery-linux** | `LinuxWorkerPool` backend: fork server, seccomp, x86-64 process isolation |
| **hatchery-ccall** | `CCall` egg: System V AMD64, register mappings, calling conventions |
| **hatchery-bench** | Benchmarks |
| **hatchery-llvm** | LLVM IR to machine code bridge via `llvm-tf` (stub) |
| **trustless-ffi** | High-level typed FFI built on CCall egg |

## LinuxWorkerPool Backend

The `hatchery-linux` package provides a concrete `Hatchery` instance using pre-spawned worker processes with seccomp filtering on Linux x86-64.

```
GHC Process (Haskell)
  │
  │  socketpair (control)     pipe (parent-liveness)
  │
  └──► Fork Server            static-PIE C binary, embedded at TH time
        │                     single-threaded, epoll, no libc, raw syscalls
        │
        ├──► Worker 0         own address space, seccomp-filtered
        ├──► Worker 1         spin/futex-suspended until dispatch
        └──► ...              PROT_RWX code region + MAP_SHARED ring buffer
```

### Measured latency (return 42, 100k iterations)

```
foreign import prim:       0.3 ns/call  (register shuffle, no stack frame)
unsafe ccall:              1.4 ns/call  (C ABI overhead)
safe ccall:               68   ns/call  (releases GHC capability)
hatchery (spin-wait Cmm): 365  ns/call  (Cmm spin, no futex syscalls)
hatchery (spin-wait C):   370  ns/call  (C spin, GCC-inlined atomics)
hatchery (pre-loaded):   3100  ns/call  (direct futex wake/wait)
hatchery (vm_writev):    5500  ns/call  (code injection + fork server relay)
hatchery (memfd):        5950  ns/call  (code injection + fork server relay)
```

### Platform requirements

- Linux x86-64
- Kernel >= 5.3 (`pidfd_open`)
- Kernel >= 3.17 (`memfd_create`)

## Building

Requires Nix. The flake provides GHC, musl cross-compiler, LLVM 19, and all Haskell dependencies.

```bash
nix build .#hatchery
nix build .#hatchery-bench
nix develop -c cabal build all
```

## Status

**Rebuilding from new foundations.** The previous implementation (pool of worker processes with hardcoded `int fn(void)` dispatch) is frozen on the [`v1-worker-pool`](../../tree/v1-worker-pool) branch. The core sandbox machinery (fork server, spin-wait, ring buffer IPC) is proven and its latency characteristics are well-understood — it becomes the `LinuxWorkerPool` backend instance of the new `Hatchery` typeclass.

The new architecture introduces payload-agnostic abstractions:
- `Object f m` — coalgebraic mutable machine with typed GADT methods
- `Egg img f` — reification recipe pairing concrete seed with abstract method list
- `Hatchery h` — typeclass for sandbox backends

See [`docs/design.md`](docs/design.md) for the full design document.

## License

BSD-3-Clause
