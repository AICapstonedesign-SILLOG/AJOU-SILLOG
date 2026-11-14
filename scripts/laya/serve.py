"""Local Laya v4 server for AJOU-SILLOG: POST /v1/privacy scores screen records for private sensitive information.

Follows the v4 evaluation (sillog-pii project/sillog_v2/server/predict_sp.py): each masked record is cut into token
windows that repeat its header, and the record score is the highest 1 - P(none) over its windows.

usage: python3 scripts/laya/serve.py [--model DIR] [--port 8766] [--device cpu]
needs: pip install torch transformers safetensors huggingface_hub
Without --model the weights come from the private Hugging Face repo below, so log in once with `hf auth login`
or set HF_TOKEN with an account that can read it.

request:  {"records": [{"app", "app_kind", "capture_source", "window_title", "url", "doc_path", "text"}]}
response: {"results": [{"score": 0.93, "category": "health"}]}
"""
import argparse
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import torch
import torch.nn as nn
from safetensors.torch import load_file
from transformers import AutoConfig, AutoModel, AutoTokenizer

MODEL_REPO = "beaver-zip/sillog-guard"
# Pinned so a later upload never changes what a build scores with.
MODEL_REVISION = "1e8a738ee41eff7f1ba0da934fb415f560b1e932"

HERE = os.path.dirname(os.path.abspath(__file__))
QUESTION = json.load(open(os.path.join(HERE, "questions.json"), encoding="utf-8"))["privacy"]
OPTIONS = list(QUESTION["criteria"])                      # none first
MAX_LEN, HEAD_MAX_LEN, OVERLAP, MARGIN = 512, 256, 64, 6   # predict_sp defaults and Windower


class DecisionModel(nn.Module):
    """laya.common.DecisionModel in the sequential option layout v4 was trained and evaluated with."""

    def __init__(self, encoder, head_layers):
        super().__init__()
        self.encoder = encoder
        d = encoder.config.hidden_size
        layer = nn.TransformerEncoderLayer(d, d // 64, 4 * d, 0.1, batch_first=True, norm_first=True)
        self.head = nn.TransformerEncoder(layer, head_layers, enable_nested_tensor=False)
        self.type_emb = nn.Embedding(3, d)
        self.scorer = nn.Sequential(nn.LayerNorm(d), nn.Linear(d, d), nn.GELU(), nn.Linear(d, 1))
        self.act_head = nn.Sequential(nn.Linear(d + 4, 256), nn.GELU(), nn.Linear(256, 2))  # unused, kept for strict loading
        self.register_buffer("temperature", torch.ones(3))

    def forward(self, ids, att, markers):
        h = self.encoder(input_ids=ids, attention_mask=att).last_hidden_state
        h = h + self.type_emb.weight[0]                     # qtype 0 = choice
        for layer in self.head.layers:
            h = layer(h, src_key_padding_mask=~att.bool())
        m = torch.gather(h, 1, markers[:, :, None].expand(-1, -1, h.size(-1)))
        return self.scorer(m).squeeze(-1).float()


class Laya:
    def __init__(self, model_dir, device):
        cfg = json.load(open(os.path.join(model_dir, "rl_agent_config.json")))
        self.tok = AutoTokenizer.from_pretrained(os.path.join(model_dir, "tokenizer"))
        ecfg = AutoConfig.from_pretrained(os.path.join(model_dir, "encoder"))
        ecfg.reference_compile = False                      # torch.compile needs Python headers and buys nothing here
        self.model = DecisionModel(AutoModel.from_config(ecfg, attn_implementation="sdpa"), cfg["head_layers"])
        self.model.load_state_dict(load_file(os.path.join(model_dir, "model.safetensors")), strict=True)
        self.device = torch.device(device)
        self.model.float().to(self.device).eval()
        self.head, self.markers = self._head()
        self.room = MAX_LEN - len(self.head) - 1
        self.lock = threading.Lock()

    def _ids(self, text, **kw):
        return self.tok(text.replace(self.tok.mask_token, " "), add_special_tokens=False, **kw)["input_ids"]

    def _head(self):
        """[CLS] choice question: <ins> [SEP] [MASK] opt0 [MASK] opt1 ... [SEP], as laya.common.build_head."""
        opt_ids = [[self.tok.mask_token_id] + self._ids(" %s: %s" % (k, v), truncation=True, max_length=48)
                   for k, v in QUESTION["criteria"].items()]
        budget = HEAD_MAX_LEN - sum(len(o) for o in opt_ids)
        assert budget >= 16, "options no longer fit the head"
        ids = [self.tok.cls_token_id] + self._ids("choice question: " + QUESTION["instructions"])[:max(8, budget)] + [self.tok.sep_token_id]
        markers = []
        for o in opt_ids:
            markers.append(len(ids))
            ids += o
        return ids + [self.tok.sep_token_id], markers

    @staticmethod
    def _header(rec):
        def trunc(s, n):
            s = str(s).replace("\n", " ").strip()
            return s if len(s) <= n else s[: n - 1] + "…"
        parts = ["[앱] %s (%s, %s)" % (rec.get("app") or "-", rec.get("app_kind") or "-", rec.get("capture_source") or "-")]
        for key, label in (("window_title", "[창] "), ("url", "[URL] "), ("doc_path", "[경로] ")):
            if rec.get(key):
                parts.append(label + trunc(rec[key], 120))
        return "\n".join(parts) + "\n[화면]\n"

    def windows(self, rec):
        """Window states over rec['text'], each starting with the header, as sp_common.Windower."""
        text = (rec.get("text") or "").replace("{n}", "3").replace(self.tok.mask_token, " ")
        header = self._header(rec)
        budget = max(64, self.room - len(self._ids(header)) - MARGIN)
        offs = self.tok(text, add_special_tokens=False, return_offsets_mapping=True)["offset_mapping"]
        if not offs:
            return [header]
        out, i, stride = [], 0, max(16, budget - OVERLAP)
        while True:
            j = min(len(offs), i + budget)
            out.append(header + text[offs[i][0]:offs[j - 1][1]])
            if j >= len(offs):
                return out
            i += stride

    @torch.inference_mode()
    def probabilities(self, states, batch=16):
        seqs = [self.head + self._ids(s)[:MAX_LEN][: self.room] + [self.tok.sep_token_id] for s in states]
        out = []
        for k in range(0, len(seqs), batch):
            part = seqs[k:k + batch]
            width = max(len(s) for s in part)
            ids = torch.full((len(part), width), self.tok.pad_token_id, dtype=torch.long)
            att = torch.zeros((len(part), width), dtype=torch.long)
            for r, s in enumerate(part):
                ids[r, :len(s)] = torch.tensor(s)
                att[r, :len(s)] = 1
            markers = torch.tensor([self.markers] * len(part))
            logits = self.model(ids.to(self.device), att.to(self.device), markers.to(self.device))
            out += torch.softmax(logits, -1).cpu().tolist()
        return out

    def score(self, records):
        with self.lock:
            owner, states = [], []
            for r, rec in enumerate(records):
                for state in self.windows(rec):
                    owner.append(r)
                    states.append(state)
            best = [None] * len(records)
            for r, p in zip(owner, self.probabilities(states)):
                if best[r] is None or 1 - p[0] > 1 - best[r][0]:
                    best[r] = p
            return [{"score": round(1 - p[0], 4), "category": OPTIONS[1 + max(range(len(p) - 1), key=lambda i: p[i + 1])]} for p in best]


def model_dir():
    """Downloads the weights once into the Hugging Face cache and returns their folder."""
    from huggingface_hub import snapshot_download
    from huggingface_hub.errors import HfHubHTTPError, LocalEntryNotFoundError
    try:
        return snapshot_download(MODEL_REPO, revision=MODEL_REVISION)
    except (HfHubHTTPError, LocalEntryNotFoundError) as e:
        # A missing, expired or under-scoped token surfaces as "not found", 401 or a network error, so keep the cause.
        raise SystemExit("cannot download %s (%s): run `hf auth login` (or set HF_TOKEN) with an account invited to it, "
                         "check the network, or pass --model with a local copy" % (MODEL_REPO, str(e).splitlines()[0]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", help="local model folder; default downloads %s" % MODEL_REPO)
    # 8765 is the Google OAuth callback and Picker port.
    ap.add_argument("--port", type=int, default=8766)
    # mps stalled on the first request on macOS 27 with torch 2.10, so cpu (about 1 s a record) is the default.
    ap.add_argument("--device", default="cpu")
    args = ap.parse_args()
    laya = Laya(args.model or model_dir(), args.device)

    class Handler(BaseHTTPRequestHandler):
        def _send(self, code, body):
            data = json.dumps(body, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self._send(200, {"ok": True}) if self.path == "/health" else self._send(404, {"error": "not found"})

        def do_POST(self):
            if self.path != "/v1/privacy":
                return self._send(404, {"error": "not found"})
            try:
                records = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))["records"]
                assert isinstance(records, list) and all(isinstance(r, dict) for r in records)
            except Exception:  # noqa: BLE001
                return self._send(422, {"error": "body must be {\"records\": [record, ...]}"})
            self._send(200, {"results": laya.score(records)})

        def log_message(self, fmt, *a):  # records are private: log nothing about them
            pass

    # Loopback only: the records are unmasked screen text apart from identifiers.
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print("Laya v4 on http://127.0.0.1:%d/v1/privacy (%s)" % (args.port, args.device), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
