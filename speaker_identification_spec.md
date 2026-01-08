# Implementación de Speaker Identification con Voice Embeddings

## Contexto del Proyecto

Estoy desarrollando una app móvil (Flutter) basada en el repositorio de Omi (BasedHardware/omi) con mi propio backend. Actualmente uso **Deepgram** para transcripción con diarización, pero el reconocimiento del speaker principal no es preciso - identifica al usuario por base de datos en lugar de por huella de voz.

**Problema actual:** La diarización de Deepgram no distingue bien al usuario principal de otros speakers en la conversación.

**Objetivo:** Implementar un sistema de voice profiles basado en embeddings para identificar al usuario por su huella de voz única.

---

## Arquitectura Recomendada

### Stack Tecnológico

| Componente | Herramienta | Propósito |
|------------|-------------|-----------|
| STT + Diarización base | Deepgram (ya implementado) | Transcripción y separar speakers |
| Voice Embeddings | pyannote + SpeechBrain ECAPA-TDNN | Crear huella de voz |
| Almacenamiento | PostgreSQL + pgvector | Guardar embeddings para búsqueda por similaridad |
| Comparación | Cosine similarity | Identificar quién habla |

### Flujo de Datos

```
                    ┌─→ Deepgram API ──────────────────────┐
                    │   (transcription + diarize=true)     │
Audio ─→ Splitter ──┤                                      ├─→ Fusion → Named Transcript
                    │                                      │
                    └─→ Speaker Embedding Service ─────────┘
                        (ECAPA-TDNN por segmento)
```

---

## Implementación Backend (Python)

### 1. Dependencias Requeridas

```bash
pip install pyannote.audio speechbrain torch torchaudio
pip install psycopg2-binary pgvector
pip install scipy numpy
```

### 2. Servicio de Voice Embeddings

```python
# voice_profile_service.py

import torch
import torchaudio
from pyannote.audio.pipelines.speaker_verification import PretrainedSpeakerEmbedding
from pyannote.audio import Audio
from scipy.spatial.distance import cosine
import numpy as np

class VoiceProfileService:
    def __init__(self):
        # Modelo ECAPA-TDNN de SpeechBrain (192 dimensiones)
        # Este es el mismo que usa pyannote internamente
        self.device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        self.embedding_model = PretrainedSpeakerEmbedding(
            "speechbrain/spkrec-ecapa-voxceleb",
            device=self.device
        )
        self.audio_processor = Audio(sample_rate=16000, mono=True)
        
    def extract_embedding(self, audio_path: str) -> np.ndarray:
        """
        Extrae el embedding de voz de un archivo de audio.
        Retorna un vector de 192 dimensiones.
        """
        waveform, sample_rate = self.audio_processor(audio_path)
        
        # El modelo espera: (batch, channels, samples)
        if waveform.dim() == 2:
            waveform = waveform.unsqueeze(0)
        
        with torch.no_grad():
            embedding = self.embedding_model(waveform)
        
        return embedding.cpu().numpy().flatten()
    
    def extract_embedding_from_bytes(self, audio_bytes: bytes, sample_rate: int = 16000) -> np.ndarray:
        """
        Extrae embedding directamente de bytes de audio (para streaming).
        """
        # Convertir bytes a tensor
        audio_tensor = torch.frombuffer(audio_bytes, dtype=torch.int16).float()
        audio_tensor = audio_tensor / 32768.0  # Normalizar a [-1, 1]
        
        # Resample si es necesario
        if sample_rate != 16000:
            resampler = torchaudio.transforms.Resample(sample_rate, 16000)
            audio_tensor = resampler(audio_tensor)
        
        waveform = audio_tensor.unsqueeze(0).unsqueeze(0)  # (1, 1, samples)
        
        with torch.no_grad():
            embedding = self.embedding_model(waveform.to(self.device))
        
        return embedding.cpu().numpy().flatten()
    
    def calculate_similarity(self, embedding1: np.ndarray, embedding2: np.ndarray) -> float:
        """
        Calcula la similitud coseno entre dos embeddings.
        Retorna valor entre -1 y 1 (mayor = más similar).
        """
        return 1 - cosine(embedding1, embedding2)
    
    def is_same_speaker(self, embedding1: np.ndarray, embedding2: np.ndarray, threshold: float = 0.75) -> bool:
        """
        Determina si dos embeddings corresponden al mismo speaker.
        Threshold recomendado: 0.75-0.85
        """
        similarity = self.calculate_similarity(embedding1, embedding2)
        return similarity > threshold
```

### 3. Gestor de Perfiles de Voz

```python
# voice_profile_manager.py

import numpy as np
from typing import Optional, Dict, List, Tuple
from voice_profile_service import VoiceProfileService

class VoiceProfileManager:
    def __init__(self, db_connection):
        self.voice_service = VoiceProfileService()
        self.db = db_connection
        self.similarity_threshold = 0.75
        
    async def enroll_user(self, user_id: str, audio_files: List[str]) -> dict:
        """
        Enrollment: Registra la voz del usuario.
        Requiere 30+ segundos de audio total para un perfil robusto.
        
        Args:
            user_id: ID del usuario
            audio_files: Lista de paths a archivos de audio (WAV, 16kHz)
        
        Returns:
            dict con status y calidad del enrollment
        """
        embeddings = []
        total_duration = 0
        
        for audio_path in audio_files:
            try:
                embedding = self.voice_service.extract_embedding(audio_path)
                embeddings.append(embedding)
                # Calcular duración (asumiendo 16kHz)
                # total_duration += get_audio_duration(audio_path)
            except Exception as e:
                print(f"Error procesando {audio_path}: {e}")
                continue
        
        if len(embeddings) == 0:
            return {"status": "error", "message": "No se pudo procesar ningún audio"}
        
        # Promediar embeddings para perfil más robusto
        average_embedding = np.mean(embeddings, axis=0)
        
        # Normalizar (L2)
        average_embedding = average_embedding / np.linalg.norm(average_embedding)
        
        # Guardar en base de datos
        await self._save_profile(user_id, average_embedding)
        
        return {
            "status": "success",
            "user_id": user_id,
            "samples_processed": len(embeddings),
            "embedding_dimensions": len(average_embedding)
        }
    
    async def identify_speaker(self, audio_segment: bytes, sample_rate: int = 16000) -> Tuple[Optional[str], float]:
        """
        Identifica qué usuario registrado está hablando.
        
        Args:
            audio_segment: Bytes del segmento de audio
            sample_rate: Sample rate del audio
        
        Returns:
            Tuple de (user_id o None, similarity_score)
        """
        # Extraer embedding del segmento
        test_embedding = self.voice_service.extract_embedding_from_bytes(audio_segment, sample_rate)
        
        # Buscar en perfiles almacenados
        profiles = await self._get_all_profiles()
        
        best_match = None
        best_score = -1
        
        for user_id, stored_embedding in profiles.items():
            similarity = self.voice_service.calculate_similarity(test_embedding, stored_embedding)
            if similarity > best_score:
                best_score = similarity
                best_match = user_id
        
        if best_score >= self.similarity_threshold:
            return best_match, best_score
        else:
            return None, best_score
    
    async def verify_speaker(self, user_id: str, audio_segment: bytes) -> Tuple[bool, float]:
        """
        Verifica si un segmento de audio corresponde a un usuario específico.
        
        Returns:
            Tuple de (es_el_usuario, similarity_score)
        """
        test_embedding = self.voice_service.extract_embedding_from_bytes(audio_segment)
        stored_embedding = await self._get_profile(user_id)
        
        if stored_embedding is None:
            return False, 0.0
        
        similarity = self.voice_service.calculate_similarity(test_embedding, stored_embedding)
        return similarity >= self.similarity_threshold, similarity
    
    async def _save_profile(self, user_id: str, embedding: np.ndarray):
        """Guarda el perfil de voz en PostgreSQL con pgvector."""
        query = """
            INSERT INTO voice_profiles (user_id, embedding, created_at)
            VALUES ($1, $2, NOW())
            ON CONFLICT (user_id) 
            DO UPDATE SET embedding = $2, updated_at = NOW()
        """
        await self.db.execute(query, user_id, embedding.tolist())
    
    async def _get_profile(self, user_id: str) -> Optional[np.ndarray]:
        """Obtiene el perfil de voz de un usuario."""
        query = "SELECT embedding FROM voice_profiles WHERE user_id = $1"
        result = await self.db.fetchone(query, user_id)
        if result:
            return np.array(result['embedding'])
        return None
    
    async def _get_all_profiles(self) -> Dict[str, np.ndarray]:
        """Obtiene todos los perfiles de voz."""
        query = "SELECT user_id, embedding FROM voice_profiles WHERE is_active = true"
        results = await self.db.fetch(query)
        return {row['user_id']: np.array(row['embedding']) for row in results}
```

### 4. Esquema de Base de Datos (PostgreSQL + pgvector)

```sql
-- Habilitar extensión pgvector
CREATE EXTENSION IF NOT EXISTS vector;

-- Tabla de perfiles de voz
CREATE TABLE voice_profiles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID UNIQUE NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    embedding vector(192),  -- ECAPA-TDNN genera 192 dimensiones
    enrollment_duration_sec FLOAT,
    quality_score FLOAT,
    samples_count INTEGER DEFAULT 1,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Índice para búsqueda por similaridad coseno
CREATE INDEX idx_voice_profiles_embedding 
ON voice_profiles 
USING ivfflat (embedding vector_cosine_ops) 
WITH (lists = 100);

-- Función para buscar el speaker más similar
CREATE OR REPLACE FUNCTION find_similar_speaker(
    query_embedding vector(192), 
    threshold FLOAT DEFAULT 0.75
)
RETURNS TABLE(user_id UUID, similarity FLOAT) AS $$
    SELECT 
        user_id, 
        1 - (embedding <=> query_embedding) as similarity
    FROM voice_profiles
    WHERE is_active = true
    AND 1 - (embedding <=> query_embedding) > threshold
    ORDER BY embedding <=> query_embedding
    LIMIT 1;
$$ LANGUAGE SQL;
```

### 5. Integración con Deepgram (Post-procesamiento)

```python
# deepgram_integration.py

import asyncio
from typing import List, Dict, Any
from voice_profile_manager import VoiceProfileManager

class TranscriptionWithSpeakerID:
    def __init__(self, deepgram_client, voice_manager: VoiceProfileManager):
        self.deepgram = deepgram_client
        self.voice_manager = voice_manager
        self.min_segment_duration = 2.0  # Segundos mínimos para identificar
        
    async def process_audio(self, audio_bytes: bytes, user_id: str) -> Dict[str, Any]:
        """
        Procesa audio con Deepgram y añade identificación de speaker por voz.
        """
        # 1. Transcribir con Deepgram
        deepgram_result = await self.deepgram.transcribe(
            audio_bytes,
            options={
                "model": "nova-2",
                "diarize": True,
                "utterances": True,
                "punctuate": True,
                "smart_format": True
            }
        )
        
        # 2. Extraer segmentos por speaker de Deepgram
        speaker_segments = self._group_segments_by_speaker(deepgram_result)
        
        # 3. Identificar cada speaker usando voice embeddings
        identity_map = {}
        
        for speaker_id, segments in speaker_segments.items():
            # Combinar audio de todos los segmentos del speaker
            combined_audio = self._extract_audio_segments(audio_bytes, segments)
            
            # Solo identificar si hay suficiente audio
            total_duration = sum(s['end'] - s['start'] for s in segments)
            
            if total_duration >= self.min_segment_duration:
                identified_user, confidence = await self.voice_manager.identify_speaker(combined_audio)
                
                if identified_user:
                    identity_map[speaker_id] = {
                        "user_id": identified_user,
                        "confidence": confidence,
                        "is_primary_user": identified_user == user_id
                    }
                else:
                    identity_map[speaker_id] = {
                        "user_id": None,
                        "confidence": confidence,
                        "is_primary_user": False,
                        "label": f"Speaker_{speaker_id}"
                    }
        
        # 4. Enriquecer resultado con identidades
        enriched_result = self._enrich_transcript(deepgram_result, identity_map)
        
        return enriched_result
    
    def _group_segments_by_speaker(self, deepgram_result) -> Dict[int, List[Dict]]:
        """Agrupa los segmentos por speaker_id de Deepgram."""
        speaker_segments = {}
        
        for utterance in deepgram_result.get('utterances', []):
            speaker = utterance.get('speaker', 0)
            if speaker not in speaker_segments:
                speaker_segments[speaker] = []
            speaker_segments[speaker].append({
                'start': utterance['start'],
                'end': utterance['end'],
                'text': utterance['transcript']
            })
        
        return speaker_segments
    
    def _extract_audio_segments(self, audio_bytes: bytes, segments: List[Dict]) -> bytes:
        """
        Extrae y concatena los segmentos de audio especificados.
        Asume audio PCM 16-bit, 16kHz, mono.
        """
        sample_rate = 16000
        bytes_per_sample = 2
        
        extracted = bytearray()
        
        for segment in segments:
            start_byte = int(segment['start'] * sample_rate * bytes_per_sample)
            end_byte = int(segment['end'] * sample_rate * bytes_per_sample)
            extracted.extend(audio_bytes[start_byte:end_byte])
        
        return bytes(extracted)
    
    def _enrich_transcript(self, deepgram_result: Dict, identity_map: Dict) -> Dict:
        """Añade información de identidad al transcript."""
        for utterance in deepgram_result.get('utterances', []):
            speaker_id = utterance.get('speaker', 0)
            identity = identity_map.get(speaker_id, {})
            
            utterance['identified_user'] = identity.get('user_id')
            utterance['speaker_confidence'] = identity.get('confidence', 0)
            utterance['is_primary_user'] = identity.get('is_primary_user', False)
            
            if identity.get('user_id'):
                utterance['speaker_label'] = f"User_{identity['user_id'][:8]}"
            else:
                utterance['speaker_label'] = identity.get('label', f"Speaker_{speaker_id}")
        
        return deepgram_result
```

---

## API Endpoints Recomendados

```python
# routes/voice_profiles.py

from fastapi import APIRouter, UploadFile, File, HTTPException
from typing import List

router = APIRouter(prefix="/api/v1/voice-profiles", tags=["voice-profiles"])

@router.post("/enroll")
async def enroll_voice_profile(
    user_id: str,
    audio_files: List[UploadFile] = File(...)
):
    """
    Enrollment: Registra el perfil de voz del usuario.
    
    Requisitos:
    - Audio WAV, 16kHz, mono
    - Mínimo 30 segundos de habla total
    - Idealmente 3-5 grabaciones diferentes
    """
    # Guardar archivos temporalmente
    temp_paths = []
    for audio in audio_files:
        # ... guardar y validar audio
        pass
    
    result = await voice_manager.enroll_user(user_id, temp_paths)
    return result

@router.post("/verify")
async def verify_speaker(
    user_id: str,
    audio: UploadFile = File(...)
):
    """
    Verifica si el audio corresponde al usuario especificado.
    """
    audio_bytes = await audio.read()
    is_verified, confidence = await voice_manager.verify_speaker(user_id, audio_bytes)
    
    return {
        "is_verified": is_verified,
        "confidence": confidence,
        "threshold": voice_manager.similarity_threshold
    }

@router.post("/identify")
async def identify_speaker(
    audio: UploadFile = File(...)
):
    """
    Identifica qué usuario registrado está hablando.
    """
    audio_bytes = await audio.read()
    user_id, confidence = await voice_manager.identify_speaker(audio_bytes)
    
    return {
        "identified_user": user_id,
        "confidence": confidence,
        "is_known_speaker": user_id is not None
    }
```

---

## Flujo de Enrollment en la App (Flutter)

```dart
// lib/services/voice_enrollment_service.dart

import 'package:record/record.dart';
import 'dart:io';

class VoiceEnrollmentService {
  final _recorder = AudioRecorder();
  final List<String> _recordedSamples = [];
  
  /// Inicia el proceso de enrollment
  /// Requiere grabar 3-5 muestras de ~10 segundos cada una
  Future<EnrollmentResult> startEnrollment(String userId) async {
    if (!await _recorder.hasPermission()) {
      return EnrollmentResult.error("Permiso de micrófono denegado");
    }
    
    _recordedSamples.clear();
    return EnrollmentResult.ready();
  }
  
  /// Graba una muestra de voz
  Future<void> recordSample(int sampleIndex) async {
    final path = '${Directory.systemTemp.path}/voice_sample_$sampleIndex.wav';
    
    await _recorder.start(
      RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
      ),
      path: path,
    );
    
    // Grabar por 10 segundos
    await Future.delayed(Duration(seconds: 10));
    await _recorder.stop();
    
    _recordedSamples.add(path);
  }
  
  /// Envía las muestras al backend para enrollment
  Future<EnrollmentResult> completeEnrollment(String userId) async {
    if (_recordedSamples.length < 3) {
      return EnrollmentResult.error("Se necesitan al menos 3 muestras");
    }
    
    // Enviar al backend
    final response = await apiClient.enrollVoiceProfile(
      userId: userId,
      audioFiles: _recordedSamples.map((p) => File(p)).toList(),
    );
    
    // Limpiar archivos temporales
    for (final path in _recordedSamples) {
      File(path).deleteSync();
    }
    _recordedSamples.clear();
    
    return EnrollmentResult.fromResponse(response);
  }
}
```

---

## Consideraciones Importantes

### Requisitos de Audio para Enrollment
- **Sample rate:** 16 kHz
- **Formato:** WAV o PCM 16-bit, mono
- **Duración mínima:** 30 segundos totales (idealmente 45-60)
- **Calidad:** Sin ruido de fondo excesivo
- **Contenido:** Frases variadas fonéticamente

### Thresholds de Similaridad
| Threshold | Uso |
|-----------|-----|
| 0.65-0.70 | Muy permisivo (más falsos positivos) |
| 0.75-0.80 | Balanceado (recomendado) |
| 0.85-0.90 | Estricto (más falsos negativos) |

### Rendimiento
- **CPU:** ~500ms por embedding (aceptable para batch)
- **GPU:** ~50ms por embedding (recomendado para real-time)
- **Embedding size:** 192 dimensiones (ECAPA-TDNN)
- **Mínimo audio para identificación:** 2-3 segundos de habla

### Seguridad y Privacidad
- Los embeddings NO son reversibles al audio original
- Almacenar solo embeddings, nunca audio raw
- Requiere consentimiento explícito del usuario (GDPR)
- Cifrar embeddings en reposo (AES-256)

---

## Recursos Adicionales

- **pyannote.audio:** https://github.com/pyannote/pyannote-audio
- **SpeechBrain ECAPA-TDNN:** https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb
- **pgvector:** https://github.com/pgvector/pgvector
- **Omi Backend Reference:** https://github.com/BasedHardware/omi/blob/main/backend/utils/stt/speech_profile.py
