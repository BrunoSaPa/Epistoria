"""Pinned FormulaNet batch-one cached neural step with traceable cache dimensions."""
import numpy as np
import onnx
import torch
from torch import nn
from torch.nn import functional as F


class CachedFormulaDecoder(nn.Module):
    """Two pre-normalized attention layers; generation and review stay outside the model."""
    def __init__(self, reference):
        super().__init__()
        for tensor in reference.graph.initializer:
            self.register_buffer(tensor.name.replace(".", "_"), torch.from_numpy(onnx.numpy_helper.to_array(tensor).copy()))
        # The exported embedding multiply masks only the PAD row; preserve that operation.
        mask = np.ones((50000, 384), np.float32)
        mask[1] = 0
        self.register_buffer("embedding_mask", torch.from_numpy(mask))

    def weight(self, name):
        return getattr(self, name.replace(".", "_"))

    def linear(self, x, index):
        return x @ self.weight(f"linear_{index}.w_0") + self.weight(f"linear_{index}.b_0")

    def norm(self, x, index):
        return F.layer_norm(x, (384,), self.weight(f"layer_norm_{index}.w_0"),
                            self.weight(f"layer_norm_{index}.b_0"), 1e-5)

    @staticmethod
    def heads(x):
        return x.reshape(1, -1, 16, 24).transpose(1, 2)

    @staticmethod
    def attend(query, key, value):
        probability = torch.softmax((query * (24 ** -0.5)) @ key.transpose(-1, -2), dim=-1)
        return (probability @ value).transpose(1, 2).reshape(1, 3, 384)

    def layer(self, x, offset, norm, past_key, past_value, cross_key, cross_value):
        normalized = self.norm(x, norm)
        query = self.heads(self.linear(normalized, offset + 2))
        key = self.heads(self.linear(normalized, offset))
        value = self.heads(self.linear(normalized, offset + 1))
        if past_key is not None:
            key = torch.cat([past_key, key], dim=2)
            value = torch.cat([past_value, value], dim=2)
        x = x + self.linear(self.attend(query, key, value), offset + 3)
        query = self.heads(self.linear(self.norm(x, norm + 1), offset + 6))
        x = x + self.linear(self.attend(query, cross_key, cross_value), offset + 7)
        x = x + self.linear(F.gelu(self.linear(self.norm(x, norm + 2), offset + 8)), offset + 9)
        return x, key, value

    def embed(self, tokens, cache_length):
        positions = torch.arange(3, device=tokens.device) + cache_length + 2
        embedded = F.embedding(tokens, self.weight("embedding_3.w_0") * self.embedding_mask) * 19.595918655395508
        x = embedded + F.embedding(positions, self.weight("m_bart_learned_positional_embedding_3.w_0"))
        return F.layer_norm(x, (384,), self.weight("create_parameter_14.w_0"), self.weight("create_parameter_15.w_0"), 1e-5)

    def forward(self, tokens, key0, value0, cross_key0, cross_value0,
                key1, value1, cross_key1, cross_value1):
        x = self.embed(tokens, key0.shape[2])
        # The pinned three-token group attends all preceding tokens and its entire new group.
        # Its original exported mask is zero; history values are not read by the neural graph.
        x, key0, value0 = self.layer(x, 192, 61, key0, value0, cross_key0, cross_value0)
        x, key1, value1 = self.layer(x, 202, 64, key1, value1, cross_key1, cross_value1)
        logits = self.norm(x, 67) @ self.weight("linear_191.w_0")
        return logits, key0, value0, cross_key0, cross_value0, key1, value1, cross_key1, cross_value1


class PrefillFormulaDecoder(CachedFormulaDecoder):
    """Initial three-token group, without zero-length Core ML input arrays."""
    def forward(self, tokens, encoder):
        projected = self.linear(encoder, 212)
        cross_key0, cross_value0 = self.heads(self.linear(projected, 196)), self.heads(self.linear(projected, 197))
        cross_key1, cross_value1 = self.heads(self.linear(projected, 206)), self.heads(self.linear(projected, 207))
        x = self.embed(tokens, 0)
        x, key0, value0 = self.layer(x, 192, 61, None, None, cross_key0, cross_value0)
        x, key1, value1 = self.layer(x, 202, 64, None, None, cross_key1, cross_value1)
        logits = self.norm(x, 67) @ self.weight("linear_191.w_0")
        return logits, key0, value0, cross_key0, cross_value0, key1, value1, cross_key1, cross_value1
