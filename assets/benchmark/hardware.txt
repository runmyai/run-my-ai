# Hardware

## 1. What each part does

### SSD

- **When it matters.** An expert that is in neither RAM nor VRAM when its layer needs it comes from the SSD. With enough free RAM every expert fits in the RAM cache, and the SSD is read only while the cache warms up. With less RAM the cache holds the experts the eviction rule values most, and the rest are read when needed or predicted.
- **Latency, not bandwidth.** TokenWing hides the latency of the reads. It does not raise memory bandwidth: the CPU and GPU still read every expert from RAM or VRAM. A read is hidden when it lands before its layer starts, so it depends on how long one read takes against one layer's compute. A slower drive or faster compute needs more lead, and `--moe-stream-lookahead` sets how many layers ahead TokenWing reads.
- **Direct reads.** Every expert read skips the operating system's file cache and lands in its slot in the RAM expert cache, so the file cache never holds a second copy. Direct reads need 4 KiB-aligned offsets, lengths and buffers, so the model file is laid out with every expert on a 4 KiB boundary. If the file system refuses direct reads, TokenWing reads through the file cache and prints one line.
- **Parallel reads.** `--moe-stream-io-threads` threads (default 8) read at once, so the drive's own queue stays full. Expert streaming only reads from the SSD; it never writes.
- **One drive.** The model file is read from a single drive. There is no striping across drives.

### RAM

- **The expert cache.** Each streamed layer has a pool of slots, one expert per slot. The slot count per layer is set at start-up from free RAM, minus a headroom for other programs (`--moe-stream-ram-free`), minus TokenWing's own non-expert memory. It stays under the process's memory limit. `--moe-stream-slots` sets it by hand.
- **Eviction.** When a pool is full, the expert with the lowest use count leaves first. The count is halved every 64 tokens.
- **CPU-only machines.** There RAM also holds the always-used weights (attention, shared experts, routers, embeddings, output head, dense layers), and the CPU computes every expert. On a GPU machine those weights are in VRAM.

### GPU and VRAM

- **What runs there.** The always-used weights live in VRAM. The GPU that holds a layer runs its attention, router and top-k selection, and computes the guesses for the next two layers.
- **Experts in VRAM.** Whole MoE layers (`--moe-stream-gpu-layers`; a negative value fits as many as the free VRAM takes), or a VRAM expert cache of the hottest experts of every streamed layer (`--moe-stream-vram-experts`, sized from free VRAM with `--moe-stream-vram-free`). VRAM follow (`--moe-stream-vram-follow`) swaps that set during decode.
- **GPU and CPU in parallel.** VRAM experts are computed on the GPU while the CPU computes the RAM experts, and the two outputs are summed (`--moe-stream-vram-parallel`).
- **Prompts.** Large waves of a long prompt run their expert matmuls on the GPU: the wave's experts are copied from RAM to VRAM over PCIe and computed there (`--moe-stream-gpu-waves`). VRAM lending for prompts (`--moe-stream-vram-lend-prompt`) lets a prompt borrow VRAM from the expert cache. It made long prompts slower on small GPUs, so it is a switch.
- **NVIDIA and AMD.** AMD GPUs build the same source as the CUDA backend, through HIP.

### CPU

- **Expert compute.** The CPU computes the experts that are in RAM. It starts on them while the missing ones land, and each projection has its own ready flag (`--moe-stream-proj-ready`), so gate and up run while down is still being read. With no GPU the router runs on the CPU, so the expert IDs are available at once.
- **Instruction sets.** The 4-row expert kernels (`--moe-stream-cpu-x4`, for MXFP4 and IQ4_XS) need AVX-512 VNNI. The tiled prompt matmul has AVX-512 VNNI, AVX2 and AVX paths. The iqk kernels (`--moe-stream-cpu-iqk`) are x86-64 with AVX2. ARM CPUs run llama.cpp's own ARM kernels.
- **Thread placement.** Compute threads can be placed on cores with `-C`, `--cpu-range` and `--cpu-strict`.

## 2. Supported hardware

- **Operating systems:** Windows and Linux. macOS on Apple Silicon comes after launch.
- **GPUs:** NVIDIA and AMD, one or several, or no GPU (CPU only).
- **CPUs:** x86 and ARM (ARM builds are untested).

## 3. Speed-ups

Most speed-ups are settings that are off by default; the autotuner chooses which to turn on for a machine and a model. A speed-up that cannot run on a machine switches itself off with one line, and the engine still runs.

| Speed-up | Runs on |
|---|---|
| Guesses ahead (`--moe-stream-lookahead`, `--moe-stream-wordstart`), waiting list (`--moe-stream-plan`), overlap (`--moe-stream-overlap`), slot and read-back checks (`--moe-stream-slot-check`, `--moe-stream-verify`) | GPU and CPU |
| Needed-early, host producer (`--moe-stream-needed-early`) | GPU and CPU |
| Needed-early, GPU producer: the GPU writes the router's choices and the guesses into pinned host memory | GPU |
| Whole MoE layers in VRAM, fitted to free VRAM (`--moe-stream-gpu-layers`) | GPU |
| Expert waves of prompts on the GPU (`--moe-stream-gpu-waves`) | GPU |
| VRAM expert cache (`--moe-stream-vram-experts`, `--moe-stream-vram-free`), VRAM follow (`--moe-stream-vram-follow`), copy-back (`--moe-stream-vram-copyback`) | GPU |
| VRAM experts computed beside the CPU (`--moe-stream-vram-parallel`) | GPU |
| Async copies to the GPU (`--moe-stream-async-h2d`) | GPU |
| Skipping all-zero slices (`--moe-stream-gpu-skip-zero`, `--moe-stream-cpu-skip-zero`) | GPU and CPU |
| Fused router pick (`--moe-stream-fused-route`) | GPU and CPU |
| Combined guess step (`--moe-stream-guess-combined`) | GPU and CPU |
| No guess for layers that hold every expert in RAM (`--moe-stream-guess-skip-full-gpu`, `--moe-stream-guess-skip-full`) | GPU and CPU |
| Trained guess correction (`--moe-stream-correction`) | GPU and CPU |
| Non-expert memory measured from the run (`--moe-stream-nonpool-measured`) | GPU and CPU |
| Layer-major prompts (`--moe-stream-layer-major`, `--moe-stream-layer-major-batch`) | GPU and CPU |
| Wave plan (`--moe-stream-wave-plan`) | GPU and CPU |
| Read-ahead during prompts (`--moe-stream-read-ahead`) | GPU and CPU |
| Moving RAM window (`--moe-stream-window`) | GPU and CPU |
| Idle-time loading (`--moe-stream-idle-load`) | GPU and CPU |
| Prompt defer (`--moe-stream-prompt-defer`) | GPU and CPU |
| Prompt split (`--moe-stream-prompt-split`) | GPU |
| Copy-ahead (`--moe-stream-copy-ahead`) | GPU |
| VRAM lending for prompts (`--moe-stream-vram-lend-prompt`) | GPU |
| VRAM end fill (`--moe-stream-vram-end-fill`) | GPU |
| Skipping zero-slice pairs in GPU prompt matmuls (`--moe-stream-gpu-wave-skip-zero`) | GPU |
| Small GPU copies as a kernel (`GGML_CUDA_COPY_KERNEL`) | GPU |
| GPU kernel fusions (`GGML_CUDA_POOL1D_ROW`, `GGML_CUDA_FUSE_AMAX`, `GGML_CUDA_FUSE_NORM_QUANT`) | GPU |
| 4-row expert kernels (`--moe-stream-cpu-x4`, `--moe-stream-cpu-x4-prefetch`) | CPU |
| Fused gate and up step (`--moe-stream-cpu-fuse`) | CPU |
| Expert work split and weighted sum (`--moe-stream-cpu-dispatch`, `--moe-stream-cpu-weighted-sum`, `--moe-stream-cpu-pieces`, `--moe-stream-cpu-conv1`) | CPU |
| Linear-attention state in place, small ops over all threads (`--moe-stream-cpu-state-inplace`, `--moe-stream-cpu-small-ops`) | CPU |
| Down-input scale step left out where exact (`--moe-stream-cpu-down-scale`) | CPU |
| Top-k in one pass (`--moe-stream-cpu-topk`) | CPU |
| q8_0 weights in the tiled prompt matmul (`--moe-stream-cpu-q8-tiled`) | CPU |
| CPU flash attention with a q8_0 KV cache (`--moe-stream-cpu-fa`) | CPU |
| Fewer small CPU steps (`--moe-stream-cpu-fuse-small`) | CPU |
| Expert weight groups as one tiled window (`--moe-stream-cpu-mmid-merge`) | CPU |
| ik_llama.cpp's expert kernels at prompt sizes (`--moe-stream-cpu-iqk`) | CPU |

## 4. The OS layer

Engine code does not call the system directly for these. Each goes through one small function with a version per system.

| TokenWing asks for | Linux | Windows |
|---|---|---|
| Reads that skip the file cache | `O_DIRECT` and `pread`; buffered reads and one line if the file system refuses | Unbuffered reads (`FILE_FLAG_NO_BUFFERING`) |
| Page-aligned memory for those reads | `posix_memalign` | `_aligned_malloc` |
| Pool memory that holds no RAM until written | Anonymous `mmap` | `VirtualAlloc` with `MEM_RESERVE`, then `MEM_COMMIT` for the slots in use |
| Giving a slot's pages back | `madvise(MADV_DONTNEED)` | `VirtualFree(MEM_DECOMMIT)` |
| Moving a slot's pages to another layer | `mremap` with `MREMAP_FIXED` and `MREMAP_DONTUNMAP` (Linux 5.7 and newer, `vm.max_map_count` of at least 262144); otherwise the pages are given back | No page move: pages are given back and committed fresh |
| The process's own memory use | `/proc/self/statm` | `K32GetProcessMemoryInfo` (working set) |
| Threads on given cores | `pthread_setaffinity_np`, set with `-C`, `--cpu-range`, `--cpu-strict` | `SetThreadAffinityMask`, same options |
| Small files written whole (usage table, measured non-expert memory) | Temp file, `fsync`, `rename` | `_commit`, `MoveFileExW` |
| An expert read from the model file itself (`--moe-stream model`): one request per projection, each at its own file offset | The same `O_DIRECT` read as above, issued once per projection | The same unbuffered read as above, once per projection |
| A byte range of a file (the data appended to a model file) | `fseeko` and `fread` | `_fseeki64` and `fread` |
