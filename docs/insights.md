# How We Got Here

Notes from the design session that produced the Egg/Object architecture. Written as a conversation trail — the way things actually unfolded, not the cleaned-up version.

## It Started with Frustration

We'd built a working sandbox. Fork server, spin-wait at 365ns, the whole thing. It worked. But something was wrong at the level of the abstractions.

The user put it plainly: "hatchery needs to be more payload agnostic, but we put too much of design's in that level." The v1 API had `dispatch :: Hatchery -> InjectionMethod -> ByteString -> IO DispatchResult` — you shoved raw machine code in, you got an exit code out. That was the only interaction shape. If you wanted to pass arguments to your sandboxed code, you had to hand-assemble argument passing into your machine code. If you wanted structured output, you had to manually read the ring buffer data region and know the layout.

The core sandbox was doing double duty: managing process isolation (its real job) AND defining the I/O protocol (not its job).

## A Type Signature Sketch Changed Everything

The user sketched a type signature on the fly:

```haskell
_ :: Image -> (in -> (Image -> m Image)) -> (Image -> m (out, Image)) -> m (in -> m out)
```

This was rough, the user said it was "one-time usage only" and would need changes. But it captured something crucial: the I/O strategy (how you encode input, how you decode output) should be **parameters**, not hardcoded behavior. The sandbox provides the Image; the consumer provides the lens into it.

This one line reframed the entire project.

## Chasing the Right Abstraction for Image Access

We went through a whole journey trying to figure out how to interact with Image.

**First try: `Ref` (like IORef)**
```haskell
data Ref m a = Ref { readRef :: m a, writeRef :: a -> m () }
```
Seemed natural. Image has fields, each field is a Ref. But the user said something that stopped us cold:

> "It is an mutable object. Observation on it inevitably mutate it."

This killed `Ref`. In a sandbox backed by a live process, reading a register might require stopping the process. Checking if a worker is alive might reap a zombie. Even shared memory reads have cache-line effects. There is no non-destructive observation. `readRef`/`writeRef` pretends there is — it's a lie.

**Second try: Optics/Lenses**
Traditional `Lens' s a`. Even monadic variants. Rejected for the same reason — lenses assume get-put/put-get laws that don't hold when observation mutates.

**Third try: Port (Mealy machine)**
```haskell
newtype Port m a b = Port { interact :: a -> m b }
```
Getting warmer — every interaction is effectful, takes input, produces output. But it doesn't capture the fact that the object *changes* after each interaction. You interact with a Port and it's the same Port. But our sandbox is different after every touch.

## "What is Machine type in machine package?"

The user asked this question and it cracked everything open.

Edward Kmett's `machines` gives us `MachineT m k o` — a step-by-step automaton where each step is monadic, the continuation IS the new machine, and the GADT `k` types the requests. Perfect state-change semantics.

But then the user pointed out: "Machine is a great abstraction for our mutable object, but it doesn't have method."

Machine has `step`. You can advance it. But you can't send it a typed `ReadReg RAX` request and get a `Word64` back. Machine is demand-driven (it pulls via `Await`); we needed something call-driven (the user pushes typed commands).

## The Object Falls Out

Take Machine's state semantics (each interaction produces a new machine) and add typed methods (a GADT defining what you can ask):

```haskell
data Object f m = Object
  { method :: forall t. f t -> m (t, Object f m)
  }
```

This is a **coalgebraic object** — defined by its observations, not its construction. The GADT `f` is the method list. Each method call returns a result AND the new object. The old object is gone.

When we wrote this down, the user's reaction was: "That is perfect!!!!!"

It captures everything:
- Observation mutates (you get a new Object back)
- Typed methods (GADT constrains inputs and outputs)
- Effectful (everything is in `m`)
- Stateful (the returned Object may behave differently)

## The Free Monad Detour

We briefly got excited about modeling strategies as free monad programs:

```haskell
data Program a where
  Done :: a -> Program a
  Then :: Interaction t -> (t -> Program a) -> Program a
```

Write a script of interactions, hand it to hatchery, get results. Inspectable! Testable! Composable!

The user brought us back to earth: "However, we cannot interact with it."

A pure `Program` is a batch job. You can't do IO between steps. You can't make real-time decisions based on intermediate results. Adding `m` via `FreeT` recovers interactivity but loses inspectability — at which point you've reinvented `ReaderT Computer m a` with extra steps.

The sandbox is something you **interact with in real time**, not something you **submit a script to**. Back to Object.

## Egg: Where Does the Object Come From?

The user connected it to the project's name: "If we provide an egg to hatchery, we get object as a return."

An Egg is a recipe for a live Object. It carries:

1. **A seed** — concrete worker configuration (memory layout, security policy). The physical material.
2. **A GADT method list + interpreter** — what the object can do and how each method maps to concrete operations. The behavioral specification.

```haskell
data Egg img f = Egg
  { eConfig      :: WorkerConfig
  , eInterpreter :: img -> f ~> IO
  }
```

The user emphasized: "Egg is also carrying type information GADT, a method list." The GADT isn't just a parameter — it IS the egg's identity. An `Egg img CCall` is a C-calling-convention egg. An `Egg img RawX86` is a raw-machine-code egg. The type tells you what will hatch.

### CCall: The First Concrete Egg

The C calling convention is one Egg type. The insight that made this click: **the ABI knowledge lives entirely in the interpreter**.

The GADT says `SetArg 0 value` — it doesn't say which register. The interpreter maps arg 0 → RDI (System V) or arg 0 → RCX (Win64). Same GADT, different interpreter, different ABI. You could parameterize the interpreter by architecture and get a generic calling convention egg.

## PrimMonad: Image Tied to Its Context

The user said: "I think m should be associated with s like in ST or IO monad, MonadPrim."

This was about safety. `Image s` where `s ~ PrimState m` — the same pattern as `STRef s` or `MutableByteArray s`. Image can't escape its monadic context. Extra consumer state (GPU handles, LLVM engines, whatever) lives in the monad via `ReaderT`, not in Image. Keeps Image focused.

## Hatchery as Typeclass: The Late Realization

Near the end, the user said: "Now Hatchery should be a typeclass, and what we've been making is a particular instance for pool of workers in a x86-64 linux namespace."

This reframed the entire v1 effort. The fork server, seccomp, ring buffer, spin-wait — that's not "hatchery." That's `LinuxWorkerPool`, one backend. Hatchery is the abstract capability to hatch eggs into objects.

```haskell
class Hatchery h where
  type HatchPool h
  type HatchConfig h
  type HatchImage h
  withPool :: HatchConfig h -> (HatchPool h -> IO a) -> IO a
  hatch    :: HatchPool h -> Egg (HatchImage h) f -> IO (Object f IO)
```

Other backends — KVM, WASM, a mock for testing — would be other instances. The 365ns spin-wait latency is a property of the linux backend, not of the abstraction.

## The Hybrid Static/Dynamic Pattern

The user wanted both typeclass ergonomics AND runtime flexibility: "Can we have hybrid system?"

The solution: **records as the core, typeclass as sugar**.

```haskell
-- The runtime value (always works, compose dynamically)
data Egg img f = Egg { ... }

-- The typeclass (convenience for known static strategies)
class IsEgg s where
  type Methods s :: * -> *
  toEgg :: s -> Egg (EggImage s) (Methods s)
```

The core API takes `Egg` records. The typeclass just produces them. You get static dispatch when you want it, dynamic composition when you need it. Under the hood, GHC compiles typeclasses into exactly this pattern anyway — dictionary passing. We're just making the dictionary explicit.

## Composition via Coproduct

Method lists combine:

```haskell
data (f :+: g) t where
  L :: f t -> (f :+: g) t
  R :: g t -> (f :+: g) t

combine :: Egg img f -> Egg img g -> Egg img (f :+: g)
```

`RawX86 :+: DebugOps` hatches an object that can execute code AND inspect registers. Two independent Eggs, composed at the value level.

Open question: deeply nested `:+:` has pattern-match overhead. For hot paths, a flat GADT with all methods is probably better. Both should coexist.

## The Naming (and Why It Works)

- **Hatchery** — the incubator, the platform
- **Egg** — the blueprint you bring to be hatched
- **Object** — the live thing that comes out
- **Image** — the object's physical state (VM image analogy)
- **Seed** (eConfig) — the yolk, the material substrate
- **Method list** (GADT f) — the DNA, the specification
- **Interpreter** (f ~> IO) — gene expression, specification → behavior

## Patterns We Tried and Killed

For future sessions — don't rediscover these:

| Pattern | Why Rejected |
|---------|-------------|
| Handle (closures over Image) | Hides Image too much. Consumer needs register/memory access. |
| Backpack (module signatures) | Purely static. No dynamic composition. Immature tooling. |
| Tagless final (monad carries strategy) | Forces specific effect stack. No dynamic composition without existentials. |
| Lens/Optics | Observation mutates violates lens laws (get-put, put-get). |
| Ref/IORef | Pretends read is non-destructive. Semantically wrong. |
| Free monad Program | Can't interact in real time. Batch-only. FreeT + m ≈ ReaderT with extra indirection. |
| Port/Mealy | Doesn't capture state change after interaction. Evolved into Object. |

## Open Questions We Didn't Resolve

1. **Object linearity** — nothing prevents using the "old" Object reference after a method call. Linear types could enforce single-use. YAGNI?

2. **Error handling** — should Object encode failure in the return type (`Either Error t`)? Or let `m` handle it via exceptions? Probably the latter — keep Object simple.

3. **Pool-level dispatch** — `hatch` gives one Object from one worker. But sometimes you want "borrow a worker, do something, return it." That's a `dispatch :: Pool -> Egg f -> Strategy f in out -> in -> IO out` that manages the lifecycle. Probably needed.

4. **Lifecycle & GC** — if an Object is GC'd without `destroy`, the worker leaks. GHC finalizers are unreliable for timely cleanup. Bracket pattern (`withComputer`) is safer. Should we make this the only API?

5. **Performance** — Object indirection (method → interpreter → concrete ops) adds a function call per interaction. At 365ns cross-process round-trip, probably unmeasurable. But worth confirming.

6. **Egg validation** — should `hatch` check that the Egg's needs match the backend's capabilities? (e.g., XMM registers on a backend without FPU support.) Type-level validation would be ideal, runtime is simpler.

---

*Session: 2026-03-15, Claude Opus 4.6. Session ID: 919c38de-05cd-402c-bbf5-e3dba6df4a9c.*
*Conversation flow: payload-agnostic hatchery → Image with three components → opaque effectful lens → observation mutates → Machine type connection → coalgebraic Object → Egg reification → Hatchery typeclass → clean master.*
