# Dataset sources and selection

## GPT-2: WikiText-2 from Hugging Face

- Repository: [`Salesforce/wikitext`](https://huggingface.co/datasets/Salesforce/wikitext).
- Configuration: **`wikitext-2-raw-v1`**.
- Split used for measurements: **`validation`**. Train/test examples are not scored.
- Loader: `datasets.load_dataset("Salesforce/wikitext", "wikitext-2-raw-v1", split="validation", revision=...)`.
- Requested revision defaults to **`main`**, overridable by `--dataset-revision`.
  The first smoke job used `main`; it was not pinned to a repository commit.
- Text is taken from the `text` column in dataset order and joined with two
  newline characters. The GPT-2 checkpoint tokenizer uses no added special tokens.

WikiText consists of selected Wikipedia articles; it is not the entire English
Wikipedia corpus. Therefore this experiment is not an exact reproduction of the
paper's unspecified English Wikipedia evaluation corpus.

The first smoke run scored 32 nonoverlapping full windows of 128 tokens (4,064
next-token transitions). The size sweep uses 256 windows at the same context
length (32,512 transitions) for every GPT-2 size. All numerical modes and model
sizes use the same text and window selection. The four GPT-2 variants share the
GPT-2 tokenizer vocabulary; input hashes in their reports allow verification.

Each GPT-2 JSON report records repository URL/name, configuration, split,
requested revision, dataset fingerprint, SHA-256 of the joined text, and SHA-256
of the scored token windows. An unpinned `main` is not an immutable source
revision; archive the cached data and these hashes when preserving a run.
For subsequent runs, pass an explicit Hub commit using `--dataset-revision`.

`--text-file` is a separate optional local input mode, not the Hugging Face
WikiText path. Its report records the local file path and content/input hashes.

## ViT: official ImageNet-1k validation from Hugging Face

- Repository: [`ILSVRC/imagenet-1k`](https://huggingface.co/datasets/ILSVRC/imagenet-1k).
- Split: **`validation`**, the labeled ILSVRC 2012 validation set (50,000 images,
  1,000 classes). No train or unlabeled test images are used.
- Initial sweep revision: **`49e2ee26f3810fb5a7536bbf732a7b07389a47b5`**,
  confirmed through Hub metadata on 2026-11-05.
- Download helper: `python -m avant_garde.imagenet`. It calls
  `snapshot_download(..., repo_type="dataset", allow_patterns=["data/validation-*.parquet"])`.
  There are 14 validation shards at the recorded revision. Explicit patterns
  prevent downloading the larger training and test splits.
- The repository requires accepted ImageNet access terms and authorized Hugging
  Face credentials. Access was verified with the cluster's existing credentials;
  no credentials are written to results or documentation.
  The first size job (4829451) nevertheless failed at download because its
  relocated `HF_HOME` hid the login token. The Slurm environment now preserves
  `HF_TOKEN_PATH` before moving caches; the token itself is not copied.

The sweep uses a deterministic **1,000-image subset**, not all 50,000 validation
images: one randomly selected image per class, seed 0. The helper randomizes
within each class, selects in class-balanced rounds, then shuffles the selected
order. ViT-Base, ViT-Large, and every numerical mode use that same manifest.

Images are decoded and saved as RGB PNG without resizing or added JPEG loss.
The checkpoint's image processor applies resizing and normalization at inference.
Official zero-based class IDs are preserved; folder names are not reinterpreted.
This assumes the standard ImageNet class order used by the Google ViT checkpoints.

The generated subset contains:

- `validation.csv`: relative image paths and class IDs;
- `images/*.png`: the selected decoded images;
- `source.json`: repository URL/name, requested revision, resolved snapshot
  commit, split, seed, selection method, selected dataset indices, class names,
  dataset fingerprint, and manifest SHA-256.

ViT result JSON embeds this provenance and checks that its manifest hash matches.
If a user supplies a separate `--manifest`, its path/hash are recorded; provenance
is embedded only if a matching sibling `source.json` exists. Its source must not
be assumed to be Hugging Face merely because the experiment uses ViT.

## Storage

Until work-directory write access is available, the persistent root remains
`/scratch/$USER/avant-garde-reproduction`:

- `huggingface/hub/`: Hub model and dataset snapshots;
- `datasets/`: processed Arrow caches;
- `imagenet-validation-1000-seed0/`: materialized ImageNet subset and provenance;
- `runs/`: reports and normalized bar graphs.

The dataset caches and reports have not been moved to work. Set
`AVANT_GARDE_DATA_ROOT=/work/cs-471/mixedprecisionarchitects/avant-garde-reproduction`
after permissions are fixed and caches are migrated between jobs. The old
`AVANT_GARDE_SCRATCH` variable remains a compatible root override. Slurm temporary
files can stay on scratch through `AVANT_GARDE_TMP_ROOT`.
