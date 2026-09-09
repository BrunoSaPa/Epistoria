"""Offline, verified token-to-text reference. Does not normalize or repair mathematics."""
import json
from pathlib import Path
import numpy as np

from probe import MANIFEST, verified


def load_tokenizer(config_path):
    expected = json.loads(MANIFEST.read_text())["files"]["config.json"]
    if not verified(config_path, expected):
        raise ValueError("Tokenizer configuration failed pinned verification")
    from tokenizers import Tokenizer
    config = json.loads(config_path.read_text())
    tokenizer = Tokenizer.from_str(json.dumps(config["PostProcess"]["character_dict"]["fast_tokenizer_file"]))
    if tokenizer.get_vocab_size() != 50000 or [tokenizer.id_to_token(i) for i in range(4)] != ["<s>", "<pad>", "</s>", "<unk>"]:
        raise ValueError("Unexpected tokenizer vocabulary")
    return tokenizer


def content_ids(raw_tokens):
    values = np.asarray(raw_tokens)
    if values.ndim == 2 and values.shape[0] == 1:
        values = values[0]
    if values.ndim != 1 or values.dtype.kind not in "iu" or not 6 <= values.size <= 1026 or values.size % 3:
        raise ValueError("Invalid generated token sequence")
    if np.any(values < 0) or np.any(values >= 50000) or not np.array_equal(values[:3], [0, 0, 0]):
        raise ValueError("Invalid token IDs or generation prefix")
    eos = np.flatnonzero(values == 2)
    if not eos.size:
        raise ValueError("Incomplete generation: EOS is missing")
    end = int(eos[0])
    if end < values.size - 3:
        raise ValueError("Generation continued after its EOS group")
    content = values[3:end]
    if np.any(content == 3):
        raise ValueError("Unrecognized token in generated expression")
    if np.any(content == 0):
        raise ValueError("Unexpected beginning token inside expression")
    return [int(value) for value in content if value != 1]


def decode_generated(tokenizer, raw_tokens):
    ids = content_ids(raw_tokens)
    if not ids:
        raise ValueError("Empty recognized expression")
    # Match the reference EOS boundary. Preserve decoded Unicode, spaces and LaTeX commands;
    # Paddle's separate text-repair/normalization passes have not been ported or validated.
    text = tokenizer.decode(ids, skip_special_tokens=False)
    if not text.strip() or "\ufffd" in text:
        raise ValueError("Empty or invalid decoded text")
    return text


def verify_reference_vectors(tokenizer):
    """Small owner-authored text fixtures; not OCR accuracy samples."""
    vectors = json.loads(Path(__file__).with_name("tokenizer-fixtures.json").read_text())
    results = []
    for vector in vectors:
        ids = [0, 0] + vector["ids"]
        ids += [1] * (-len(ids) % 3)
        if decode_generated(tokenizer, ids) != vector["text"]:
            raise ValueError(f"Tokenizer reference vector failed: {vector['name']}")
        results.append({"fixture": vector["name"], "passed": True})
    return results
