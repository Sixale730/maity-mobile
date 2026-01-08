"""
Voice Embeddings Service for Modal.com
Extracts speaker embeddings using ECAPA-TDNN (192 dimensions)
Deploy: modal deploy voice_embeddings.py
"""
import modal
from typing import List, Optional

# Modal app configuration
app = modal.App("maity-voice-embeddings")

# Image with ML dependencies
image = modal.Image.debian_slim(python_version="3.11").pip_install(
    "speechbrain>=1.0.0",
    "torch>=2.0.0",
    "torchaudio>=2.0.0",
    "scipy>=1.11.0",
    "numpy>=1.24.0",
    "fastapi",
)


@app.cls(gpu="T4", image=image, container_idle_timeout=300)
class VoiceEmbeddingService:
    """Service class for voice embedding extraction using ECAPA-TDNN."""

    @modal.enter()
    def load_model(self):
        """Load ECAPA-TDNN model on container start."""
        from speechbrain.inference.speaker import EncoderClassifier
        import torch

        print("[VoiceEmbedding] Loading ECAPA-TDNN model...")
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.model = EncoderClassifier.from_hparams(
            source="speechbrain/spkrec-ecapa-voxceleb",
            savedir="/tmp/model_cache",
            run_opts={"device": self.device}
        )
        print(f"[VoiceEmbedding] Model loaded on {self.device}")

    @modal.method()
    def extract_embedding(self, audio_bytes: bytes, sample_rate: int = 16000) -> List[float]:
        """
        Extract 192-dimensional embedding from audio bytes.

        Args:
            audio_bytes: Raw PCM audio (16-bit signed, mono)
            sample_rate: Sample rate of the audio (default 16kHz)

        Returns:
            List of 192 floats representing the speaker embedding
        """
        import torch
        import torchaudio
        import numpy as np

        # Convert bytes to tensor (assuming 16-bit signed PCM)
        audio = torch.frombuffer(audio_bytes, dtype=torch.int16).float()
        audio = audio / 32768.0  # Normalize to [-1, 1]

        # Resample if needed
        if sample_rate != 16000:
            resampler = torchaudio.transforms.Resample(
                orig_freq=sample_rate,
                new_freq=16000
            )
            audio = resampler(audio)

        # Ensure minimum length (0.5 seconds at 16kHz)
        min_samples = 8000
        if len(audio) < min_samples:
            # Pad with zeros
            padding = torch.zeros(min_samples - len(audio))
            audio = torch.cat([audio, padding])

        # Extract embedding (model expects batch dimension)
        with torch.no_grad():
            embedding = self.model.encode_batch(audio.unsqueeze(0))

        return embedding.cpu().numpy().flatten().tolist()

    @modal.method()
    def extract_embeddings_batch(
        self,
        audio_segments: List[bytes],
        sample_rate: int = 16000
    ) -> List[List[float]]:
        """Extract embeddings for multiple audio segments."""
        return [
            self.extract_embedding(seg, sample_rate)
            for seg in audio_segments
        ]

    @modal.method()
    def calculate_similarity(
        self,
        embedding1: List[float],
        embedding2: List[float]
    ) -> float:
        """
        Calculate cosine similarity between two embeddings.

        Returns:
            Similarity score between -1 and 1 (higher = more similar)
        """
        from scipy.spatial.distance import cosine
        return 1.0 - cosine(embedding1, embedding2)

    @modal.method()
    def verify_speaker(
        self,
        audio_bytes: bytes,
        reference_embedding: List[float],
        sample_rate: int = 16000,
        threshold: float = 0.75
    ) -> dict:
        """
        Verify if audio belongs to the reference speaker.

        Returns:
            dict with 'is_match', 'similarity', and 'embedding'
        """
        test_embedding = self.extract_embedding(audio_bytes, sample_rate)
        similarity = self.calculate_similarity(reference_embedding, test_embedding)

        return {
            "is_match": similarity >= threshold,
            "similarity": similarity,
            "embedding": test_embedding,
        }


# HTTP Endpoints for Vercel backend to call

@app.function(image=image, gpu="T4", timeout=120)
@modal.web_endpoint(method="POST")
def extract_embedding_http(data: dict) -> dict:
    """
    HTTP endpoint to extract voice embedding from audio.

    Request body:
    {
        "audio_base64": "base64_encoded_audio",
        "sample_rate": 16000  // optional, default 16000
    }

    Response:
    {
        "embedding": [...192 floats...],
        "dimensions": 192
    }
    """
    import base64

    audio_base64 = data.get("audio_base64")
    sample_rate = data.get("sample_rate", 16000)

    if not audio_base64:
        return {"error": "audio_base64 is required"}

    try:
        audio_bytes = base64.b64decode(audio_base64)
    except Exception as e:
        return {"error": f"Invalid base64: {str(e)}"}

    # Minimum audio length check (~0.5 seconds at 16kHz, 16-bit)
    min_bytes = 16000  # 0.5s * 16000Hz * 2 bytes
    if len(audio_bytes) < min_bytes:
        return {"error": f"Audio too short. Minimum {min_bytes} bytes required."}

    service = VoiceEmbeddingService()
    embedding = service.extract_embedding.remote(audio_bytes, sample_rate)

    return {
        "embedding": embedding,
        "dimensions": len(embedding),
    }


@app.function(image=image, gpu="T4", timeout=180)
@modal.web_endpoint(method="POST")
def verify_speakers_http(data: dict) -> dict:
    """
    HTTP endpoint to verify multiple speakers against a user's voice profile.

    Request body:
    {
        "user_embedding": [...192 floats...],
        "speaker_segments": {
            "0": "base64_audio_speaker_0",
            "1": "base64_audio_speaker_1"
        },
        "sample_rate": 16000,  // optional
        "threshold": 0.75      // optional
    }

    Response:
    {
        "results": {
            "0": {"is_user": true, "similarity": 0.85},
            "1": {"is_user": false, "similarity": 0.32}
        }
    }
    """
    import base64

    user_embedding = data.get("user_embedding")
    speaker_segments = data.get("speaker_segments", {})
    sample_rate = data.get("sample_rate", 16000)
    threshold = data.get("threshold", 0.75)

    if not user_embedding:
        return {"error": "user_embedding is required"}

    if not speaker_segments:
        return {"error": "speaker_segments is required"}

    if len(user_embedding) != 192:
        return {"error": f"user_embedding must have 192 dimensions, got {len(user_embedding)}"}

    service = VoiceEmbeddingService()
    results = {}

    for speaker_id, audio_base64 in speaker_segments.items():
        try:
            audio_bytes = base64.b64decode(audio_base64)

            # Skip if audio too short
            if len(audio_bytes) < 16000:
                results[speaker_id] = {
                    "is_user": False,
                    "similarity": 0.0,
                    "error": "Audio too short"
                }
                continue

            verification = service.verify_speaker.remote(
                audio_bytes=audio_bytes,
                reference_embedding=user_embedding,
                sample_rate=sample_rate,
                threshold=threshold
            )

            results[speaker_id] = {
                "is_user": verification["is_match"],
                "similarity": verification["similarity"],
            }

        except Exception as e:
            results[speaker_id] = {
                "is_user": False,
                "similarity": 0.0,
                "error": str(e)
            }

    return {"results": results}


@app.function(image=image, gpu="T4", timeout=60)
@modal.web_endpoint(method="GET")
def health() -> dict:
    """Health check endpoint."""
    import torch
    return {
        "status": "healthy",
        "gpu_available": torch.cuda.is_available(),
        "model": "speechbrain/spkrec-ecapa-voxceleb",
        "embedding_dimensions": 192,
    }


# Local testing
if __name__ == "__main__":
    print("To deploy: modal deploy voice_embeddings.py")
    print("To test locally: modal run voice_embeddings.py")
