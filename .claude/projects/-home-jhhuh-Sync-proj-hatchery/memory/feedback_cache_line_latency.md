---
name: Cache line RT not hardware floor
description: ~365ns spin-wait latency is NOT the hardware floor — intra-socket cache-line round-trips are much faster; this latency likely includes scheduler jitter or cross-NUMA effects
type: feedback
---

~365ns cross-process cache-line round-trip is not "the hardware floor" for same-socket cores. Intra-socket (same NUMA node) cache-line invalidation round-trips are significantly faster than that.

**Why:** The README and devlog claim ~365ns is "at the hardware floor — two cross-process cache-line round-trips." This overstates what the hardware limit actually is. The measured latency likely includes OS scheduler jitter, lack of core pinning, or other overhead beyond pure cache coherency.

**How to apply:** Don't claim spin-wait latency is at a hardware floor unless benchmarks use core pinning (`taskset`) on same-socket cores and the numbers are validated against known cache-line RT measurements for the specific microarchitecture. The current ~365ns is a good result but there's likely room to improve with proper pinning.
