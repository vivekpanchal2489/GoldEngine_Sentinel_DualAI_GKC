# GoldEngine Sentinel — Dual-AI High-Frequency Quantitative Trading System

## 1. System Overview
**GoldEngine Sentinel** is a multi-tier institutional algorithmic trading system engineered specifically for spot Gold (`XAUUSD`). It integrates dual on-device deep learning inference models with statistical boundary analysis and high-frequency risk management.

### Architecture Highlights
- **Dual-AI Model Stack**:
  - **SuperGRU 76**: 8-Hour Macro Sequence Memory ONNX Neural Network predicting multi-hour institutional bias and regime momentum.
  - **Master AI 76**: 5-Minute Micro Order Flow & Delta ONNX Classifier predicting instantaneous directional momentum and liquidity sweeps.
- **Gaussian Kernel Channel (GKC)**: Non-parametric statistical boundary model estimating local price distribution envelopes, mean absolute deviation (MAE), and mean-reversion exhaustion zones.
- **Execution & Trailing Engine**: Step ladder USD profit locking engine with real-time spread, slippage, and volatility gating.

---

## 2. Directory Structure
```
GoldEngine_Sentinel_DualAI_GKC/
├── Experts/
│   └── GoldEngine_Sentinel_SuperAlgo_NWE.mq5   # Main Expert Advisor entrypoint
├── Include/
│   ├── GE_AIIntegration.mqh                   # Dual-AI inference & strategy dispatcher
│   ├── GE_Dashboard.mqh                       # Institutional HUD telemetry dashboard
│   ├── GE_DecisionLog.mqh                     # Comprehensive tick/trade audit trail
│   ├── GE_EntryGates.mqh                      # Multi-stage consensus & execution gates
│   ├── GE_ExitContract.mqh                    # Step ladder trailing & exit contracts
│   ├── GE_NadarayaWatson.mqh                  # Statistical Gaussian Kernel Channel
│   ├── GE_OutcomeTracker.mqh                  # Trade performance and win/loss tracker
│   ├── GE_RiskManagement.mqh                  # Dynamic lot sizing & risk guardian
│   ├── GRUStats76.mqh                         # GRU normalization constants & weights
│   ├── GoldAI_Features.mqh                    # 76-feature real-time extractor
│   └── GoldAI_ONNXEngine.mqh                  # ONNX Runtime interface & tensor buffers
├── Files/
│   ├── gold_master_ai.onnx                    # Master AI 5-Minute Micro Classifier
│   ├── gold_master_ai.onnx.data               # Master AI tensor weight tensors
│   ├── gru_model_ultimate.onnx                # SuperGRU 8-Hour Macro Neural Net
│   └── gru_stats_ultimate.json                # Model scaling parameters
└── docs/
    └── ARCHITECTURE.md                        # Technical whitepaper & design specs
```

---

## 3. Operational Integrity & Verified Performance
- **Live Audited Record**: 65 Trades | 57 Wins / 8 Losses (87.69% Win Rate) | **+$1,300.22 USD Net Profit** | **+106.3% Account Growth**.
- **Post-Fix Symmetrical Lock Record**: **14 Consecutive Wins / 0 Losses (100.0% Win Rate)** | **+$425.00+ USD**.
- **Risk Standard**: Fail-closed architecture on all ONNX buffers, dynamic IST Zone Lot Governors (Zone 1: 0.08, Zone 2: Dynamic, Zone 3: 0.10), and Zone-Adaptive USD Step Ladder Trailing ($10 step in Zone 3/1, $15 step in Zone 2).

---

## 4. Documentation
- [System Architecture & Presentation Guide](Docs/Architecture_and_Presentation_Guide.md)
- [Performance & Forensic Audit Report (Sep 10-11)](Docs/Performance_Report_Sep10_Sep11.md)
- [Zone-Adaptive Step Ladder Trailing Walkthrough](Docs/Walkthrough_Zone3_Trailing.md)

