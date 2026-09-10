# FPGA Semi-General Purpose CNN Convolution Accelerator

[한국어](#한국어) | [English](#english)

---

## 한국어

**CNN 컨볼루션 연산을 위한 준-범용 FPGA 가속기 설계 및 구현**

중앙대학교 전자전기공학부 2025학년도 학사학위논문(종합설계보고서) — 지도교수 한동현

### 프로젝트 개요

Zynq-7000 SoC 기반 FPGA(Digilent Arty Z7-20)에 3×3 컨볼루션 연산 전용 CNN 가속기 IP를 설계·검증했습니다. 특정 모델 구조에만 맞춰 하드코딩되는 기존 CNN 가속기와 달리, 입력 크기·채널 수·패딩·스트라이드가 달라져도 **동일한 하드웨어로 대응 가능한 준-범용(Semi-General Purpose) 구조**로 설계했습니다.

### 핵심 아키텍처

- **Shift Buffer**: 동적 인덱싱(MUX) 대신 버퍼 자체를 시프트시키는 방식으로 3×3 윈도우를 구성 — 가변 입력 크기·패딩·스트라이드에 동일한 로직으로 대응
- **MAC9 병렬 유닛 × 16개**: 유닛당 9개 곱셈기, 3단 파이프라인 구조로 매 클럭 16개 출력 채널을 동시 연산 (단일 유닛 대비 약 16배 속도 향상)
- **BRAM + FIFO 혼합 메모리**: 필터/바이어스는 BRAM에, 다채널 누적은 FIFO 구조로 처리 — 임의 주소 접근 방식(BRAM만 사용 시 최대 16.8Mbit 필요) 대비 약 **8배 메모리 절감**(약 2.1Mbit)
- **FSM 기반 전 과정 자동 제어**: 파라미터 설정 → 입력 스트리밍 → 연산 → 출력까지 하드웨어 단독 수행
- **AXI 표준 인터페이스**: AXI4-Lite(파라미터 제어), AXI4-Stream(데이터 스트리밍), AXI4 DMA(메모리 접근) — Vivado IP Packager로 재사용 가능한 IP로 패키징
- **정수형 양자화**: 입력/가중치 INT8, 바이어스 INT32 — PYNQ 기반 Python 드라이버가 AXI-Lite로 하이퍼파라미터를 설정하고 DMA로 데이터를 스트리밍

### 지원 사양

| 항목 | 범위 |
|---|---|
| 필터 크기 | 3×3 (고정) |
| 입력 크기 | 1×1 ~ 32×32 |
| 출력 채널 | 최대 512 |
| 패딩 | 0 ~ 2 |
| 스트라이드 | 제약 없음 |

### 검증 결과

| 검증 단계 | 결과 |
|---|---|
| RTL 시뮬레이션 | 테스트벤치로 기초 동작 검증 |
| 랜덤 정수 데이터 (32×32, 16ch→32ch, pad 2, stride 5) | CPU 결과와 완전 일치, **약 921배 가속** |
| Simple VGG (CIFAR-10 자체 학습) 하이브리드 추론 | 정확도 80.7%→80.6% (−0.1%p), **12.71배 가속** |
| VGG16 (Torchvision 파인튜닝) 하이브리드 추론 | 정확도 83.0%→81.0% (−2.0%p), **16.88배 가속** |

Vivado 합성 결과 (Arty Z7-20 기준): LUT 17.67%, LUTRAM 4.88%, FF 9.99%, BRAM 60.00%, DSP 65.45% 사용, 100MHz 동작 시 타이밍 여유(WNS) 0.274ns 확보.

### 개발 환경

- FPGA 보드: Digilent Arty Z7-20 (Zynq XC7Z020-1CLG400C)
- 개발 도구: Vivado 2022.1/2022.2
- 임베디드 환경: PYNQ 2.7 (Python 3.8), Jupyter Notebook
- 실험 환경: PyTorch 1.8.1, Torchvision 0.9.1 (armv7l)

### 폴더 구조

```
verilog/       RTL 소스 (convolution.sv, MAC9.sv) 및 테스트벤치
python/        모델 학습·양자화·검증용 Jupyter 노트북 (PYNQ 드라이버 포함)
c_reference/   YOLOv2 forward network C 참조 구현
docs/          최종보고서, 최종발표자료, 요약서, 제안서 (PDF)
```

---

## English

**Semi-General Purpose FPGA Accelerator for CNN Convolution: Design and Implementation**

Bachelor's capstone thesis, School of Electrical and Electronics Engineering, Chung-Ang University (2025) — Advisor: Prof. Donghyun Han

### Overview

We designed and verified a dedicated 3×3 convolution accelerator IP on a Zynq-7000 SoC FPGA (Digilent Arty Z7-20). Unlike conventional hard-coded CNN accelerators tied to one model architecture, this IP is a **semi-general-purpose** design that handles varying input sizes, channel counts, padding, and stride using the same hardware.

### Key Architecture

- **Shift Buffer**: instead of dynamic MUX-based indexing, the buffer itself shifts to form the 3×3 window — the same logic handles any input size, padding, or stride
- **16× parallel MAC9 units**: each with 9 multipliers in a 3-stage pipeline, computing 16 output channels per clock (~16x speedup over a single unit)
- **BRAM + FIFO hybrid memory**: filters/bias in BRAM, multi-channel accumulation via FIFO — roughly **8x memory savings** (~2.1Mbit vs. up to 16.8Mbit for a naive random-access BRAM buffer)
- **Fully automated FSM control**: parameter setup → input streaming → compute → output, all handled by hardware alone
- **Standard AXI interfaces**: AXI4-Lite (parameter control), AXI4-Stream (data streaming), AXI4 DMA (memory access) — packaged as a reusable IP via Vivado IP Packager
- **Integer quantization**: INT8 input/weights, INT32 bias — a PYNQ-based Python driver sets hyperparameters over AXI-Lite and streams data via DMA

### Supported Specs

| Parameter | Range |
|---|---|
| Kernel size | 3×3 (fixed) |
| Input size | 1×1 to 32×32 |
| Output channels | up to 512 |
| Padding | 0 to 2 |
| Stride | unrestricted |

### Verification Results

| Stage | Result |
|---|---|
| RTL simulation | Basic functional correctness via testbench |
| Random integer data (32×32, 16ch→32ch, pad 2, stride 5) | Exact match with CPU, **~921x speedup** |
| Simple VGG (custom, CIFAR-10) hybrid inference | Accuracy 80.7%→80.6% (−0.1pp), **12.71x speedup** |
| VGG16 (Torchvision, fine-tuned) hybrid inference | Accuracy 83.0%→81.0% (−2.0pp), **16.88x speedup** |

Vivado synthesis (Arty Z7-20): LUT 17.67%, LUTRAM 4.88%, FF 9.99%, BRAM 60.00%, DSP 65.45% utilized, with 0.274ns timing slack (WNS) at 100MHz.

### Dev Environment

- FPGA board: Digilent Arty Z7-20 (Zynq XC7Z020-1CLG400C)
- Tools: Vivado 2022.1/2022.2
- Embedded: PYNQ 2.7 (Python 3.8), Jupyter Notebook
- Experiments: PyTorch 1.8.1, Torchvision 0.9.1 (armv7l)

### Repo Structure

```
verilog/       RTL sources (convolution.sv, MAC9.sv) and testbench
python/        Jupyter notebooks for training, quantization, and validation (incl. PYNQ driver)
c_reference/   C reference implementation of the YOLOv2 forward network
docs/          Final report, final presentation, summary, proposal (PDF)
```
