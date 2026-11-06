# Third-party notices / 第三方模型与许可声明

KuiklyLLMProvider is published as two variants: `download` (no bundled model) and
`bundled` (one bundled model). Both variants include this notice and the full
Apache License 2.0 text in the adjacent `LICENSE`.

The source code, build scripts and documentation in this repository are
Copyright 2026 iPel and are licensed under the Apache License, Version 2.0.
The Alibaba Cloud copyright notices below apply to the upstream Qwen model
weights, not to this repository's source code.

## 1. Model catalog

All three weights are licensed under Apache-2.0 and are not gated. The files on
Hugging Face and ModelScope are identical (file size and SHA-256 verified).
Quantization to Q4_K_M GGUF is provided by Unsloth Dynamic 2.0. KuiklyLLMProvider
does not modify the weights; it only packages, downloads and loads them.

| Model id | GGUF file | Bytes | SHA-256 |
|---|---|---|---|
| `qwen3-0.6b-q4-k-m` | `Qwen3-0.6B-Q4_K_M.gguf` | 396,705,472 | `ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a` |
| `qwen3.5-0.8b-q4-k-m` | `Qwen3.5-0.8B-Q4_K_M.gguf` | 532,517,120 | `bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517` |
| `qwen3.5-2b-q4-k-m` | `Qwen3.5-2B-Q4_K_M.gguf` | 1,280,835,840 | `aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223` |

| GGUF repository | Original model | Copyright |
|---|---|---|
| `unsloth/Qwen3-0.6B-GGUF` | `Qwen/Qwen3-0.6B` | Copyright 2024 Alibaba Cloud |
| `unsloth/Qwen3.5-0.8B-GGUF` | `Qwen/Qwen3.5-0.8B` | Copyright 2026 Alibaba Cloud |
| `unsloth/Qwen3.5-2B-GGUF` | `Qwen/Qwen3.5-2B` | Copyright 2026 Alibaba Cloud |

Primary download source: `https://www.modelscope.cn/models/{repo}/resolve/master/{file}`
Backup download source: `https://huggingface.co/{repo}/resolve/main/{file}`

The unsloth GGUF repositories do not include a LICENSE file. Their model cards
declare `license: apache-2.0` and link to the corresponding official Qwen
LICENSE files, which govern the notices above.

## 2. Modification chain (Apache-2.0 section 4(b))

Qwen official weights -> Unsloth Dynamic 2.0 quantization to Q4_K_M GGUF ->
packaging, download and loading by KuiklyLLMProvider. No weight bytes are changed.

## 3. Trademarks (Apache-2.0 section 6)

Qwen, 通义千问, Unsloth, OpenAI, llama.cpp and ggml are names or trademarks of
their respective owners. Apache-2.0 grants no trademark rights. References to
"OpenAI API" in this project are descriptive and denote protocol compatibility
only. KuiklyLLMProvider is independently developed and is not affiliated with,
endorsed by, or sponsored by Alibaba Cloud, Qwen, Unsloth, OpenAI or the
llama.cpp authors. Model identifiers and GGUF file names are data values or
asset names; they are not code identifiers.

## 4. Other components

- `llama.cpp` / `ggml`: MIT License. Every platform build links the prebuilt
  llama.cpp / ggml static libraries (`LLMPROVIDER_WITH_LLAMA=1`) and therefore
  contains this code, so the full MIT notice is reproduced below and ships with
  every artifact:

  ```text
  MIT License
  
  Copyright (c) 2023-2026 The ggml authors
  
  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:
  
  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.
  
  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.
  ```

- KuiklyUI (rendering framework): distributed under its own license. Refer to
  the LICENSE file in the KuiklyUI repository that provides the Kuikly
  dependency used by the host application.

## 5. Distribution obligations

Both variants ship `LICENSE` and this `NOTICE.md` (including the MIT notice
above) in the Android AAR assets, the iOS Pod resource bundle and the
HarmonyOS HAR `resfile`. The `bundled` variant additionally contains one GGUF.
The `download` variant contains no weights and downloads them at runtime with
SHA-256 verification.
