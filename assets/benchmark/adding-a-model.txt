# Adding a model

A new Mixture-of-Experts architecture needs llama.cpp support for the architecture, an experts file made from its GGUF, and checks that streaming gives the same answers as a plain run, up to rounding. Ling 3.0 Flash (`bailingmoe3`, `src/models/bailingmoe3.cpp`) and Flint 40B (`flint`, `src/models/flint.cpp`) are the two to learn from. Flint's file is the shorter one.

## 1. What a model needs

### llama.cpp support for the architecture

The usual parts of a new llama.cpp architecture: a converter class (`conversion/flint.py`), the architecture and its tensor names (`gguf-py/gguf/constants.py`, `src/llama-arch.h`, `src/llama-arch.cpp`), the hyperparameters, tensors and graph in `src/models/<arch>.cpp` with its entry in `src/llama-model.cpp`, and a pre-tokenizer type (`src/llama-vocab.h`, `src/llama-vocab.cpp`) if the tokenizer is new. CMake collects `src/models/*.cpp` when it configures, so configure again after adding a file.

### Routed experts through build_moe_ffn

The graph must reach its routed experts through `build_moe_ffn` (`src/llama-graph.cpp`). The streaming lives inside it: in a streamed layer it replaces the expert tensors with the layer's RAM pool, adds the op that maps picked experts to pool slots, and builds the waves. The model's own graph code never mentions pools. The model hands in the router, the three expert tensors, the optional selection bias, and the gating function, weight normalisation and scale from its hyperparameters.

The experts must look like this:

- **Three tensors per MoE layer**, named `blk.N.ffn_gate_exps.weight`, `ffn_up_exps.weight` and `ffn_down_exps.weight`. The tools and the loader (`llama_moe_stream_is_exps`) look for these names only, so a fused gate-up tensor is not found.
- **Each projection's slice is a multiple of 4096 bytes**, because reads are direct. If not, the engine refuses the experts file and names the layer and projection.
- **Gate and up of a layer share type and shape.** The VRAM expert pool keeps them in one tensor; otherwise the pool and the features that depend on it switch off, with one line. Formats may differ between layers; Flint's do.
- **Dense layers come first.** The guess code treats every layer from `n_layer_dense_lead` on as a MoE layer.

### What stays streamed and what does not

Only the three expert tensors are streamed. Attention, routers, shared experts, dense layers, norms and the output head load as in llama.cpp. Layers kept whole in VRAM (`--moe-stream-gpu-layers`) load their experts from the model file. A model that is not MoE, is not loaded from a file, or is loaded with `--no-alloc` runs as plain llama.cpp, with one line saying so.

## 2. Step by step

`MODEL.gguf` is the model; a split GGUF is given by its first shard. The programs are in `build/bin/` ([Building](building.md)).

### 1. Make the experts file

```bash
python3 tokenwing-tools/experts/expert_index.py MODEL.gguf -o MODEL.index.json
python3 tokenwing-tools/experts/expert_repack.py MODEL.gguf --index MODEL.index.json -o MODEL.experts
```

The first command reads only the GGUF header and writes where every expert slice sits. The second writes `MODEL.experts`, with every expert (gate, up, down, not requantized) in a block that starts on a 4096-byte boundary, and `MODEL.experts.json`, which describes it and carries the model's header fingerprint. The file is about as large as the model's routed experts, so keep it on the drive the model streams from. Each layer's block size is recorded in `block_bytes_per_layer`; the top-level `block_bytes` is null when layers differ. Leave `--cpu-repack` off unless the experts are MXFP4, the only format with a repacked layout.

### 2. Verify it

```bash
python3 tokenwing-tools/experts/verify_sidecar.py MODEL.index.json MODEL.experts.json
```

It compares a sample of experts (8 layers, 3 experts each; `--layers` and `--experts` change that) byte for byte with the GGUF, prints `same` or `MISMATCH` for each, and exits with 1 on any mismatch.

### One file instead of two

`make_model_file.py` turns the GGUF into a TokenWing model file: the same GGUF (same tensors, order, bytes and metadata) with every tensor on a 4096-byte boundary, the key `tokenwing.format`, checksums of the first, middle and last expert of every MoE layer, and optional data appended after the last tensor. Plain llama.cpp opens it like the original, and `--moe-stream model` streams the experts from it, so there is no experts file and no `.json`.

```bash
python3 tokenwing-tools/experts/make_model_file.py MODEL.gguf -o MODEL.tokenwing.gguf \
    [--correction CORR.bin] [--vram-list MODEL.vram-experts.json] [--usage-seed SEED.json] [--layer-order ORDER.json]
build/bin/llama-completion -m MODEL.tokenwing.gguf --moe-stream model -f prompt.txt -n 128 --load-mode dio
```

It refuses a split GGUF (merge the shards first) and a model whose expert slices are not a multiple of 4096 bytes, and names the layer and tensor. The data is streamed in chunks, so a 70 GB model needs little RAM; the file is written as `OUT.tmp` and renamed at the end, then read back and compared with the source (every tensor's bytes, the metadata, the checksums, the appended data; `--no-check` skips that). The appended data is used with `--moe-stream-correction model` and `--moe-stream-vram-experts-file model`; the layer order and the usage seed are used by `--moe-stream model` when no file of that name sits next to the model. `--moe-stream-verify` then checks the file's own checksums instead of comparing with a second copy.

### 3. Check the plan

```bash
build/bin/llama-completion -m MODEL.gguf --moe-stream MODEL.experts.json --moe-stream-plan-only
```

It prints the slots per layer, the pool RAM and the streamed layers, and loads nothing. When experts differ in size by layer, the plan says so and the engine's start-up lines give each layer's size.

### 4. Record which experts the model picks

```bash
build/bin/llama-moe-trace -m MODEL.gguf -o recordings/p01 -f prompts/p01.txt -n 512 -c 4096 -b 512 --no-warmup
```

`-o` is a prefix. `p01.bin` holds int32 `[tokens][MoE layers][experts per token]`, and `p01.json` the layers, the expert counts and `n_prompt`, how many tokens belong to the prompt. Use many varied prompts: the counts are only as good as their text. `tokenwing-tools/testing/prompts/` has twelve examples written with `<role>...</role>` chat markers; write the same kinds of text in the model's own chat format. For a model larger than RAM, add `--moe-stream MODEL.experts.json`; the tool records streamed layers too.

### 5. Make the VRAM list and the usage seed

```bash
python3 tokenwing-tools/experts/make_vram_list.py MODEL.vram-experts.json recordings/p01 recordings/p02 --top 64
python3 tokenwing-tools/experts/make_usage_seed.py MODEL.experts.usage-seed.json recordings/p01 recordings/p02
```

The list ranks each layer's experts by how often replies picked them (prompt tokens are not counted) and keeps `--top` per layer. It feeds `--moe-stream-vram-experts-file`. Each entry is `[expert, count]`; the count is only used for the optional non-uniform split described in `docs/settings.md`. The seed counts picks over prompts and replies for `--moe-stream-idle-load 1`; the engine reads it only until its own table, `MODEL.experts.usage.json`, exists. The seed's name is the experts file's name without `.json`, plus `.usage-seed.json`. Both tools refuse recordings of different models.

A third file is optional: `MODEL.experts.layer-order.json`, which orders the layers for whole-layer VRAM placement:

```json
{"format": "tokenwing layer order v1", "arch": "flint", "order": [10, 3, 7]}
```

`order` lists the streamed layers (three shown here), the one a token waits on most first, and `arch` must equal the model's architecture name. No tool in `tokenwing-tools/` makes this file. Without it, only Ling has a built-in order; any other model gets its layers shallowest first, with a warning.

### 6. Run it

```bash
build/bin/llama-completion -m MODEL.gguf -f prompt.txt -n 128 -c 4096 -ub 512 -ngl 99 --load-mode dio -fit off \
    --moe-stream MODEL.experts.json --moe-stream-vram-free 200MiB \
    --moe-stream-vram-experts-file MODEL.vram-experts.json --moe-stream-idle-load 1
```

Every flag is in [Settings](settings.md). Two defaults were measured on Ling 3.0 Flash: `--moe-stream-vram-scratch` and `--moe-stream-other-rest` (the server's share of the RAM plan). Measure them on the new model.

## 3. What a real port changes in the code

These are the changes Flint needed. Each says where it lives.

- **The graph.** `src/models/flint.cpp`: hyperparameters, tensors and a graph that calls `build_moe_ffn`. Router bias is `TENSOR_NOT_REQUIRED`; Flint's routing is set by the hyperparameters `expert_gating_func`, `expert_weights_norm` and `expert_weights_scale`.
- **The graph node budget.** Streaming adds nodes to every streamed layer (the remap op, pool views, guesses, waves). Flint's graph ran out of the default budget of 8 nodes per tensor at its first prompt. `llama_context::graph_max_nodes` (`src/llama-context.cpp`) now gives any streamed model the larger of 40 nodes per token and 32 per tensor.
- **Guess inputs.** In the layer loop the model calls `moe_guess_routers`, builds its shared expert first when `g.want_shared` is set (`--moe-stream-pred-shared 1`: the guess input is the residual plus the shared expert), calls `moe_guess_finish`, and passes the result to `build_moe_ffn`. After each layer it calls `moe_ws_layer` for the word-start guesses, with `moe_ws_begin` before the loop (all in `src/llama-graph.cpp`). Without these calls the model streams but makes no guesses, because `build_moe_ffn` builds the guess only when it is handed the next layer's router. `--moe-stream-lookahead` above 1 and `--moe-stream-wordstart` fall back with one line for an architecture not in `arch_leads` (`src/llama-moe-stream.cpp`); add the architecture's name there.
- **The lazy word table.** Add the architecture to `llama_arch_marks_token_embd_lazy` (`src/llama-model.cpp`) and mark `tok_embd` with `TENSOR_READ_LAZY` in the model's tensors, only when the file has a separate `output.weight`: a tied table would be read in full by every token.
- **Sliding-window attention.** The model sets `n_swa` and the window pattern in `load_arch_hparams` and uses `build_attn_inp_kv_iswa`. The RAM plan then counts only the window cells in a snapshot (`llama_moe_stream_srv_compute`, `src/llama-model.cpp`).
- **Layer-major prompts.** Add the architecture to `llama_arch_layer_major` (`src/llama-context.cpp`). The graph builds only the layers `[lm_il0, lm_il1)` of a call and reads the `lm_*` parameters (`lm_phase`, `lm_hid`, `lm_x`, `lm_row0`). `llama_model_flint::graph` shows the three kinds of graph: a layer's expert graph (`lm_phase == 2`), a layer group with the experts split off (`lm_phase == 1`), and the usual whole graph. The memory must implement `rewind()` and `reapply()`.
- **Layer-major with a window cache.** A window cache reuses cells, so a layer replaying an earlier ubatch needs that ubatch's own cell records. `cells_rec` and the kept masks are in `llama_kv_cache_context` (`src/llama-kv-cache.cpp`), `rewind` and `reapply` in `llama_kv_cache_iswa_context` (`src/llama-kv-cache-iswa.cpp`). The engine counts them against the memory limit (`rg_call_need`).
- **Down-projection scaling.** For some architectures llama.cpp scales the down projection's input by a power of two and undoes it on the output. The host path and the VRAM expert pass in `build_moe_ffn` both need it, so the architecture is listed in both places (search `build_amax_src1_f16`). It is also kept out of `-sm tensor` in `llm_arch_supports_sm_tensor` (`src/llama-arch.cpp`), because the scaling op cannot be split across devices. `--moe-stream-cpu-down-scale` skips the step where the result is exact.
- **Experts that differ in size.** The engine charges each layer its own size: the whole-layer fit, the RAM plan, and the plan printout (`block_bytes` is 0 when sizes differ; `common/common.cpp`). The guess width defaults to the model's top-k (`--moe-stream-prefetch-m 0`), not a fixed 8.
- **The VRAM pool with mixed formats.** `vx_setup` (`src/llama-moe-stream.cpp`) makes one pool group per combination of gate/up type and shape and down type and shape. The tail of the pool lives in the group with the most layers, and the per-place fit of `--moe-stream-vram-free` runs only with a single group.
- **CPU kernels by format.** `--moe-stream-cpu-x4` covers MXFP4 only. `--moe-stream-cpu-iqk` covers Q4_K, Q5_K, IQ4_XS, IQ3_S and Q8_0 in prompt-size calls (`ggml/src/ggml-cpu/iqk/`). Any other format runs ggml's own kernel.

## 4. How to know it works

### The built-in checks

```bash
python3 tokenwing-tools/testing/check.py --model SMALL.gguf --build build
```

`SMALL.gguf` is the smallest model of the architecture that fits in RAM. The script builds, runs `ctest`, tests the experts-file tools on the model, makes the experts file, and compares runs. The one that matters for a port: the streamed run on the CPU must write the same text as the plain run, both with `-ngl 0 --no-repack` and at a batch size where no call needs waves, so both use the same kernels in the same order. A pool smaller than the prompt needs (waves) and a streamed GPU run must finish with sensible text. [Testing](testing.md) lists the steps.

### Text that must not change

A setting that changes only what is read, never what is computed, must give the same text on and off. `compare.py` runs the two sides alternately and prints `same text as the old side: yes` or `no`:

```bash
python3 tokenwing-tools/testing/compare.py --old build --new build --model MODEL.gguf --experts MODEL.experts.json \
    --old-args "--moe-stream-prefetch 0" --new-args "--moe-stream-prefetch 1" --pairs 1 --words 128
```

Run it for each guess flag the graph supports. Rounding differs between execution paths (GPU against CPU, another batch shape), so different text is not an error in itself. Text that stops making sense, NaN, or no output is.

### KL divergence against a plain run

`llama-moe-decode-batch` writes the logits of every forced token and compares a run with such a file. Both runs must feed the same tokens, so give both `--force-text`, the text of a plain run (`check.py` leaves one in `tokenwing-check/plain_cpu.txt`):

```bash
build/bin/llama-moe-decode-batch -m MODEL.gguf -f prompt.txt --force-text plain.txt --gen 256 --no-batch \
    -c 4096 -ub 512 -ngl 99 --save-logits base.logits
build/bin/llama-moe-decode-batch -m MODEL.gguf -f prompt.txt --force-text plain.txt --gen 256 --no-batch \
    -c 4096 -ub 512 -ngl 99 --moe-stream MODEL.experts.json --kld-base base.logits
```

The first run has no `--moe-stream`, so the model must fit in memory; for a larger model compare two streamed settings the same way. The second prints `kld <call> <value> <same top-1>` for each token and a summary with the mean, maximum, 99th-percentile and median KLD and the share of tokens with the same top-1. A run refuses a base file with a different vocabulary or length. `--kld-base` needs `--force-text`. The yardstick is plain llama.cpp against itself: save a base at one `-ub`, run the plain model at another, and the streamed run's KLD should fall within that spread.

### The start-up lines

The start-up line `sidecar fingerprint ok` (shown with `-v`) means the experts file belongs to the model. `--moe-stream-verify` (on by default) reads one filled slot of every streamed layer back from the model file at the first token and ends the run, naming the layer, projection and byte, on a mismatch.

## 5. The correction file

The tools in `tokenwing-tools/correction/` have Ling 3.0 Flash's shape built in: 512 experts, a hidden size of 2,560, top 8 with 8 expert groups of which 4 are used, and layers 5 to 41 (`correction_fit.py`, `make_correction.py`, `check_correction.py`). They cannot train or check a file for another model until those constants and the grouped top-k are changed. `correction_file.py`, which writes and reads the file format, takes the shape from the model.

The engine reads any file whose header matches the model, but it uses one only with `--moe-stream-pred-shared 1` and when every covered layer's router tensor is F32, BF16 or F16, its `ffn_norm` is F32, and its selection bias, if the model has one, is F32 (`src/llama-moe-correction.cpp`; `bailingmoe3` must have the bias). A BF16 or F16 router is converted to F32 when the file is loaded. The bias is part of the file's model check whenever the model has it. Otherwise the engine runs the plain guess and prints one line saying why.
