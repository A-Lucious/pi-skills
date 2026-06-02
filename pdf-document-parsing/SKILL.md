---
name: pdf-document-parsing
description: Convert PDFs and documents to structured formats (Markdown, JSON) for LLM/ RAG pipelines. Three tools with automatic selection: (1) OpenDataLoader PDF — #1 benchmark accuracy (0.907), bounding boxes, hybrid AI, auto-tagging, Java required; (2) MinerU — high-precision OCR/formula/table extraction, GPU-friendly, heavy deps; (3) MarkItDown — lightweight multi-format converter (PDF/DOCX/PPTX/XLSX/HTML/audio/YouTube), minmal deps, quick & simple. Use when extracting text, tables, or structured data from documents for LLM context, RAG indexing, or text analysis. Priority: OpenDataLoader >MinerU >MarkItDown unless user specifies otherwise.
---

# Document Parsing — Unified Skill

Three PDF/document-to-Markdown tools in a **shared environment**. Selection priority: **OpenDataLoader PDF > MinerU > MarkItDown** (unless the user specifies otherwise).


## Tool Selection Guide

| Scenario | Best Tool | Why |
|----------|-----------|-----|
| PDF → JSON with bounding boxes for RAG citations | **OpenDataLoader** | Only tool with per-element bbox; #1 table accuracy |
| PDF → Markdown with highest accuracy | **OpenDataLoader** | #1 overall benchmark (0.907), deterministic + AI hybrid |
| Scanned/image PDF needing OCR | **OpenDataLoader** (hybrid) or **MinerU** | Both support OCR; ODL is faster, MinerU handles more languages |
| Scientific PDF with LaTeX formulas | **OpenDataLoader** (hybrid) | Native LaTeX extraction in JSON |
| Complex/nested/borderless tables | **OpenDataLoader** (hybrid) | 0.928 table accuracy (#1) |
| DOCX / PPTX / XLSX → Markdown | **MarkItDown** | Lightweight, built for Office formats; MinerU also supports |
| HTML / CSV / JSON / XML → Markdown | **MarkItDown** | Only tool supporting these text-based formats |
| Audio / YouTube / EPUB / ZIP | **MarkItDown** | Only tool supporting these |
| Batch processing large PDF volumes | **OpenDataLoader** | 60+ pages/sec local, 100+ pages/sec multi-process |
| PDF accessibility / auto-tagging | **OpenDataLoader** | Only tool with Tagged PDF output |
| Need GPU acceleration for OCR | **MinerU** | CUDA/MPS acceleration built-in |
| Quick single-file conversion, minimal setup | **MarkItDown** | `pip install markitdown[all]`, one command |
| Chinese/Japanese/Korean documents | **OpenDataLoader** (hybrid with `--ocr-lang`) or **MinerU** | Both support CJK OCR |


## Prerequisites (System-Level)

These are checked once, outside the shared venv:

```bash
# OpenDataLoader requires Java 11+
java -version 2>&1 || echo "Java not found — install JDK 11+ from https://adoptium.net/"

# MinerU may benefit from GPU; check CUDA availability (optional)
nvidia-smi 2>/dev/null && echo "GPU detected — will use CUDA for MinerU" || echo "No GPU — MinerU will use CPU-only mode"
```


## Shared Environment Management

> **All three tools share a single `.venv`**. Never create multiple separate virtual environments for these tools.

### Step 1: Locate or Create the Shared Environment

Use `pdf-parse-env` as the canonical venv name. Check existing environments in priority order:

```bash
# 1. Check for existing pdf-parse-env in current dir or ancestors
ls -d pdf-parse-env */pdf-parse-env ../pdf-parse-env ../../pdf-parse-env .venv ../.venv 2>/dev/null

# 2. If none found, create the shared env
python3 -m venv pdf-parse-env
source pdf-parse-env/bin/activate
pip install --upgrade pip uv
```

### Step 2: Activate and Install on Demand

Always activate the shared env first, then install only the tool(s) needed for the current task:

```bash
source pdf-parse-env/bin/activate
```

### Step 3: Verify Installed Tools

```bash
# Which tools are available?
source pdf-parse-env/bin/activate
python -c "import opendataloader_pdf; print('OpenDataLoader:', opendataloader_pdf.__version__)" 2>/dev/null || echo "OpenDataLoader not installed"
which mineru && mineru --version 2>/dev/null || echo "MinerU not installed"
which markitdown 2>/dev/null || echo "MarkItDown not installed"
```

### Install as Needed

```bash
source pdf-parse-env/bin/activate

# For OpenDataLoader
pip install -U opendataloader-pdf
# Optional: hybrid mode
pip install -U "opendataloader-pdf[hybrid]"
# Optional: LangChain
pip install -U langchain-opendataloader-pdf

# For MinerU (heavy — CPU-only torch preferred if no GPU)
uv pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
uv pip install -U "mineru[all]"

# For MarkItDown
pip install 'markitdown[all]'
```


---

# 1. OpenDataLoader PDF (PRIORITY DEFAULT)

**#1 benchmark accuracy (0.907). Bounding boxes for every element. Deterministic + AI hybrid. Tagged PDF output. Java required.**

- Input: PDF only
- Output: Markdown, JSON (with bbox), HTML, Annotated PDF, Text, Tagged PDF
- SDKs: Python, Node.js, Java
- Requires: Java 11+ (no GPU)
- License: Apache 2.0

## Installation (into shared env)

```bash
source pdf-parse-env/bin/activate
pip install -U opendataloader-pdf
# Hybrid AI mode (optional):
pip install -U "opendataloader-pdf[hybrid]"
```

## Quick Start

```python
import opendataloader_pdf

# Batch all files in one call — each convert() spawns a JVM process
opendataloader_pdf.convert(
    input_path=["file1.pdf", "file2.pdf", "folder/"],
    output_dir="output/",
    format="markdown,json"
)
```

> **Performance**: Pass all files in one `convert()` call. Do NOT loop per-file — each call spawns a JVM process.

## Mode Selection

| Document Type | Mode | Setup |
|---------------|------|-------|
| Standard digital PDF | Fast (default) | No server needed |
| Complex/nested tables | Hybrid | `opendataloader-pdf-hybrid --port 5002` |
| Scanned/image PDF (OCR) | Hybrid + OCR | server: `--force-ocr` |
| Non-English scanned | Hybrid + OCR | server: `--force-ocr --ocr-lang "ko,en"` |
| Math formulas (LaTeX) | Hybrid + formula | server: `--enrich-formula`, client: `--hybrid-mode full` |
| Chart/image descriptions | Hybrid + picture | server: `--enrich-picture-description`, client: `--hybrid-mode full` |
| Untagged → accessible | Auto-tagging | `--format tagged-pdf` |

### Hybrid Mode Setup

```bash
# Terminal 1: Backend server
opendataloader-pdf-hybrid --port 5002

# Terminal 2: Process
opendataloader-pdf --hybrid docling-fast file.pdf
```

Python hybrid:

```python
opendataloader_pdf.convert(
    input_path=["file.pdf"],
    output_dir="output/",
    hybrid="docling-fast"
)
```

### Important Gotchas

- `--enrich-formula` / `--enrich-picture-description` on server → client MUST use `--hybrid-mode full`, otherwise silently skipped
- `--format` values: `json`, `markdown`, `html`, `pdf`, `text`, `tagged-pdf` (output kinds only); markdown-with-html/images are separate flags
- Hidden text filtering (`filter_hidden_text`) is **off by default**

## JSON Output (Bounding Boxes)

```json
{
  "type": "heading",
  "id": 42,
  "level": "Title",
  "page number": 1,
  "bounding box": [72.0, 700.0, 540.0, 730.0],
  "heading level": 1,
  "font": "Helvetica-Bold",
  "font size": 24.0,
  "content": "Introduction"
}
```

Key fields: `type`, `bounding box` (left, bottom, right, top in points), `page number`, `heading level`, `content`.

## Advanced Options

```python
opendataloader_pdf.convert(
    input_path=["file.pdf"],
    output_dir="output/",
    format="json,markdown",
    image_output="embedded",        # off | embedded (Base64) | external (default)
    image_format="jpeg",            # png (default) | jpeg
    use_struct_tree=True,           # Native PDF structure tags
    reading_order="xycut",          # off | xycut (default)
    table_method="cluster",         # default (border-based) | cluster
    hybrid="docling-fast",
    pages="1,3,5-7",              # Page range
    filter_hidden_text=True,        # Off by default
    sanitize=True,                  # Replace sensitive data → placeholders
)
```

## Hybrid Options Reference

| Option | Values |
|--------|--------|
| `--hybrid` | `off` (default), `docling-fast` |
| `--hybrid-url` | Custom backend URL |
| `--hybrid-timeout` | ms (0 = no timeout) |
| `--hybrid-fallback` | Fall back to Java on backend error |
| `--hybrid-mode` | `auto` (triage per page), `full` (all to backend) |

## Auto-Tagging (Accessibility)

```python
# Untagged PDF → Tagged PDF (screen-reader ready)
opendataloader_pdf.convert(
    input_path=["untagged.pdf"],
    output_dir="output/",
    format="tagged-pdf"
)
```

## LangChain Integration

```python
from langchain_opendataloader_pdf import OpenDataLoaderPDFLoader
from langchain_text_splitters import RecursiveCharacterTextSplitter

loader = OpenDataLoaderPDFLoader(file_path=["file.pdf"], format="text")
documents = loader.load()
chunks = RecursiveCharacterTextSplitter(chunk_size=500, chunk_overlap=50).split_documents(documents)
```

## RAG Chunking Strategies

1. **By Element**: One chunk per paragraph/heading/list — fine-grained, precise citations
2. **By Section**: Group under headings — context-rich, topic-based search
3. **Merged (min size)**: Combine adjacent elements until 200+ chars — balanced sizes

Each chunk: `{"text": ..., "metadata": {"type": "paragraph", "page": 1, "bbox": [...], "source": "file.pdf"}}`

## Performance

| Mode | Speed | Accuracy |
|------|-------|----------|
| Local (default) | 60+ pages/sec | 0.831 |
| Hybrid | 2+ pages/sec | **0.907 (#1)** |
| Multi-process batch | 100+ pages/sec | — |

No GPU required. Benchmarked on Apple M4.

## Bounding Boxes for Source Citations

Map RAG answer chunks back to exact PDF locations using `bounding box` + `page number` → highlight source in viewer ("click to source" UX). No other open-source parser provides this for every element.

## Capability Matrix

| Capability | Mode |
|------------|------|
| Reading order (XY-Cut++) | Default |
| Bounding boxes (all elements) | Default |
| Tables (simple) | Default |
| Tables (complex/borderless) | Hybrid |
| Heading hierarchy | Default |
| Nested lists | Default |
| Images with coordinates | Default |
| OCR (80+ languages) | Hybrid + `--force-ocr` |
| LaTeX formula extraction | Hybrid + `--enrich-formula` |
| AI chart/image descriptions | Hybrid + `--enrich-picture-description` |
| Tagged PDF support | Default (`use_struct_tree=True`) |
| Auto-tagging → Tagged PDF | Default (`format="tagged-pdf"`) |
| AI safety (hidden text/sanitize) | Opt-in |
| Header/footer filtering | Default |
| Page range extraction | Default (`--pages`) |


---

# 2. MinerU (HIGH-PRECISION FALLBACK)

**High-precision document parsing with GPU-accelerated OCR, formula, and table extraction. Supports PDF, images, DOCX, PPTX, XLSX.**

- Input: PDF, images, DOCX, PPTX, XLSX
- Output: Markdown, JSON
- Backends: pipeline (CPU), vlm (GPU/VLM), hybrid, http-client
- Requires: Python 3.10+ (GPU optional but recommended)
- License: AGPL-3.0

> Use MinerU when: OpenDataLoader is unavailable (no Java), GPU acceleration is desired, or document has CJK text that ODL struggles with.

## Installation (into shared env)

```bash
source pdf-parse-env/bin/activate

# CPU-only torch (prefer if no GPU)
uv pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
uv pip install -U "mineru[all]"
```

If huggingface is inaccessible, switch model source:

```bash
export MINERU_MODEL_SOURCE=modelscope
# Or for local models:
export MINERU_MODEL_SOURCE=local
```

## Quick Start

```bash
source pdf-parse-env/bin/activate
mineru -p <input_path> -o <output_path>
```

- `<input_path>`: PDF / image / DOCX / PPTX / XLSX file or directory
- Without `--api-url`: CLI launches a temporary local mineru-api
- With `--api-url`: connects to an existing FastAPI service

## Backend Modes

```bash
# GPU auto-detect (default — uses CUDA/MPS if available)
mineru -p input.pdf -o output/

# CPU-only
mineru -p input.pdf -o output/ -b pipeline

# HTTP client (lightweight, no local torch)
mineru -p input.pdf -o output/ -b vlm-http-client -u http://127.0.0.1:30000

# Hybrid HTTP client (requires local pipeline deps)
mineru -p input.pdf -o output/ -b hybrid-http-client -u http://127.0.0.1:30000
```

## Python API — Key Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `backend` | `hybrid-auto-engine` | `pipeline`, `vlm-auto-engine`, `vlm-http-client`, `hybrid-http-client` |
| `parse_method` | `auto` | `auto`, `txt` (text only), `ocr` (force OCR) |
| `language` | `ch` | OCR language hint |
| `formula_enable` | `true` | Enable formula parsing |
| `table_enable` | `true` | Enable table parsing |
| `image_analysis` | `true` | Enable image/chart analysis (VLM/hybrid) |
| `api_url` | `None` | Existing FastAPI URL; `None` = temp local server |
| `server_url` | `None` | Required for `*-http-client` backends |
| `start_page_id` | `0` | Zero-based start page |
| `end_page_id` | `None` | End page (`None` = to end) |

## FastAPI Server

```bash
mineru-api --host 0.0.0.0 --port 8000
```

Endpoints: `/health`, `/tasks` (async), `/file_parse` (sync), `/tasks/{id}`, `/tasks/{id}/result`.

## Router (Multi-GPU)

```bash
mineru-router --host 0.0.0.0 --port 8002 --local-gpus auto
```

## Configuration

Edit `mineru.json` in user directory (auto-generated by `mineru-models-download`):

- `latex-delimiter-config`: LaTeX delimiters (default `$`)
- `llm-aided-config`: LLM-assisted title hierarchy (any OpenAI-protocol LLM)
- `models-dir`: Local model storage paths for pipeline/vlm backends


---

# 3. MarkItDown (LIGHTWEIGHT BROAD-FORMAT)

**Minimal, broad-format converter. Best when you need quick & simple, or for non-PDF formats (DOCX/PPTX/XLSX/HTML/audio/YouTube/EPUB/ZIP).**

- Input: PDF, DOCX, PPTX, XLSX/XLS, images, audio, HTML, CSV/JSON/XML, ZIP, EPUB, YouTube, Outlook .msg, Jupyter notebooks, RSS, Wikipedia
- Output: Markdown only
- Requires: Python 3.10+
- License: MIT

> Use MarkItDown when: you need to convert non-PDF formats, want zero-config simplicity, or don't need bounding boxes/structured JSON.

## Installation (into shared env)

```bash
source pdf-parse-env/bin/activate
pip install 'markitdown[all]'
```

## Quick Start

```bash
# CLI
markitdown path-to-file.pdf -o document.md
cat path-to-file.pdf | markitdown

# Python
from markitdown import MarkItDown
md = MarkItDown()
result = md.convert("document.pdf")
print(result.markdown)
```

## Convert Method Variants

| Method | Input | Use When |
|--------|-------|----------|
| `convert_local(path)` | `str` or `Path` | Local files only (most secure) |
| `convert_stream(stream)` | `BinaryIO` | In-memory byte stream |
| `convert_response(resp)` | `requests.Response` | Pre-fetched HTTP response |
| `convert_uri(uri)` | `str` | file://, http(s)://, data:// URIs |
| `convert(source)` | anything above | General purpose (auto-dispatch) |

> **Security**: Prefer `convert_local()` for local files and `convert_response()` for HTTP. `convert()` is permissive and can access both local and remote resources.

## LLM Image Descriptions

```python
from markitdown import MarkItDown
from openai import OpenAI

md = MarkItDown(llm_client=OpenAI(), llm_model="gpt-4o")
result = md.convert("presentation.pptx")  # AI describes slide images
result = md.convert("photo.jpg")          # AI describes photo
```

Works with any OpenAI-compatible client (Azure, Ollama, LM Studio).

## Azure Document Intelligence

```python
md = MarkItDown(docintel_endpoint="<endpoint>")
result = md.convert("document.pdf")
```

## Azure Content Understanding

Superior cloud extraction with **structured YAML front matter** and audio/video support:

```python
md = MarkItDown(cu_endpoint="<endpoint>")
result = md.convert("report.pdf")   # auto-routes to document analyzer
result = md.convert("meeting.mp4")  # auto-routes to video analyzer

# Custom analyzer for domain-specific fields
md = MarkItDown(cu_endpoint="<endpoint>", cu_analyzer_id="my-invoice-analyzer")
result = md.convert("invoice.pdf")
# Output includes YAML: fields: { VendorName: CONTOSO LTD., InvoiceDate: '2019-11-15' }
```

## Plugins (OCR etc.)

```bash
pip install markitdown-ocr
```

```python
md = MarkItDown(enable_plugins=True, llm_client=OpenAI(), llm_model="gpt-4o")
result = md.convert("scanned_document.pdf")
```

OCR plugin: LLM Vision extracts text from embedded images in PDF/DOCX/PPTX/XLSX. Scanned PDFs auto-detected (full-page rendering at 300 DPI).

## Optional Dependencies

| Extra | Provides |
|-------|----------|
| `[all]` | Everything |
| `[pdf]` | PDF support |
| `[docx]` | Word support |
| `[pptx]` | PowerPoint support |
| `[xlsx]` / `[xls]` | Excel support |
| `[outlook]` | Outlook .msg support |
| `[az-doc-intel]` | Azure Document Intelligence |
| `[az-content-understanding]` | Azure Content Understanding |
| `[audio-transcription]` | WAV/MP3 transcription |
| `[youtube-transcription]` | YouTube transcription |

## Supported Formats (Full List)

PDF, DOCX, PPTX, XLSX, XLS, images (JPG/PNG), audio (WAV/MP3/M4A), HTML, CSV, JSON, XML, ZIP, EPUB, Jupyter Notebook (.ipynb), Outlook .msg, RSS feeds, Wikipedia pages, YouTube, Bing SERP, plain text.

## Performance & Limitations

- **Purely offline** (except Azure variants)
- **No GPU required**
- **No bounding boxes** — Markdown text only, no element coordinates
- **No JSON output** — Markdown only
- **No OCR by default** — requires `markitdown-ocr` plugin + LLM client
- **Tables preserved** as Markdown table syntax


---

## Quick Decision Tree

```
Input is PDF?
├── Need bounding boxes / JSON / #1 accuracy? → OpenDataLoader
├── Need Tagged PDF for accessibility? → OpenDataLoader (auto-tagging)
├── Have GPU and need high-precision OCR/formulas? → MinerU
├── Quick & simple, just want Markdown? → MarkItDown
└── Default: → OpenDataLoader

Input is DOCX / PPTX / XLSX?
├── Need high-precision parsing? → MinerU
├── Quick & simple? → MarkItDown
└── Default: → MarkItDown (lightest)

Input is HTML / CSV / JSON / XML / ZIP / EPUB / Audio / YouTube?
└── → MarkItDown (only tool supporting these)

Input is images?
├── With bounding boxes? → OpenDataLoader (PDF only) or MinerU
├── Quick description? → MarkItDown (with LLM client)
└── High-precision OCR? → MinerU
```
