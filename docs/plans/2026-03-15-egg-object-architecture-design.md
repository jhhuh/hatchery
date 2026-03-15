# Egg/Object Architecture — Payload-Agnostic Hatchery Redesign

Date: 2026-03-15
Status: Draft

## Motivation

Hatchery currently bakes in too many payload-specific assumptions at the core level:

- Workers execute `int fn(void)` — fixed signature, no arguments, no structured I/O
- Ring buffer layout is hardcoded (exit_code, result bytes, specific field offsets)
- Injection method (process_vm_writev vs memfd) is the only axis of variation
- Calling conventions, argument passing, and result extraction are left to the consumer with no abstraction

The core sandbox should be **payload-agnostic**. Specific strategies for handling input and output belong in higher abstractions built on top. The low-level library should open the hatch for such possibilities.

## Core Abstraction: Egg → Hatchery → Object

The design models a sandbox as an **abstract physical computer**:

- **Egg** — a blueprint (specification + interpreter) for a computer. Carries its method list as a GADT at the type level.
- **Hatchery** — incubator. Takes an egg, spawns a real worker process, returns a live object.
- **Object** — the hatched computer. An interactive, mutable, stateful machine you interact with through typed methods.

```
Egg f ──→ hatch pool egg ──→ Object f IO
  │                              │
  │  GADT f: method signatures   │  f t → IO (t, Object f IO)
  │  interpreter: f ~> IO        │  typed, effectful, mutable
  │  config: worker setup        │  each call yields new object
  └──────────────────────────────┘
```

## Object: Coalgebraic Machine with Methods

An Object is a coalgebraic mutable automaton — a Machine (in the `machines` package sense) that also has typed methods. Each interaction mutates the object and produces a typed result along with the new object.

**Key semantic property: observation mutates.** There is no pure read. Every interaction — even "reading a register" — is an effectful step that transitions the object's state. This reflects the physical reality: the object is backed by a live process whose memory, registers, and execution state are all entangled.

```haskell
data Object f m = Object
  { method :: forall t. f t -> m (t, Object f m)
  }

-- Convenience
call :: Monad m => Object f m -> f t -> m (t, Object f m)
call obj msg = method obj msg
```

The `f` parameter is a GADT defining the object's method list. Each constructor is a method with typed input and output:

```haskell
data SomeMethodList t where
  MethodA :: ArgType -> SomeMethodList ReturnType
  MethodB :: SomeMethodList OtherReturnType
```

## Image: Concrete Internal State

Internally, each Object is backed by an `Image` — the concrete mutable state of a worker process. Image has three components:

1. **Execution context** — registers, stack pointer. The CPU state.
2. **Blob** — a shared memory region. The I/O channel for data transfer.
3. **Process state** — pid, pidfds, ring buffer control fields.

```haskell
data Image s  -- s ~ PrimState m, constructor not exported
```

- `Image` is **concrete** (a real type, not a type parameter or typeclass).
- `Image` is **opaque** (constructor not exported; interaction only through hatchery primitives).
- `Image` is **tied to its monadic context** via `s ~ PrimState m` (like `MutableByteArray s` or `STRef s`), preventing it from escaping its scope.

### Primitive operations on Image

These are hatchery-internal. Egg interpreters use them; end users do not.

```haskell
writeCodeRegion  :: PrimMonad m => Image (PrimState m) -> ByteString -> m ()
readRegSaveArea  :: PrimMonad m => Image (PrimState m) -> Register -> m Word64
writeRegSaveArea :: PrimMonad m => Image (PrimState m) -> Register -> Word64 -> m ()
readSharedMem    :: PrimMonad m => Image (PrimState m) -> Offset -> Size -> m ByteString
writeSharedMem   :: PrimMonad m => Image (PrimState m) -> Offset -> ByteString -> m ()
wakeAndWait      :: PrimMonad m => Image (PrimState m) -> m ExecStatus
```

### Extra state lives in the monad

Consumer-specific state (GPU handles, LLVM engine, connection pools) does not go in Image. It lives in the monad stack:

```haskell
type MySandboxM = ReaderT GpuContext IO

myInterpreter :: Image RealWorld -> MyGpuOps ~> MySandboxM
myInterpreter img = \case
  CompileShader src -> do
    ctx <- ask
    compiled <- liftIO $ gpuCompile ctx src
    liftIO $ writeCodeRegion img compiled
  ...
```

## Egg: Blueprint with Type-Level Method List

An Egg pairs worker configuration with an interpreter that maps abstract methods to concrete Image operations:

```haskell
data Egg f = Egg
  { eConfig      :: WorkerConfig
  , eInterpreter :: Image RealWorld -> f ~> IO
  }
```

The GADT `f` is the method list. The Egg carries it at the type level — so `Egg f` tells you exactly what `Object f IO` you'll get from `hatch`.

### Hatching

```haskell
hatch :: Pool -> Egg f -> IO (Object f IO)
hatch pool egg = do
  img <- acquireWorker pool (eConfig egg)
  let go img = Object $ \msg -> do
        result <- eInterpreter egg img msg
        pure (result, go img)  -- img mutated in-place; go wraps same ref
  pure (go img)
```

### Lifecycle

```haskell
-- Bracket-style for automatic cleanup
withComputer :: Pool -> Egg f -> (Object f IO -> IO a) -> IO a

-- Or manual acquire/release
hatch   :: Pool -> Egg f -> IO (Object f IO)
destroy :: Object f IO -> IO ()
```

## Concrete Egg: CCall (System V AMD64 ABI)

The C calling convention is one concrete Egg type. The GADT defines C-ABI-level operations; the interpreter maps them to registers.

```haskell
data CCall t where
  LoadFunction :: ByteString -> CCall ()
  SetArg       :: Word8 -> Word64 -> CCall ()     -- int arg by index
  SetArgF      :: Word8 -> Double -> CCall ()     -- float arg by index
  Call         :: CCall ExecStatus
  GetReturn    :: CCall Word64
  GetReturnF   :: CCall Double

ccallEgg :: Egg CCall
ccallEgg = Egg
  { eConfig = defaultWorkerConfig
  , eInterpreter = \img -> \case
      LoadFunction bs -> writeCodeRegion img bs
      SetArg n v      -> writeRegSaveArea img (intArgReg n) v
      SetArgF n v     -> writeRegSaveArea img (floatArgReg n) (castDoubleToWord64 v)
      Call            -> wakeAndWait img
      GetReturn       -> readRegSaveArea img RAX
      GetReturnF      -> castWord64ToDouble <$> readRegSaveArea img XMM0
  }

-- System V AMD64 integer argument registers
intArgReg :: Word8 -> Register
intArgReg 0 = RDI
intArgReg 1 = RSI
intArgReg 2 = RDX
intArgReg 3 = RCX
intArgReg 4 = R8
intArgReg 5 = R9
intArgReg _ = error "int args > 5 require stack spill"

-- Float args: XMM0..XMM7
floatArgReg :: Word8 -> Register
floatArgReg n = XMM n
```

### Usage

```haskell
main = withPool defaultConfig $ \pool -> do
  calc <- hatch pool ccallEgg
  (_, c) <- call calc (LoadFunction addCode)
  (_, c) <- call c (SetArg 0 17)
  (_, c) <- call c (SetArg 1 25)
  (_, c) <- call c Call
  (answer, _) <- call c GetReturn   -- 42
  print answer
```

## Concrete Egg: RawX86 (Current Behavior)

What hatchery does today, expressed as an Egg:

```haskell
data RawX86 t where
  Inject :: ByteString -> RawX86 ()
  Run    :: RawX86 ExecStatus
  Result :: RawX86 (Int32, Maybe ByteString)

rawX86Egg :: Egg RawX86
rawX86Egg = Egg
  { eConfig = defaultWorkerConfig
  , eInterpreter = \img -> \case
      Inject bs -> writeCodeRegion img bs
      Run       -> wakeAndWait img
      Result    -> (,) <$> readExitCode img <*> readResultBytes img
  }
```

## Compositional Method Lists

Method lists can be combined via coproduct:

```haskell
data (f :+: g) t where
  L :: f t -> (f :+: g) t
  R :: g t -> (f :+: g) t

combine :: Egg f -> Egg g -> Egg (f :+: g)
combine ef eg = Egg
  { eConfig = mergeConfig (eConfig ef) (eConfig eg)
  , eInterpreter = \img -> \case
      L ft -> eInterpreter ef img ft
      R gt -> eInterpreter eg img gt
  }
```

Example: an object that can both execute code and inspect registers:

```haskell
data DebugOps t where
  PeekReg :: Register -> DebugOps Word64
  PeekMem :: Offset -> Size -> DebugOps ByteString
  Status  :: DebugOps WorkerStatus

debugEgg :: Egg DebugOps
debugEgg = Egg
  { eConfig = defaultWorkerConfig
  , eInterpreter = \img -> \case
      PeekReg r    -> readRegSaveArea img r
      PeekMem o s  -> readSharedMem img o s
      Status       -> readWorkerStatus img
  }

-- Combined: execute + debug
debuggableX86Egg :: Egg (RawX86 :+: DebugOps)
debuggableX86Egg = combine rawX86Egg debugEgg
```

## Static/Dynamic Hybrid

The Egg system supports both static and dynamic dispatch:

**Static (typeclass):**

```haskell
class IsEgg s where
  type Methods s :: * -> *
  toEgg :: s -> Egg (Methods s)

data RawX86Config = RawX86Config
instance IsEgg RawX86Config where
  type Methods RawX86Config = RawX86
  toEgg _ = rawX86Egg

-- Ergonomic wrapper
hatchFrom :: IsEgg s => Pool -> s -> IO (Object (Methods s) IO)
hatchFrom pool s = hatch pool (toEgg s)
```

**Dynamic (pass Egg values directly):**

```haskell
-- Construct eggs at runtime, store in data structures, compose dynamically
myEggs :: [SomeEgg]  -- existentially wrapped
myEggs = [SomeEgg rawX86Egg, SomeEgg ccallEgg]

-- Or compose programmatically
makeEgg :: Config -> SomeEgg
makeEgg cfg
  | cfgDebug cfg = SomeEgg (combine rawX86Egg debugEgg)
  | otherwise    = SomeEgg rawX86Egg
```

## Strategy: Reusable Interaction Patterns

A Strategy is a function that interacts with an Object to accomplish a task. It's not a special type — just a function:

```haskell
type Strategy f m in out = in -> Object f m -> m (out, Object f m)

-- Example: "call a C function with two int args"
callInt2 :: ByteString -> Strategy CCall IO (Word64, Word64) Word64
callInt2 code (arg0, arg1) obj = do
  (_, o) <- call obj (LoadFunction code)
  (_, o) <- call o (SetArg 0 arg0)
  (_, o) <- call o (SetArg 1 arg1)
  (_, o) <- call o Call
  call o GetReturn
```

## Fork Server Changes Required

To support register read/write through Image:

1. **Register save area in ring buffer**: Extend `ring_buffer_layout.h` with a region for saving/restoring GP registers + XMM registers.

2. **Worker prologue/epilogue**: Before calling user code, worker saves current registers to ring buffer. After return, saves result registers. This lets Haskell read/write register values between executions via shared memory.

3. **Register load before execution**: Worker reads register values from the save area and loads them before calling user code. This lets Haskell set up arguments via `writeRegSaveArea`.

4. **Protocol simplification**: With the Object model, the wire protocol between Haskell and fork server can be simplified. The fork server's job is just: manage worker processes, provide shared memory, handle wake/wait/crash. All payload interpretation moves to the Egg interpreter.

## Package Structure

```
hatchery/              Core: Image, Object, Egg, Pool, hatch
                       Primitive Image ops, fork server, worker management
                       Ships with: RawX86 egg (backward compat)

hatchery-ccall/        CCall egg: System V AMD64, Win64, ARM AAPCS
                       Register mappings, stack spill logic

hatchery-llvm/         LLVM bridge: compile IR to machine code, wrap as Egg

trustless-ffi/         High-level typed FFI built on CCall egg
                       Automatic marshalling, timeout, error handling
```

## Summary

| Concept | Role |
|---------|------|
| `Image s` | Concrete opaque mutable worker state (memory + registers + process) |
| `Object f m` | Coalgebraic machine with typed methods. Each call mutates, yields new object |
| `Egg f` | Blueprint: GADT method list (type-level) + interpreter + config |
| `f` (GADT) | Method list. Each constructor = one typed method |
| `hatch` | Egg → Object. Spawns worker, wires interpreter to Image |
| `Pool` | Manages worker processes. Payload-agnostic |
| `Strategy` | Reusable interaction pattern over an Object. Just a function |
| `:+:` | Coproduct for composing method lists |
