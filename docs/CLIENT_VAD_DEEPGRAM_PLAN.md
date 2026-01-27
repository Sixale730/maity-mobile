# Plan: VAD del Lado del Cliente para Optimizar Costos de Deepgram

## Resumen Ejecutivo

Actualmente, Maity envía **todo el audio** capturado a Deepgram de forma continua, incluyendo silencios y ruido ambiental. Esto genera costos innecesarios ya que Deepgram cobra por **minutos de audio procesado**.

**Objetivo**: Implementar Voice Activity Detection (VAD) en el cliente para enviar audio a Deepgram **solo cuando hay voz activa**, reduciendo significativamente los costos de transcripción.

**Ahorro estimado**: 40-70% de reducción en minutos facturados (dependiendo del caso de uso).

---

## Estado Actual

### Flujo de Audio Existente

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  BLE Device /   │────▶│  Flutter App     │────▶│  Deepgram API   │
│  Phone Mic      │     │  (todo el audio) │     │  (WebSocket)    │
└─────────────────┘     └──────────────────┘     └─────────────────┘
                              │
                              ▼
                        Costo: 100% del tiempo
                        de captura facturado
```

### Archivos Clave Involucrados

| Archivo | Responsabilidad |
|---------|-----------------|
| `lib/providers/capture_provider.dart` | Orquestación de captura, envío a WebSocket |
| `lib/services/sockets/pure_streaming_stt.dart` | WebSocket streaming a Deepgram |
| `lib/utils/audio/wav_bytes.dart` | Buffer de audio, manipulación de frames |
| `lib/utils/audio/audio_transcoder.dart` | Conversión de formatos (Opus → PCM) |

### Parámetros Deepgram Actuales

```dart
// lib/models/stt_provider.dart (líneas 370-386)
config['params'] = {
  'model': 'nova-3',
  'language': lang,
  'endpointing': '300',  // VAD server-side: 300ms silencio
  'encoding': 'linear16',
  'sample_rate': '16000',
  ...
};
```

**Nota**: El parámetro `endpointing` es VAD del **servidor** (Deepgram). Detecta fin de frase, pero el audio ya fue enviado y facturado.

---

## Propuesta: VAD del Lado del Cliente

### Arquitectura Propuesta

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  BLE Device /   │────▶│  VAD Local       │────▶│  Deepgram API   │
│  Phone Mic      │     │  (Flutter)       │     │  (WebSocket)    │
└─────────────────┘     └──────────────────┘     └─────────────────┘
                              │
                              ├─ Voz detectada → Enviar
                              └─ Silencio → Buffering/Pausar

                        Costo: Solo tiempo con voz
                        activa facturado (~30-60%)
```

### Opciones de Implementación VAD

#### Opción A: VAD Basado en Energía (RMS) - Recomendada para MVP

**Complejidad**: Baja
**Latencia**: Muy baja (~1-5ms)
**Precisión**: Media (80-90%)
**Dependencias**: Ninguna adicional

```dart
class EnergyVAD {
  static const double _speechThreshold = 0.015; // Calibrar según ruido ambiental
  static const int _frameDurationMs = 20;       // 20ms frames típico
  static const int _hangoverFrames = 15;        // ~300ms de "cola" tras voz

  int _silentFrames = 0;
  bool _isSpeaking = false;

  /// Calcula RMS (Root Mean Square) de una muestra de audio PCM16
  double _calculateRMS(List<int> samples) {
    if (samples.isEmpty) return 0;
    double sum = 0;
    for (var sample in samples) {
      sum += (sample / 32768.0) * (sample / 32768.0);
    }
    return sqrt(sum / samples.length);
  }

  /// Detecta si hay voz en el frame de audio
  /// Retorna true si debe enviarse a Deepgram
  bool processFrame(Uint8List audioFrame) {
    // Convertir bytes a samples PCM16
    List<int> samples = [];
    for (int i = 0; i < audioFrame.length - 1; i += 2) {
      int sample = audioFrame[i] | (audioFrame[i + 1] << 8);
      if (sample > 32767) sample -= 65536; // Signed
      samples.add(sample);
    }

    double rms = _calculateRMS(samples);

    if (rms > _speechThreshold) {
      _isSpeaking = true;
      _silentFrames = 0;
      return true;
    } else {
      _silentFrames++;
      if (_silentFrames <= _hangoverFrames) {
        return true; // Hangover: seguir enviando brevemente
      }
      _isSpeaking = false;
      return false;
    }
  }
}
```

**Pros**:
- Implementación simple, sin dependencias
- Latencia mínima
- Funciona bien en ambientes controlados

**Contras**:
- Sensible a ruido de fondo
- Requiere calibración por dispositivo/ambiente
- Puede confundir música/ruido con voz

---

#### Opción B: WebRTC VAD (via FFI)

**Complejidad**: Media
**Latencia**: Baja (~10-20ms)
**Precisión**: Alta (95%+)
**Dependencias**: Compilación nativa (C/C++)

Usar el VAD de WebRTC que es el estándar de la industria para detección de voz.

**Paquetes existentes**:
- `flutter_webrtc` - Ya incluye VAD pero orientado a video calls
- Wrapper nativo vía `ffi` sobre libwebrtc

```dart
// Conceptual - requiere binding nativo
class WebRtcVAD {
  final int aggressiveness; // 0-3 (3 = más agresivo filtrando)

  external bool isSpeech(Uint8List frame, int sampleRate);
}
```

**Pros**:
- Muy preciso, probado en producción masiva
- Robusto ante ruido
- Múltiples niveles de agresividad

**Contras**:
- Requiere compilación nativa para cada plataforma
- Mayor complejidad de mantenimiento
- Posibles issues con iOS App Store (binarios nativos)

---

#### Opción C: Silero VAD (ML-based)

**Complejidad**: Alta
**Latencia**: Media (~30-50ms)
**Precisión**: Muy alta (97%+)
**Dependencias**: ONNX Runtime o TensorFlow Lite

Modelo de ML ligero especializado en VAD, usado por empresas como Picovoice.

```dart
// Conceptual - requiere integración ONNX
class SileroVAD {
  late final OnnxModel _model;

  Future<void> init() async {
    _model = await OnnxModel.load('assets/models/silero_vad.onnx');
  }

  Future<double> getSpeechProbability(Uint8List frame) async {
    final input = _preprocessAudio(frame);
    final output = await _model.run(input);
    return output[0]; // 0.0 - 1.0
  }
}
```

**Pros**:
- Máxima precisión
- Robusto a todo tipo de ruido
- Modelo pequeño (~1MB)

**Contras**:
- Mayor consumo de CPU/batería
- Latencia adicional
- Complejidad de integración ONNX en Flutter

---

### Recomendación

**Fase 1 (MVP)**: Implementar **Opción A (Energy VAD)** con calibración automática.

**Fase 2 (Optimización)**: Migrar a **Opción C (Silero VAD)** para máxima precisión si los ahorros justifican la complejidad.

---

## Plan de Implementación Detallado

### Fase 1: VAD Basado en Energía (2-3 días)

#### 1.1 Crear Servicio VAD

**Nuevo archivo**: `lib/services/audio/client_vad_service.dart`

```dart
import 'dart:math';
import 'dart:typed_data';

enum VADState { silence, speaking, hangover }

class ClientVADService {
  // Configuración
  final double speechThreshold;
  final int hangoverMs;
  final int sampleRate;
  final int frameSizeMs;

  // Estado
  VADState _state = VADState.silence;
  int _hangoverFramesRemaining = 0;
  double _noiseFloor = 0.01;

  // Callbacks
  final void Function()? onSpeechStart;
  final void Function()? onSpeechEnd;

  ClientVADService({
    this.speechThreshold = 0.02,
    this.hangoverMs = 300,
    this.sampleRate = 16000,
    this.frameSizeMs = 20,
    this.onSpeechStart,
    this.onSpeechEnd,
  });

  int get _hangoverFrames => hangoverMs ~/ frameSizeMs;

  /// Pre-buffer para no perder inicio de frases (100ms)
  final List<Uint8List> _preBuffer = [];
  static const int _preBufferFrames = 5; // 100ms @ 20ms/frame

  /// Procesa un frame de audio y decide si enviarlo
  /// Retorna lista de frames a enviar (puede incluir pre-buffer)
  List<Uint8List> processFrame(Uint8List audioFrame) {
    double energy = _calculateEnergy(audioFrame);
    bool isSpeech = energy > (_noiseFloor * 3) && energy > speechThreshold;

    List<Uint8List> framesToSend = [];

    switch (_state) {
      case VADState.silence:
        // Mantener pre-buffer rolling
        _preBuffer.add(audioFrame);
        if (_preBuffer.length > _preBufferFrames) {
          _preBuffer.removeAt(0);
        }

        if (isSpeech) {
          _state = VADState.speaking;
          _hangoverFramesRemaining = _hangoverFrames;
          onSpeechStart?.call();

          // Enviar pre-buffer + frame actual
          framesToSend.addAll(_preBuffer);
          _preBuffer.clear();
        } else {
          // Actualizar noise floor adaptivamente
          _updateNoiseFloor(energy);
        }
        break;

      case VADState.speaking:
        framesToSend.add(audioFrame);

        if (!isSpeech) {
          _state = VADState.hangover;
          _hangoverFramesRemaining = _hangoverFrames;
        }
        break;

      case VADState.hangover:
        framesToSend.add(audioFrame);
        _hangoverFramesRemaining--;

        if (isSpeech) {
          _state = VADState.speaking;
        } else if (_hangoverFramesRemaining <= 0) {
          _state = VADState.silence;
          onSpeechEnd?.call();
        }
        break;
    }

    return framesToSend;
  }

  double _calculateEnergy(Uint8List frame) {
    if (frame.isEmpty) return 0;

    double sum = 0;
    int samples = 0;

    for (int i = 0; i < frame.length - 1; i += 2) {
      int sample = frame[i] | (frame[i + 1] << 8);
      if (sample > 32767) sample -= 65536;
      double normalized = sample / 32768.0;
      sum += normalized * normalized;
      samples++;
    }

    return samples > 0 ? sqrt(sum / samples) : 0;
  }

  void _updateNoiseFloor(double energy) {
    // Actualización exponencial del noise floor
    const alpha = 0.05;
    _noiseFloor = (_noiseFloor * (1 - alpha)) + (energy * alpha);
    _noiseFloor = _noiseFloor.clamp(0.005, 0.05);
  }

  void reset() {
    _state = VADState.silence;
    _hangoverFramesRemaining = 0;
    _preBuffer.clear();
  }

  VADState get state => _state;
  bool get isSpeaking => _state != VADState.silence;
}
```

#### 1.2 Integrar VAD en CaptureProvider

**Modificar**: `lib/providers/capture_provider.dart`

```dart
// Agregar import
import 'package:maity_mobile/services/audio/client_vad_service.dart';

class CaptureProvider extends ChangeNotifier {
  // Agregar campo
  ClientVADService? _clientVAD;
  bool _vadEnabled = true; // Configurable en settings

  // En initState o al iniciar captura
  void _initializeVAD() {
    _clientVAD = ClientVADService(
      speechThreshold: 0.02,
      hangoverMs: 300,
      onSpeechStart: () {
        debugPrint('[VAD] Speech started');
        // Reconectar WebSocket si estaba pausado
      },
      onSpeechEnd: () {
        debugPrint('[VAD] Speech ended');
        // Opcionalmente pausar WebSocket
      },
    );
  }

  // Modificar el método que envía audio (línea ~541-554)
  void _processAndSendAudio(Uint8List audioBytes) {
    if (!_vadEnabled || _clientVAD == null) {
      // Sin VAD: enviar todo
      _socket?.send(audioBytes);
      return;
    }

    // Con VAD: procesar y enviar solo si hay voz
    final framesToSend = _clientVAD!.processFrame(audioBytes);
    for (final frame in framesToSend) {
      _socket?.send(frame);
    }
  }
}
```

#### 1.3 Configuración en Settings

**Nuevo archivo**: `lib/pages/settings/vad_settings_dialog.dart`

```dart
class VADSettingsDialog extends StatefulWidget {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Voice Detection Settings'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            title: Text('Client-side VAD'),
            subtitle: Text('Only send audio when speech is detected'),
            value: SharedPreferencesUtil().vadEnabled,
            onChanged: (value) {
              SharedPreferencesUtil().setVadEnabled(value);
              setState(() {});
            },
          ),
          // Slider para threshold si es necesario
          ListTile(
            title: Text('Sensitivity'),
            subtitle: Slider(
              value: SharedPreferencesUtil().vadSensitivity,
              min: 0.0,
              max: 1.0,
              divisions: 10,
              onChanged: (value) {
                SharedPreferencesUtil().setVadSensitivity(value);
              },
            ),
          ),
        ],
      ),
    );
  }
}
```

#### 1.4 Persistencia de Configuración

**Modificar**: `lib/backend/preferences.dart`

```dart
// Agregar keys
static const String _vadEnabledKey = 'vadEnabled';
static const String _vadSensitivityKey = 'vadSensitivity';

// Agregar getters/setters
bool get vadEnabled => _preferences.getBool(_vadEnabledKey) ?? true;
Future<void> setVadEnabled(bool value) async {
  await _preferences.setBool(_vadEnabledKey, value);
}

double get vadSensitivity => _preferences.getDouble(_vadSensitivityKey) ?? 0.5;
Future<void> setVadSensitivity(double value) async {
  await _preferences.setDouble(_vadSensitivityKey, value);
}
```

---

### Fase 2: Optimizaciones Avanzadas (3-5 días)

#### 2.1 Manejo Inteligente de WebSocket

Actualmente el WebSocket a Deepgram está siempre conectado. Optimizaciones:

```dart
class SmartDeepgramSocket {
  Timer? _disconnectTimer;
  bool _isConnected = false;

  /// Conectar solo cuando hay voz
  void onSpeechStart() {
    _disconnectTimer?.cancel();
    if (!_isConnected) {
      _connect();
    }
  }

  /// Desconectar tras N segundos de silencio
  void onSpeechEnd() {
    _disconnectTimer = Timer(Duration(seconds: 10), () {
      if (!_isSpeaking) {
        _disconnect();
      }
    });
  }
}
```

**Beneficio**: Reducir conexiones WebSocket activas durante largos silencios.

#### 2.2 Métricas de Ahorro

Agregar tracking para medir el ahorro real:

```dart
class VADMetrics {
  int totalFrames = 0;
  int sentFrames = 0;

  void recordFrame(bool sent) {
    totalFrames++;
    if (sent) sentFrames++;
  }

  double get savingsPercentage {
    if (totalFrames == 0) return 0;
    return (1 - (sentFrames / totalFrames)) * 100;
  }

  String get summary =>
    'Sent $sentFrames of $totalFrames frames (${savingsPercentage.toStringAsFixed(1)}% saved)';
}
```

#### 2.3 Calibración Automática

```dart
class AdaptiveVAD {
  final List<double> _recentEnergies = [];
  static const int _calibrationWindow = 100; // ~2 segundos

  double get adaptiveThreshold {
    if (_recentEnergies.isEmpty) return 0.02;

    // Percentil 75 del noise floor + margen
    final sorted = List<double>.from(_recentEnergies)..sort();
    final p75 = sorted[(sorted.length * 0.75).floor()];
    return p75 * 2.5; // 2.5x sobre el ruido base
  }

  void addSample(double energy) {
    _recentEnergies.add(energy);
    if (_recentEnergies.length > _calibrationWindow) {
      _recentEnergies.removeAt(0);
    }
  }
}
```

---

### Fase 3: VAD con ML (Opcional, 5-7 días)

Si los ahorros de Fase 1 son insuficientes o hay muchos falsos positivos/negativos:

#### 3.1 Integrar Silero VAD

1. Exportar modelo a ONNX/TFLite
2. Agregar `onnxruntime` o `tflite_flutter` como dependencia
3. Implementar wrapper

```yaml
# pubspec.yaml
dependencies:
  onnxruntime: ^1.16.0
```

```dart
class SileroVADService {
  late final OrtSession _session;

  Future<void> initialize() async {
    final modelBytes = await rootBundle.load('assets/models/silero_vad.onnx');
    _session = await OrtSession.fromBuffer(modelBytes.buffer.asUint8List());
  }

  Future<bool> isSpeech(Uint8List audioFrame) async {
    // Preprocesar audio a formato esperado por modelo
    final input = Float32List.fromList(
      _convertPCM16ToFloat32(audioFrame)
    );

    final outputs = await _session.run({
      'input': OrtValue.tensor(input, [1, input.length])
    });

    final probability = outputs['output']!.toFloat32List()[0];
    return probability > 0.5;
  }
}
```

---

## Consideraciones Técnicas

### Latencia

| Componente | Latencia Agregada |
|------------|-------------------|
| VAD Energy-based | ~1-2ms |
| Pre-buffer (100ms) | +100ms inicial |
| Hangover (300ms) | +0ms (trailing) |
| **Total** | ~100-102ms adicional al inicio de frase |

**Aceptable**: La latencia de Deepgram es ~200-500ms, así que 100ms extra es marginal.

### Impacto en Transcripción

**Riesgos**:
1. **Cortar inicio de palabras**: Mitigado con pre-buffer de 100ms
2. **Cortar final de frases**: Mitigado con hangover de 300ms
3. **Palabras cortas perdidas**: Poco probable con threshold calibrado

**Testing recomendado**:
- Grabar conversaciones con/sin VAD
- Comparar transcripciones
- Medir WER (Word Error Rate) si hay ground truth

### Compatibilidad

| Fuente de Audio | Soporte VAD |
|-----------------|-------------|
| BLE Device (Opus) | ✅ Requiere decode previo |
| Phone Mic (PCM16) | ✅ Directo |
| System Audio (Desktop) | ✅ Directo |

Para Opus, el VAD debe aplicarse **después** de decodificar a PCM:

```dart
void processOpusFrame(Uint8List opusData) {
  final pcmData = _opusDecoder.decode(opusData);
  final framesToSend = _vad.processFrame(pcmData);
  // Re-encode a Opus si es necesario, o enviar PCM
}
```

---

## Estimación de Ahorro

### Escenarios de Uso

| Escenario | Tiempo Total | Voz Activa | Sin VAD | Con VAD | Ahorro |
|-----------|--------------|------------|---------|---------|--------|
| Reunión 1 hora | 60 min | ~30 min | 60 min | 33 min* | 45% |
| Conversación casual | 20 min | ~12 min | 20 min | 14 min* | 30% |
| Dictado continuo | 10 min | ~9 min | 10 min | 10 min* | ~10% |
| Llamada telefónica | 30 min | ~15 min | 30 min | 18 min* | 40% |

*Incluye hangover de 300ms tras cada segmento de voz

### Cálculo de Costo

**Pricing Deepgram Nova-3** (aproximado 2025):
- Pay-as-you-go: $0.0043/min
- Growth: $0.0036/min

**Ejemplo mensual** (100 horas de grabación):
- Sin VAD: 6000 min × $0.0043 = **$25.80**
- Con VAD (45% ahorro): 3300 min × $0.0043 = **$14.19**
- **Ahorro: $11.61/mes por usuario activo**

---

## Checklist de Implementación

### Fase 1: MVP Energy VAD
- [ ] Crear `ClientVADService` con detección por energía
- [ ] Agregar pre-buffer para no perder inicios de frases
- [ ] Implementar hangover para no cortar finales
- [ ] Integrar en `CaptureProvider._processAndSendAudio()`
- [ ] Agregar toggle en Settings (on/off)
- [ ] Agregar slider de sensibilidad
- [ ] Persistir configuración en SharedPreferences
- [ ] Testing con diferentes ambientes (silencioso, ruidoso)
- [ ] Comparar transcripciones con/sin VAD

### Fase 2: Optimizaciones
- [ ] Métricas de ahorro (frames enviados vs totales)
- [ ] Calibración automática de threshold
- [ ] Manejo inteligente de conexión WebSocket
- [ ] Dashboard de estadísticas de ahorro
- [ ] A/B testing con usuarios

### Fase 3: VAD ML (Opcional)
- [ ] Evaluar necesidad basado en métricas Fase 1
- [ ] Integrar ONNX Runtime
- [ ] Exportar/adaptar modelo Silero VAD
- [ ] Benchmark de CPU/batería
- [ ] Comparar precisión vs Energy VAD

---

## Riesgos y Mitigaciones

| Riesgo | Impacto | Mitigación |
|--------|---------|------------|
| Cortar palabras | Alto | Pre-buffer 100ms + testing extensivo |
| Falsos positivos (ruido) | Medio | Calibración adaptativa + threshold configurable |
| Falsos negativos (voz suave) | Alto | Sensibilidad ajustable + opción de desactivar |
| Latencia perceptible | Bajo | Pre-buffer compensa, hangover es trailing |
| Consumo batería (Fase 3) | Medio | Usar modelo ligero, procesar en chunks |

---

## Métricas de Éxito

1. **Reducción de costo**: ≥40% menos minutos facturados
2. **Calidad transcripción**: WER ≤ +5% vs sin VAD
3. **Latencia percibida**: No perceptible por usuario
4. **Adopción**: ≥80% usuarios mantienen VAD activado

---

## Referencias

- [Deepgram Pricing](https://deepgram.com/pricing)
- [Silero VAD](https://github.com/snakers4/silero-vad)
- [WebRTC VAD](https://webrtc.googlesource.com/src/+/refs/heads/main/common_audio/vad/)
- [Voice Activity Detection Wikipedia](https://en.wikipedia.org/wiki/Voice_activity_detection)
