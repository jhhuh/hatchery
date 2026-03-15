# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

Rebuilding from new foundations. The v1 implementation (worker pool with hardcoded dispatch) is frozen on `v1-worker-pool` branch. Master is clean — design doc + README only, ready for implementation.

## What This Is

**hatchery** — Type-safe sandboxed computation via coalgebraic objects.

Three core abstractions:

- **`Object f m`** — Coalgebraic mutable machine. `{ method :: forall t. f t -> m (t, Object f m) }`. Every interaction mutates. Defined by observable behavior (GADT method list), not internal state.
- **`Egg img f`** — Reification recipe. Pairs a concrete seed (worker config) with an abstract method list (GADT `f`) and its interpreter (`img -> f ~> IO`). Hatching allocates resources from the seed and wires the interpreter to produce a live Object.
- **`Hatchery h`** (typeclass) — Backend capability. Defines how to create pools and hatch eggs. `LinuxWorkerPool` is the concrete instance using fork server + seccomp + x86-64 process isolation.

## Package Structure (planned)

```
hatchery/              Core abstractions: Object, Egg, Hatchery typeclass, combinators
hatchery-linux/        LinuxWorkerPool instance (fork server, seccomp, ring buffer IPC)
hatchery-ccall/        CCall egg: System V AMD64 calling convention
hatchery-llvm/         LLVM IR → machine code bridge
trustless-ffi/         High-level typed FFI built on CCall egg
```

## Key Design Principles

- **Observation mutates**: No pure reads on Image. All interaction is effectful.
- **Image is opaque**: Concrete type, constructor not exported. PrimMonad-tied (`s ~ PrimState m`). Extra consumer state lives in the monad (ReaderT etc.), not in Image.
- **Egg carries the GADT**: Method list at the type level, interpreter at the value level. Eggs compose via coproduct (`:+:`).
- **Hybrid static/dynamic**: `IsEgg` typeclass for static dispatch, `Egg` records for runtime composition.

## Design Document

`docs/design.md` — Full architecture specification with type-theoretic foundation.

## v1 Reference

The `v1-worker-pool` branch contains the proven implementation:
- Fork server (~750 LOC C, static-PIE, raw syscalls, epoll)
- Spin-wait dispatch (~365ns via inline-cmm Cmm spin loop)
- Futex dispatch (~3100ns), one-shot dispatch (~5500ns)
- Ring buffer IPC, seccomp filtering, crash detection via pidfd

This becomes the `LinuxWorkerPool` backend instance.

## Build Commands

Not yet applicable — no source code on master. Will use nix flake + cabal once implementation begins.
