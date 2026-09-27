# Third-party notices

Keet's own code is MIT licensed (see `LICENSE`). It builds on the following, which
keep their own licenses.

## Code

| Component | Version | License | Used for |
|---|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.17.4 | Apache-2.0 | Running Parakeet on Core ML and the Neural Engine, audio resampling |
| [text-processing-rs](https://github.com/FluidInference/text-processing-rs) (NemoTextProcessing) | 0.3.1 | Apache-2.0 | Linked by FluidAudio for text normalization |

## Model

The model is not in this repository. Keet downloads it on first launch, or
`scripts/fetch-model.sh` downloads it ahead of time.

| Model | Revision | License |
|---|---|---|
| [nvidia/parakeet-unified-en-0.6b](https://huggingface.co/nvidia/parakeet-unified-en-0.6b) (original weights) | `fe53cd885760c96b6a5f51a0bfd362cb4584a98b` | [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/); the model card states it is ready for commercial and non-commercial use |
| [FluidInference/parakeet-unified-en-0.6b-coreml](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml) (the Core ML conversion Keet runs) | `d32e972dd4315f1dc3f6be28fb2aab0ab3e80358` | CC-BY-4.0 as listed on the repository |
| [FluidInference/parakeet-ctc-110m-coreml](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml) (word spotting for the Dictionary, downloaded only when you add a word) | `accdafd8cf8a2ff1cabe3c11e54416b405d409aa` | CC-BY-4.0 as listed on the repository |

If you redistribute the model, read both licenses; the conversion's listing and the
original's terms are separate documents.
