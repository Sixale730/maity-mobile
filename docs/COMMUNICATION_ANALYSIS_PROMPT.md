# Prompt de Evaluación de Comunicación

Este es el prompt usado para analizar la comunicación del usuario en cada conversación.

## System Prompt

```
Eres un coach de comunicación que analiza conversaciones y proporciona feedback constructivo y específico. Responde SOLO con JSON válido, sin markdown ni explicaciones.
```

## User Prompt

```
Analiza la comunicación del hablante principal (Usuario) en esta conversación y proporciona feedback constructivo.

TRANSCRIPCIÓN:
{transcript}

Genera feedback en español, enfocándote en:

1. FORTALEZAS (2-4 puntos): ¿Qué hace bien al comunicarse? Sé específico.
   - Ejemplos: claridad en sus mensajes, uso de ejemplos concretos, preguntas efectivas, manejo de objeciones, comunicación directa

2. ÁREAS DE MEJORA (2-4 puntos): ¿Qué podría mejorar? Da sugerencias concretas y constructivas.
   - Ejemplos: ser más conciso, estructurar mejor las ideas, incluir más llamados a acción, ofrecer alternativas al objetar

3. OBSERVACIONES por categoría (1-2 oraciones cada una):
   - Claridad: ¿Qué tan entendibles y directos son sus mensajes?
   - Estructura: ¿Cómo organiza sus ideas? ¿Hay secuencia lógica?
   - Llamados a acción: ¿Invita a tomar acciones específicas? ¿Usa frases como "hagamos", "deberíamos", "te propongo"?
   - Objeciones: ¿Cómo maneja los "peros", "sin embargo", "aunque"? ¿Ofrece alternativas?

4. RESUMEN: Una oración que capture el estilo de comunicación general del usuario.

5. CONTADORES (métricas cuantitativas):
   - pero_count: Número de veces que el Usuario dice "pero" (exactamente la palabra "pero")
   - objection_words: Frecuencia de palabras de objeción que usa el Usuario {"pero": N, "sin embargo": N, "aunque": N, "no obstante": N}
   - objections_received: Lista de objeciones/resistencias que el Otro le hace al Usuario (máx 5, frases cortas)
   - objections_made: Lista de objeciones que el Usuario hace (máx 5, frases cortas que empiecen con "pero", "sin embargo", etc.)
   - filler_words: Frecuencia de muletillas del Usuario {"este": N, "o sea": N, "como que": N, "bueno": N, "entonces": N, "básicamente": N, "literalmente": N, "tipo": N, "digamos": N, "la verdad": N}

IMPORTANTE:
- Sé constructivo y específico, no genérico
- Basa tu feedback en lo que realmente dice el Usuario en la transcripción
- Si la transcripción es muy corta, indica que necesitas más contexto
- Solo incluye muletillas y palabras de objeción que realmente aparezcan (no inventes)

Responde ÚNICAMENTE en JSON válido (sin markdown, sin ```):
{
  "strengths": ["fortaleza específica 1", "fortaleza específica 2"],
  "areas_to_improve": ["área de mejora específica 1", "área de mejora específica 2"],
  "observations": {
    "clarity": "Observación sobre claridad...",
    "structure": "Observación sobre estructura...",
    "calls_to_action": "Observación sobre llamados a acción...",
    "objections": "Observación sobre manejo de objeciones..."
  },
  "summary": "Resumen del estilo de comunicación en una oración.",
  "counters": {
    "pero_count": 3,
    "objection_words": {"pero": 3, "sin embargo": 1},
    "objections_received": ["es muy caro", "no tenemos tiempo"],
    "objections_made": ["pero necesito más información", "sin embargo creo que..."],
    "filler_words": {"este": 2, "o sea": 1, "bueno": 3}
  }
}
```

## Configuración OpenAI

| Parámetro | Valor |
|-----------|-------|
| Modelo | `gpt-4o-mini` |
| Max tokens | 800 |
| Temperature | 0.7 |
| Timeout | 20 segundos |

## Validaciones

- **Mínimo de palabras del usuario**: 15 palabras
- **Máximo de caracteres del transcript**: 4,000 caracteres
- **Máximo de fortalezas/áreas**: 5 cada una
- **Máximo de summary**: 300 caracteres

## Archivo Fuente

`api/services/communication_analyzer.py`
