# Whisper / mlx-whisper — OpenAI 오픈소스 STT

## 한 줄 소개

OpenAI가 2022년 오픈소스로 공개한 STT. 99개 언어 지원. **한국어 정확도
최고 수준**. mlx-whisper는 Apple Silicon 가속 변형.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 라이선스 | MIT (모델 가중치 포함) |
| 모델 크기 | tiny (39M) / base (74M) / small (244M) / medium (769M) / large (1.5B) / large-v3 (1.5B) / large-v3-turbo (809M) |
| 한국어 WER | large-v3: ~5% / turbo: ~6% / medium: ~10% |
| Apple Silicon | mlx-whisper로 가속 (Neural Engine + Metal) |
| 메모리 | turbo 1.5 GB / large-v3 3 GB (양자화 없음) |

## DarwinForge 통합 후보

### 옵션 A — mlx-whisper (Python subprocess)

```sh
# 설치
pip install mlx-whisper
mlx_whisper --model mlx-community/whisper-large-v3-turbo --language ko audio.wav
```

```swift
// Swift에서 subprocess로 호출
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/local/bin/mlx_whisper")
task.arguments = [
    "--model", "mlx-community/whisper-large-v3-turbo",
    "--language", "ko",
    "--output-format", "json",
    audioPath
]
task.standardOutput = Pipe()
try task.run()
task.waitUntilExit()
// stdout JSON 파싱 → transcript
```

지연: 10초 음성 → ~1.5초 처리 (M1 Max 기준).

### 옵션 B — Whisper.cpp (Rust subprocess)

```sh
brew install whisper-cpp
whisper-cli -m models/ggml-large-v3-q5_0.bin -l ko audio.wav
```

지연: 10초 → ~2~3초 (CPU only).

### 옵션 C — coreml-whisper (Apple Neural Engine)

```sh
# OpenAI 공식 Core ML 변환 가이드
git clone https://github.com/openai/whisper
python -m whisper.coreml --model large-v3
```

지연: 가장 빠름 (~0.5초). 메모리 활용 효율 ★.

## 비교 — DarwinForge 권장

| 옵션 | 한국어 WER | 지연 | 메모리 | 설치 복잡도 |
|------|-----------|------|--------|-------------|
| Apple Speech | ~10% | 0.3s | 작음 | 가장 쉬움 |
| **mlx-whisper turbo** ★ | **~6%** | **1.5s** | 1.5 GB | 중 |
| Whisper.cpp medium | ~10% | 2s | 800 MB | 쉬움 |
| coreml-whisper large-v3 | ~5% | 0.5s | 3 GB | 어려움 |

→ **권장**: Apple Speech 1차 + mlx-whisper turbo 폴백 (사용자 설정 토글).

## DarwinForge 채택

★★★ — Apple Speech가 부족할 때 폴백. 시끄러운 환경 / 사투리에서 결정적.

## 출처

- OpenAI Whisper: https://github.com/openai/whisper
- Whisper paper: https://arxiv.org/abs/2212.04356
- mlx-whisper: https://github.com/ml-explore/mlx-examples/tree/main/whisper
- Whisper.cpp: https://github.com/ggerganov/whisper.cpp
- mlx-community Hugging Face: https://huggingface.co/mlx-community
