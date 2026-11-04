# Third-party notices

Ionian Flow downloads the models below on first launch, directly from their public Hugging Face repositories (and
the MLX kernels from the MLX project's release). We do not host or redistribute them. Each model stays under its own
licence; the licence names below are those stated on the model cards at the time of writing.

## Speech recognition (Core ML conversions by FluidInference, run with the FluidAudio library, Apache 2.0)

| Model | Source repository | Based on | Licence |
|---|---|---|---|
| Streaming speech model, German and other Latin languages, 560 ms | FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML | nvidia/nemotron-3.5-asr-streaming-0.6b | OpenMDW 1.1 (https://openmdw.ai/license/1-1/) |
| Final-pass model, Parakeet TDT "Ultra" | FluidInference/parakeet-ultra-coreml | moondream/parakeet-ultra, itself derived from NVIDIA Parakeet | CC BY 4.0 |
| Vocabulary model, Parakeet CTC 110M | FluidInference/parakeet-ctc-110m-coreml | nvidia/parakeet-tdt_ctc-110m | CC BY 4.0 |

Attribution: NVIDIA Parakeet and Nemotron speech models, with Core ML conversions by FluidInference.

## Text cleanup (optional download)

| Model | Source repository | Based on | Licence |
|---|---|---|---|
| Gemma 4 E2B instruct, 4 bit | mlx-community/gemma-4-e2b-it-4bit | google/gemma-4-E2B-it | Gemma Terms of Use (https://ai.google.dev/gemma/terms) and Gemma Prohibited Use Policy |

Gemma is provided under and subject to the Gemma Terms of Use. Ionian Flow uses it only locally, to tidy dictated
text on this Mac.

## MLX (compiled into the app)

MLX and its Metal kernels are by Apple (ml-explore/mlx), MIT licence. The kernels are compiled from the mlx-swift
sources at build time into `mlx.metallib` inside the app; nothing is downloaded. The Swift bindings (mlx-swift,
mlx-swift-lm) are MIT as well.

## Libraries compiled into the app

FluidAudio (Apache 2.0), swift-transformers and swift-huggingface (Apache 2.0), mlx-swift and mlx-swift-lm (MIT).
Their full licence texts are in the respective source repositories.

## Word frequencies (shipped with the app)

`wordfreq.tsv`, the German and English word-frequency table behind the vocabulary's common-word guard, is derived
from the data of the wordfreq project (https://github.com/rspeer/wordfreq), which is licensed under CC BY-SA 4.0
(https://creativecommons.org/licenses/by-sa/4.0/). The table was reduced to words at Zipf 3.0 and above and
rescaled to integers; it is distributed under the same licence, CC BY-SA 4.0. wordfreq itself credits its sources
(among them Wikipedia, OpenSubtitles, SUBTLEX, Google Books Ngrams, Reddit and Twitter) in its README.
