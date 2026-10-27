# Media Vault

[![CI](https://github.com/hrvanovicm/media-vault/actions/workflows/ci.yml/badge.svg)](https://github.com/hrvanovicm/media-vault/actions/workflows/ci.yml)

**Self-hosted, on-premise storage & media engine that takes the pain out of file uploads.**

Built for developers who are tired of re-inventing upload pipelines in every project, no more wiring up S3 buckets, writing resize logic etc.

---

## Key Highlights

### Infrastructure & Code Scalability
Scales horizontally without choking on memory.

### Low Resource Footprint
Built with lean libraries, so it runs ultra-fast with tiny RAM requirements. One small VM can comfortably handle heavy workloads.

### Pluggable & Decoupled
Storage drivers (S3, local disk, Google Drive, SharePoint, ...) and worker processes (antivirus, AI detection, parsers, ...) are completely decoupled. Runners run as separate processes and can live on entirely different machines.

### Declarative Rules
Configure processing rules — formats, sizes, compression — using clean JSON definitions per file system.

### Files Are More Than Bytes
Extract structured features (GPS polygons, camera EXIF, AI tags) and query them directly through the API.

---

## A Note on AI

100% hand-written production code.

AI is used **only** for docs formatting and task board outlines — all core logic, system architecture, and Go code are crafted by hand. No AI slop in the engine.
AI is genuinely useful, but for this project I want to actually enjoy writing the code myself. The only place AI may potentially write code is the front-end.