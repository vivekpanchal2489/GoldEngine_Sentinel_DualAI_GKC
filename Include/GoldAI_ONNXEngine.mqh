//+------------------------------------------------------------------+
//|                                           GoldAI_ONNXEngine.mqh  |
//|               Zero-Latency C++ ONNX Inference Engine for MT5     |
//+------------------------------------------------------------------+
#property copyright "Gold AI Institutional Quant"
#property link      "https://github.com"
#property strict

#define ONNX_INPUT_SIZE  76
#define ONNX_OUTPUT_SIZE 3

struct SModelPrediction
{
   bool   valid;
   double probBullish;
   double probNeutral;
   double probBearish;
   int    predictedClass;
   double confidence;
};

class CGoldAIONNXEngine
{
private:
   long     m_onnxHandle;
   string   m_modelPath;
   bool     m_initialized;
   
   float    m_inputBuffer[ONNX_INPUT_SIZE];
   float    m_outputBuffer[ONNX_OUTPUT_SIZE];
   
   float    m_lastProbBull;
   float    m_lastProbNeu;
   float    m_lastProbBear;

public:
   CGoldAIONNXEngine() : m_onnxHandle(INVALID_HANDLE), m_modelPath("gold_master_ai.onnx"), m_initialized(false),
      m_lastProbBull(0.0f), m_lastProbNeu(0.0f), m_lastProbBear(0.0f)
   {
      ArrayInitialize(m_inputBuffer, 0.0f);
      ArrayInitialize(m_outputBuffer, 0.0f);
   }
   
   ~CGoldAIONNXEngine()
   {
      Release();
   }
   
   bool Initialize(string modelFileName = "gold_master_ai.onnx")
   {
      m_modelPath = modelFileName;
      
      // Load ONNX Model from MT5 Files directory
      m_onnxHandle = OnnxCreate(m_modelPath, ONNX_DEFAULT);
      if(m_onnxHandle == INVALID_HANDLE)
      {
         PrintFormat("[GoldAI ONNX] ERROR: Failed to create ONNX session from '%s'. Error code: %d", m_modelPath, GetLastError());
         m_initialized = false;
         return false;
      }
      
      // 2D Tensor Shapes: [Batch=1, Features=ONNX_INPUT_SIZE] -> [Batch=1, Classes=3]
      const long input_shape[]  = {1, ONNX_INPUT_SIZE};
      const long output_shape[] = {1, ONNX_OUTPUT_SIZE};
      
      if(!OnnxSetInputShape(m_onnxHandle, 0, input_shape))
      {
         PrintFormat("[GoldAI ONNX] WARNING: Could not set input shape {1, %d}. Error: %d", ONNX_INPUT_SIZE, GetLastError());
      }
      if(!OnnxSetOutputShape(m_onnxHandle, 0, output_shape))
      {
         PrintFormat("[GoldAI ONNX] WARNING: Could not set output shape {1, %d}. Error: %d", ONNX_OUTPUT_SIZE, GetLastError());
      }
      
      m_initialized = true;
      PrintFormat("[GoldAI ONNX] SUCCESS: Loaded '%s' (Input Shape: 1x%d -> Output: 1x%d).", m_modelPath, ONNX_INPUT_SIZE, ONNX_OUTPUT_SIZE);
      return true;
   }

   bool Init(string modelFileName = "gold_master_ai.onnx", int lookback = 64, int nFeat = ONNX_INPUT_SIZE)
   {
      return Initialize(modelFileName);
   }
   
   void Release()
   {
      if(m_onnxHandle != INVALID_HANDLE)
      {
         OnnxRelease(m_onnxHandle);
         m_onnxHandle = INVALID_HANDLE;
      }
      m_initialized = false;
   }

   void Shutdown() { Release(); }
   
   float GetLastProbBull() { return m_lastProbBull; }
   float GetLastProbNeu()  { return m_lastProbNeu; }
   float GetLastProbBear() { return m_lastProbBear; }

   bool Predict(const float &features[], SModelPrediction &pred)
   {
      pred.valid = false;
      pred.probBullish = 0.0;
      pred.probNeutral = 0.0;
      pred.probBearish = 0.0;
      pred.predictedClass = 1;
      pred.confidence = 0.0;
      
      if(!m_initialized || m_onnxHandle == INVALID_HANDLE)
         return false;
         
      if(ArraySize(features) < ONNX_INPUT_SIZE)
      {
         PrintFormat("[GoldAI ONNX] Input size mismatch. Expected %d, got %d", ONNX_INPUT_SIZE, ArraySize(features));
         return false;
      }
      
      for(int i = 0; i < ONNX_INPUT_SIZE; i++)
         m_inputBuffer[i] = features[i];
         
      if(!OnnxRun(m_onnxHandle, ONNX_NO_CONVERSION, m_inputBuffer, m_outputBuffer))
      {
         PrintFormat("[GoldAI ONNX] Inference execution failed. Error code: %d", GetLastError());
         return false;
      }
      
      pred.valid = true;
      pred.probBullish = (double)m_outputBuffer[0];
      pred.probNeutral = (double)m_outputBuffer[1];
      pred.probBearish = (double)m_outputBuffer[2];
      
      m_lastProbBull = m_outputBuffer[0];
      m_lastProbNeu  = m_outputBuffer[1];
      m_lastProbBear = m_outputBuffer[2];

      if(pred.probBullish >= pred.probNeutral && pred.probBullish >= pred.probBearish)
      {
         pred.predictedClass = 0; // Bullish TP
         pred.confidence = pred.probBullish;
      }
      else if(pred.probBearish >= pred.probNeutral && pred.probBearish >= pred.probBullish)
      {
         pred.predictedClass = 2; // Bearish TP
         pred.confidence = pred.probBearish;
      }
      else
      {
         pred.predictedClass = 1; // Neutral
         pred.confidence = pred.probNeutral;
      }
      
      return true;
   }

   bool PredictConsensus(const float &features[], float &pBull, float &pNeu, float &pBear)
   {
      SModelPrediction pred;
      if(!Predict(features, pred))
         return false;
         
      pBull = (float)pred.probBullish;
      pNeu  = (float)pred.probNeutral;
      pBear = (float)pred.probBearish;
      return true;
   }
};
