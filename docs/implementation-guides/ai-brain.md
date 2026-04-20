# AI Brain Implementation Guide

## Overview

The AI Brain provides real-time natural language processing for USSD sessions, including translation, intent detection, personalization, and PII redaction. It operates as a gRPC service within the `python-gateway` package.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  AI Brain gRPC Server (Python)                               │
│  ├─ LlamaModelAdapter (llama.cpp)                           │
│  ├─ ONNXRuntimeAdapter (quantized models)                   │
│  ├─ DictionaryFallback (dev/test)                           │
│  └─ PII Redaction Pipeline                                   │
└─────────────────────┬───────────────────────────────────────┘
                      │ Load model from path
                      ▼
┌─────────────────────────────────────────────────────────────┐
│  Model Storage                                               │
│  ├─ /models/llama-7b-chat.Q4_K_M.gguf (translation)         │
│  ├─ /models/intent-classifier.onnx                          │
│  └─ /models/pii-detector.onnx                               │
└─────────────────────────────────────────────────────────────┘
```

## Model Deployment

### Llama.cpp (Translation & Generation)

```bash
# Download quantized model
wget https://huggingface.co/TheBloke/Llama-2-7B-Chat-GGUF/resolve/main/llama-2-7b-chat.Q4_K_M.gguf \
  -O /models/llama-7b-chat.Q4_K_M.gguf

# Environment
export LLAMA_MODEL_PATH=/models/llama-7b-chat.Q4_K_M.gguf
export LLAMA_N_CTX=2048
export LLAMA_N_THREADS=4
```

The `LlamaModelAdapter` loads the model at startup and provides:
- `translate(text, target_language)` — Shona/Ndebele ↔ English
- `generate_response(prompt, max_tokens)` — Contextual menu suggestions

### ONNX Runtime (Classification)

For intent detection and PII redaction, use ONNX quantized models:

```python
import onnxruntime as ort

session = ort.InferenceSession("/models/intent-classifier.onnx")
outputs = session.run(None, {"input": tokenized_text})
```

Benefits:
- < 50ms inference on CPU
- No Python GIL contention
- Cross-platform deployment

### Fallback Strategy

```
1. Try ONNX runtime (fastest)
2. Fall back to llama.cpp (most capable)
3. Fall back to dictionary-based stubs (always available)
```

## Translation Service

### Supported Languages

| Language | Code | Model | Accuracy Target |
|----------|------|-------|----------------|
| English | `en` | Native | — |
| Shona | `sn` | Llama-7B | 85% BLEU |
| Ndebele | `nd` | Llama-7B | 80% BLEU |
| Chichewa | `ny` | Llama-7B | 75% BLEU |

### Prompt Engineering

```
Translate the following USSD menu text to {language}.
Keep all numbers and option markers (1., 2., etc.) unchanged.
Text: {text}
Translation:
```

## Personalization Engine

The personalization engine adapts menu ordering based on user history:

```python
def personalize(menu_items: list, user_profile: dict) -> list:
    """
    Reorder menu items by predicted preference.
    Uses collaborative filtering + content-based scoring.
    """
    scores = []
    for item in menu_items:
        score = (
            0.4 * historical_frequency(user_profile["user_id"], item["id"]) +
            0.3 * time_of_day_preference(item["id"]) +
            0.3 * demographic_similarity(user_profile, item["target_demographic"])
        )
        scores.append((item, score))
    return [item for item, _ in sorted(scores, key=lambda x: x[1], reverse=True)]
```

## PII Detection & Redaction

PII is detected using a fine-tuned ONNX NER model:

| Entity Type | Pattern | Redaction |
|-------------|---------|-----------|
| `PHONE` | `2637[1378]\d{8}` | `[PHONE]` |
| `NATIONAL_ID` | `\d{2}-\d{6,7}[A-Z]\d{2}` | `[ID]` |
| `ACCOUNT_NUMBER` | `\d{10,16}` | `[ACCT]` |
| `NAME` | NER label `PER` | `[NAME]` |

All outbound logs and analytics events are redacted before storage.

## Model Versioning & A/B Testing

Models are versioned via environment variables:

```
AI_MODEL_VERSION=v2.3.1
AI_EXPERIMENT_ID=menu-reorder-b
```

A/B test assignments are stored in Redis:
```
Key:    ai:experiment:{user_id}
Value:  {"variant": "B", "model_version": "v2.3.1"}
```

## Performance Targets

| Metric | Target | Measurement |
|--------|--------|-------------|
| Translation p99 | < 200ms | gRPC server histogram |
| Intent detection p99 | < 150ms | gRPC server histogram |
| Model load time | < 30s | Startup log |
| GPU memory | < 8GB | nvidia-smi |
| CPU threads | 4 | Configurable |

## Deployment

### Docker

```dockerfile
FROM python:3.12-slim
RUN apt-get update && apt-get install -y libgomp1
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY models/ /models/
ENV LLAMA_MODEL_PATH=/models/llama-7b-chat.Q4_K_M.gguf
CMD ["python", "-m", "openai_ussd_kernel.ai.ports.grpc_server"]
```

### Kubernetes

```yaml
resources:
  requests:
    memory: "4Gi"
    cpu: "2"
  limits:
    memory: "16Gi"
    cpu: "4"
```

## Monitoring

- `ai_model_load_duration_seconds` — Model initialization time
- `ai_inference_duration_seconds` — Per-method inference latency
- `ai_cache_hit_ratio` — Translation cache effectiveness
- `ai_pii_detected_total` — PII redaction counter
