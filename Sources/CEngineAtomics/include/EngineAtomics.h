//
//  EngineAtomics.h
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef UNTOLD_ENGINE_ATOMICS_H
#define UNTOLD_ENGINE_ATOMICS_H

#include <stdatomic.h>
#include <stdint.h>

// Word-sized atomic load and store for Swift code that cannot use `Synchronization.Atomic`
// (macOS 15, iOS 18) at the engine's deployment targets. `EngineRecursiveLock` uses them for
// its owner word, which a thread reads without holding the lock to recognise its own re-entry.
// Relaxed ordering is enough there: a thread can only ever read its own identifier back if it
// stored it itself.

static inline uintptr_t UEAtomicLoadRelaxed(const uintptr_t *_Nonnull address) {
    return atomic_load_explicit((const _Atomic(uintptr_t) *)address, memory_order_relaxed);
}

static inline void UEAtomicStoreRelaxed(uintptr_t *_Nonnull address, uintptr_t value) {
    atomic_store_explicit((_Atomic(uintptr_t) *)address, value, memory_order_relaxed);
}

#endif
