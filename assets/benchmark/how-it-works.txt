# Inside TokenWing

TokenWing is the engine inside Run My AI. It streams the routed experts of MoE models from NVMe, so models far larger than your memory run at a usable speed. This page explains the whole pipeline.

Your SSD’s read speed isn’t the deciding factor for your speed; your memory’s size just stops being the limit. TokenWing mainly hides the latency of streaming from the SSD. It doesn’t increase your memory bandwidth: your CPU and GPU still read every expert from RAM or VRAM.

## Think of how a video game runs

You download a 50 GB game, yet while you play it consumes maybe 8 GB of RAM and 4 GB of VRAM, and it still runs fine... That works because the engine never holds the whole world in memory: it streams in what’s about to appear just before you reach it, and evicts what you’ve left behind. That works because a game is surely predictable: the engine always knows what lies around the next corner.

A Mixture-of-Experts model is built in a way that fits this perfectly. Inside, it’s split into many small experts, and each token needs only a few of them, so most of the model sits unused at any moment. That’s exactly the situation game engines handle so well. So why can’t an AI model stream itself from the disk, the way a game streams its world?

Because a model isn’t predictable. Which experts the next token needs is decided at the last moment, deep inside the model, right before they’re used.

Well, not anymore. TokenWing works out which experts are coming a couple of layers early, and loads them in time. That’s what this project is about.

## 1. Overview

### Sparse activation, hidden latency

In each MoE layer the router selects the top-k routed experts for the current token: top-6 of 256 for Flint 40B, top-8 of 512 for Ling 3.0 Flash. Only those experts' weights are read, so a token touches a few percent of the model's weights, even when the model is far larger than RAM.

The problem is latency. NVMe is much slower than DRAM, and fetching each expert on demand would stall every token on the SSD. TokenWing hides that latency: it predicts the next layers' experts from their own routers, reads them through a priority I/O queue into a RAM expert cache it manages itself, and overlaps compute with the reads still in flight.

### Where the bytes go

```
model file
├─ at start ──► attention, shared experts,
│               routers, dense layers,
│               embeddings, output head
└─ direct reads (8 threads)
──► RAM expert cache, per layer
RAM expert cache ─PCIe─► VRAM expert cache
GPU (VRAM experts) ‖ CPU (RAM experts) ─► sum
```

### What decides the speed

With TokenWing you could technically run even a trillion-parameter model, if the math checks out with:

- the active parameters per token;

- how fast your SSD reads;

- how much of the model your memory can already hold;

- how many layers ahead the prefetcher looks, and how accurate it is.

## 2. What is streamed

### Only the routed experts

| Part of the model | Where it lives |
|---|---|
| Routed experts of the MoE layers (gate, up and down per expert) | Streamed from the model file on NVMe into the RAM and VRAM expert caches |
| Routed experts of layers kept whole on the GPU | Loaded from the model file into VRAM at startup, not streamed |
| Attention, shared experts, routers, norms, embeddings, output head, the leading dense layers | Loaded at startup: VRAM on a GPU machine, RAM otherwise |
| KV cache | VRAM or RAM, sized for the context |
| The MTP (next-token prediction) layer, where a model has one | Not streamed; MTP isn't used at launch |

## 3. Storage

### One model file, laid out for streaming

A standard GGUF lines its data up to only 32 bytes, and an expert's slice is 4 KiB-aligned only relative to its tensor's start, so experts can't be read from it with direct reads, which need 4 KiB alignment. So TokenWing's models are published in their own layout: every routed expert starts on a 4 KiB boundary, next to the always-used weights and an index of where each expert sits.

It's one file per model, about the size of the original (Flint 40B about 25 GB, Ling 3.0 Flash about 70 GB), with no second copy of the experts. At startup TokenWing checks sample experts against the file's own checksums, so a corrupt file stops the run before it can produce output.

### Direct reads, no file cache

Every expert read skips the operating system's file cache and goes straight into its slot in the RAM expert cache: `O_DIRECT` on Linux, unbuffered reads (`FILE_FLAG_NO_BUFFERING`) on Windows. The file cache is skipped on purpose: it would hold a second copy of every expert and evict on its own terms. The always-used weights are loaded without mapping the whole file, since mapping it can push a machine out of memory. On a file system that doesn't allow direct reads, TokenWing falls back to normal cached reads and prints one line saying so.

Several I/O threads (8 by default) read in parallel, so the drive's own queue stays full. Expert streaming only reads from the SSD; it never writes to it.

## 4. RAM

### The RAM expert cache

Each streamed layer has a pool of slots; a slot holds one expert's gate, up and down bytes. The slot count per layer is set at startup from free RAM, minus a headroom for other apps (0.5 GB in Run My AI's presets), minus TokenWing's own non-expert memory (KV cache, compute buffers, GPU host buffers), under the process's memory limit.

With enough free RAM, every expert of every layer fits, and the SSD is only read while the cache warms up. With less, each layer's cache holds the share of its experts that the eviction rule (section 10) values most, and the rest are read from the SSD when needed or predicted.

## 5. VRAM

### Whole layers or an expert cache

On a GPU, TokenWing can keep whole MoE layers in VRAM, or a VRAM expert cache: the hottest experts of every streamed layer, sized from free VRAM and seeded from a usage census of the model. With several GPUs, each GPU keeps its own expert cache for the layers it holds, sized from its own free memory.

During decode, the VRAM set follows usage. Every 8 tokens, up to 64 VRAM experts are swapped for hotter ones; a swap needs the newcomer's recent count to beat 1.25 × the leaver's, plus 4. The copy comes from the RAM slot, which is protected while it runs, and the GPU keeps working.

VRAM-resident experts are computed on the GPU in parallel with the RAM-resident experts on the CPU, and the two outputs are summed.

## 6. Prediction

### Router lookahead

The residual stream changes little from one layer to the next, so a later layer's router, applied to the current hidden state, is a good predictor of what that layer will select.

- **The input.** At layer L, the prediction input is L's hidden state plus L's shared-expert output. Adding the shared expert cut misses by 11 % on Ling.

- **Two targets.** The routers of layers L+1 and L+2 are applied to that input, and each prediction is the top-k: the same width as the model's own selection. Both are computed in one fused op, bit-identical to computing them separately.

- **The first streamed layer.** The first streamed layer of each token comes after layers that aren't streamed (the dense layers, and layers kept whole in VRAM). Those layers predict it as well, from up to 2 layers before it. On Ling this halved its demand reads (0.87 → 0.44 per token).

- **Optional: a trained correction.** A small correction file, trained on a model's recorded routing, can adjust its predictions. It's optional: prediction works without one.

Accuracy on Ling 3.0 Flash (recall: the share of the selected experts that are in the top-8 prediction): 75.7 % one layer ahead, 67.2 % two layers ahead, 61.1 % three layers ahead. Wider predictions saturate: 64 wide reaches only 90.8 %, and every extra expert in a prediction is a read that's often wasted. On real runs, widening the prediction cut demand reads but barely moved the SSD wait, so the width stays at the model's top-k.

## 7. Design choice

### Why two layers ahead

**Lead time.** A prediction only helps if its read lands before the layer that needs it, and the time it gets is the compute time of the layers in between. When a layer computes faster than one expert read takes, as it does on fast RAM and GPUs, one layer of lead isn't enough to hide a read. Two layers about double the lead.

**Accuracy.** Each extra layer of distance costs accuracy (75.7 → 67.2 → 61.1 % at 1, 2 and 3 layers), and every wrong prefetch spends drive time and a RAM slot that a correct one could have used.

### A setting, measured

So the best distance depends on how long one read takes compared to one layer's compute: the slower the drive or the faster the compute, the more lead pays.

**We recommend two layers ahead, and it's the default**: on our test machine it beat one and three layers. A longer lead can help on a slower drive, but guesses further ahead are less accurate (61 % right at three layers, 67 % at two), and on a slow drive each wrong read costs more time too. So it's a setting (`--moe-stream-lookahead`), and another value should be measured on the machine before it's used.

## 8. I/O scheduler

### Demand first, prefetch in chunks

- **Two queues.** Demand reads (experts the router has selected that aren't resident) always go before prefetches (predicted experts).

- **Whole demand reads, chunked prefetches.** A demand read stays one request: splitting it into parallel pieces was slower in our tests, because each extra request adds a fixed cost in the I/O stack, while the drive's own queue already reads in parallel. Prefetches are split into 512 KiB chunks, so a demand read can be served between two chunks instead of waiting behind a whole expert. Each chunk wakes its own I/O thread.

- **Caps.** While a demand read is in service, at most 2 prefetch chunks are; while none is, at most 4.

- **Late binding.** A prediction goes on a waiting list, sorted by target distance and rank. An I/O thread gives it a RAM slot only when it has no demand read and no started prefetch to work on, so predictions don't evict cached experts early.

- **Cancel and promote.** When a layer starts, its predictions that the router didn't select are removed from the list, and their reads in progress are cancelled and their slots freed. A selected expert still queued as a prefetch has its chunks moved to the demand queue.

## 9. Decode

### One layer of one token

On a GPU machine. CPU-only is the same without the GPU parts.

- **Attention and routing on the GPU.** The GPU that holds layer L runs its attention, the router and the top-k selection, and computes the predictions for L+1 and L+2.

- **IDs to the CPU without a sync.** On NVIDIA (CUDA) and AMD (HIP) GPUs, inside the same launch, the GPU writes the selected expert IDs and the predictions into pinned host memory: the data, then a system-wide memory fence, then a counter. The CPU sees them as soon as the counter changes, with no separate copy or stream sync. On a CPU-only machine the router runs on the CPU, so the IDs are there at once.

- **Demand reads issued.** The CPU issues reads for the selected experts that aren't resident, and a helper thread queues the predictions.

- **Compute overlaps the reads.** The CPU starts on the experts already in RAM while the missing ones land. Each projection has its own ready flag: gate and up are read before down, so an expert's gate and up projections run while its down projection is still being read.

- **GPU and CPU in parallel.** Meanwhile the GPU computes the experts it holds in VRAM. The CPU's output is copied up and summed with the GPU's, and layer L+1 starts.

## 10. Eviction

### Frequency with decay

During decode, each expert in the RAM cache has a value: its use count, halved every 64 tokens. The lowest value leaves first; ties go to the least recently used, then the lower ID. A prefetched expert that nobody used is worth 0.

An expert predicted in this token for a layer that hasn't run yet is never evicted by a prefetch, and by a demand read only if nothing else is left. Prompts use LRU, but each prompt batch ages the values by its token count, so a long prompt doesn't leave stale counts from the previous reply.

### What was measured

On real routing recordings, perfect hindsight (Belady) would cut plain LRU's misses to 0.57×, and no cheap rule we tried came close. Decay was chosen on real runs, together with the chunk wake-ups, promotion, the prefetch cap and the prompt-end order.

## 11. Prefill

### Layer-major prefill

A long prompt activates most experts in every layer. Running the whole model batch by batch re-reads them for every batch: on Ling, a 4k-token prompt at a 16-token batch read 954 GiB from the SSD. So prefill has its own path.

- **Layer by layer over the whole prompt.** The whole prompt passes through one layer before the next starts, so each layer's experts are read about once per prompt (0.98 to 1.00 reads per distinct expert).

- **Expert waves.** If a layer needs more distinct experts than it has slots, they're processed in waves that fit: ceil(min(n_expert, n_tokens × k) / n_slots) waves, each expert read at most once. Inside a wave, experts not in it point to all-zero slices, which take no RAM and are skipped instead of computed.

- **GPU waves.** Large waves run their expert matmuls on the GPU: the wave's experts are copied from RAM into VRAM and computed there. While one step computes, the next step's experts are copied into a second set of VRAM places.

- **Read-ahead window.** From 4,096 tokens, the RAM cache works as one window over the layers: while a layer computes, the most-used experts of the next 2 streamed layers are read from the SSD. At that length, 98.5 % of the usage table's top experts turn out to be needed.

- **VRAM lending (a setting).** The prefill compute buffer can be planned by ggml's own allocator into space borrowed from the VRAM expert cache, then returned and refilled after the prompt, so decode keeps more experts in VRAM. It has a cost too: on small GPUs it made long prompts slower. So it's a switch, and the autotuner turns it on only where it pays.

- **Ready for decode.** The prompt's last batch puts its waves in recency order (a 128-token half-life), so the experts the end of the prompt used most stay in RAM for the first reply tokens. After 500 ms without a request, empty RAM slots are filled with the most-used experts from a usage table stored next to the model file, without evicting anything.

## 12. Memory

### Sizing and safety

- Every size (RAM slots, VRAM experts, GPU layers) is computed at startup from what the machine has free, never from a fixed value for one machine.

- A prompt's own working memory counts against the memory limit. If it needs room, the RAM cache gives back slots, empty ones first, then the coldest, and takes them back at the first decode token.

- When a prompt's GPU tensors can't fit, the prompt is split into calls that do.

### Slower, not broken

TokenWing doesn't refuse to load or run a model for lack of RAM or VRAM. It falls back to a slower path and prints one line saying what it did and why. It stops hard only for wrong data, such as a model file that fails its checksums.

## 13. Correctness

### No shortcuts

- No expert skipping and no top-k reduction: every expert the router selects is computed, with its full weights in the file's own quantization.

- Prediction only decides what to read early; it never changes which experts are used.

- Differences from llama.cpp are floating-point rounding (GPU vs CPU, batch shape, summing order). On Flint 40B, the KL divergence against official llama.cpp is 0.010 to 0.016 across our three test setups, against 0.016 for llama.cpp against itself when only its batch size changes.

### How changes are checked

A change that must not alter output is checked against frozen outputs (text checksums and saved logits). A change that may alter rounding is checked with KL divergence against llama.cpp. Speed claims come from paired, interleaved runs on a quiet machine on AC power; GPU pairs only count when the GPU clocks matched within 60 MHz.

## 14. Known limits

### What isn't solved yet

- After a very long prompt (16k tokens and more), the first reply tokens are slower while the RAM cache moves from the prompt's experts to the reply's.

- One SSD at a time: the model file is read from a single drive, with no striping across drives.

## 15. Settings

### Every part is a flag

Each mechanism on this page is a `--moe-stream-*` flag. Most are off by default in the engine, so plain TokenWing behaves like llama.cpp. Run My AI's presets turn on the measured set for each model, and the autotuner sets the machine-dependent values. Every flag is in [Settings](settings.md).

## Built on others' work

Where another engine or paper does something really well, we build on it. The [README](../README.md#thanks) lists what came from each.
