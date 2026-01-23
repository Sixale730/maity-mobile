"""
Maity Backend API - FastAPI Application

Main entry point for Vercel serverless functions.
Processes conversations with OpenAI and stores in Firebase.
"""
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse

from .routers import (
    conversations_router,
    metrics_router,
    action_items_router,
    omi_router,
    voice_profiles_router,
    communication_router,
    messages_router,
    feedback_router,
    memories_router,
)

# Create FastAPI app
app = FastAPI(
    title="Maity API",
    description="Backend API for Maity - Conversation categorization and metrics",
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, specify your app's domain
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(conversations_router)
app.include_router(metrics_router)
app.include_router(action_items_router)
app.include_router(omi_router)
app.include_router(voice_profiles_router)
app.include_router(communication_router)
app.include_router(messages_router)
app.include_router(feedback_router)
app.include_router(memories_router)


@app.get("/")
async def root():
    """Health check endpoint"""
    return {
        "status": "ok",
        "service": "Maity API",
        "version": "1.0.0",
    }


@app.get("/health")
async def health():
    """Health check for monitoring"""
    return {"status": "healthy"}


@app.get("/privacy", response_class=HTMLResponse)
async def privacy_policy():
    """Privacy Policy page for Google Play Store"""
    return """
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Política de Privacidad - Maity</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 800px;
            margin: 0 auto;
            padding: 40px 20px;
            background: #f9f9f9;
        }
        h1 { color: #485DF4; margin-bottom: 10px; }
        h2 { color: #333; margin: 30px 0 15px; border-bottom: 2px solid #485DF4; padding-bottom: 5px; }
        h3 { margin: 20px 0 10px; }
        p { margin-bottom: 15px; }
        ul { margin: 10px 0 20px 20px; }
        li { margin-bottom: 8px; }
        .updated { color: #666; font-size: 14px; margin-bottom: 30px; }
        .contact { background: #485DF4; color: white; padding: 20px; border-radius: 8px; margin-top: 30px; }
        .contact a { color: white; }
        .logo { font-size: 48px; margin-bottom: 10px; }
    </style>
</head>
<body>
    <div class="logo">🎙️</div>
    <h1>Política de Privacidad de Maity</h1>
    <p class="updated">Última actualización: 23 de enero de 2026</p>

    <h2>1. Introducción</h2>
    <p>En Maity, tu privacidad es muy importante para nosotros. Esta política describe qué datos recopilamos, cómo los usamos y cómo los protegemos.</p>
    <p>Maity es una aplicación que se conecta a un dispositivo wearable para transcribir conversaciones y generar análisis con inteligencia artificial.</p>

    <h2>2. Datos que Recopilamos</h2>

    <h3>2.1 Información de Cuenta</h3>
    <ul>
        <li>Correo electrónico (a través de Google Sign-In)</li>
        <li>Nombre de perfil de Google</li>
    </ul>

    <h3>2.2 Datos de Conversaciones</h3>
    <ul>
        <li>Transcripciones de audio grabadas con tu consentimiento</li>
        <li>Resúmenes y análisis generados por IA</li>
        <li>Action items y eventos extraídos</li>
        <li>Memorias generadas automáticamente</li>
    </ul>

    <h3>2.3 Datos de Uso</h3>
    <ul>
        <li>Eventos de onboarding y configuración</li>
        <li>Interacciones con la aplicación (navegación, ajustes)</li>
        <li>Estado de conexión del dispositivo</li>
        <li>Métricas de uso (duración, palabras transcritas)</li>
    </ul>

    <h3>2.4 Perfil de Voz (Opcional)</h3>
    <ul>
        <li>Embedding de voz para identificación del hablante</li>
        <li>Este dato es opcional y puedes eliminarlo en cualquier momento</li>
    </ul>

    <h2>3. Cómo Usamos tus Datos</h2>
    <ul>
        <li><strong>Transcripción:</strong> Convertimos audio a texto usando servicios de terceros (Deepgram)</li>
        <li><strong>Análisis:</strong> Generamos resúmenes y action items usando OpenAI</li>
        <li><strong>Almacenamiento:</strong> Guardamos tus conversaciones de forma segura en Supabase</li>
        <li><strong>Mejora del servicio:</strong> Usamos métricas anónimas para mejorar la app</li>
    </ul>

    <h2>4. Servicios de Terceros</h2>
    <p>Utilizamos los siguientes servicios que procesan datos:</p>
    <ul>
        <li><strong>Google Sign-In:</strong> Autenticación</li>
        <li><strong>Supabase:</strong> Base de datos y autenticación</li>
        <li><strong>OpenAI:</strong> Análisis de conversaciones</li>
        <li><strong>Deepgram:</strong> Transcripción de audio</li>
    </ul>

    <h2>5. Seguridad de los Datos</h2>
    <ul>
        <li>Todos los datos se transmiten usando HTTPS/TLS</li>
        <li>Las conversaciones se almacenan con políticas de Row Level Security (RLS)</li>
        <li>Solo tú puedes acceder a tus propios datos</li>
        <li>No vendemos ni compartimos tus datos con terceros para publicidad</li>
    </ul>

    <h2>6. Retención de Datos</h2>
    <p>Conservamos tus datos mientras mantengas una cuenta activa. Puedes solicitar la eliminación de tus datos en cualquier momento contactándonos.</p>

    <h2>7. Tus Derechos</h2>
    <ul>
        <li><strong>Acceso:</strong> Puedes ver todos tus datos en la aplicación</li>
        <li><strong>Eliminación:</strong> Puedes eliminar conversaciones individuales o solicitar la eliminación total de tu cuenta</li>
        <li><strong>Exportación:</strong> Puedes solicitar una copia de tus datos</li>
        <li><strong>Opt-out:</strong> Puedes desactivar el tracking anónimo en ajustes</li>
    </ul>

    <h2>8. Menores de Edad</h2>
    <p>Maity no está dirigida a menores de 13 años. No recopilamos intencionalmente datos de niños.</p>

    <h2>9. Cambios a esta Política</h2>
    <p>Podemos actualizar esta política ocasionalmente. Te notificaremos de cambios significativos a través de la aplicación.</p>

    <h2>10. Contacto</h2>
    <div class="contact">
        <p>Si tienes preguntas sobre esta política de privacidad, contáctanos:</p>
        <p><strong>Email:</strong> <a href="mailto:julio.gonzalez@maity.com.mx">julio.gonzalez@maity.com.mx</a></p>
        <p><strong>Empresa:</strong> Maity</p>
        <p><strong>Ubicación:</strong> Ciudad de México, México</p>
    </div>
</body>
</html>
"""


@app.get("/delete-account", response_class=HTMLResponse)
async def delete_account():
    """Account deletion request page for Google Play Store"""
    return """
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Eliminar Cuenta - Maity</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 600px;
            margin: 0 auto;
            padding: 40px 20px;
            background: #f9f9f9;
        }
        h1 { color: #485DF4; margin-bottom: 10px; }
        h2 { color: #333; margin: 25px 0 15px; }
        p { margin-bottom: 15px; }
        ul { margin: 10px 0 20px 20px; }
        li { margin-bottom: 8px; }
        .logo { font-size: 48px; margin-bottom: 10px; }
        .warning { background: #fff3cd; border: 1px solid #ffc107; padding: 15px; border-radius: 8px; margin: 20px 0; }
        .warning-title { color: #856404; font-weight: bold; margin-bottom: 5px; }
        .form-group { margin-bottom: 20px; }
        label { display: block; margin-bottom: 5px; font-weight: 500; }
        input, textarea {
            width: 100%;
            padding: 12px;
            border: 1px solid #ddd;
            border-radius: 8px;
            font-size: 16px;
        }
        textarea { resize: vertical; min-height: 100px; }
        button {
            background: #dc3545;
            color: white;
            padding: 15px 30px;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            cursor: pointer;
            width: 100%;
        }
        button:hover { background: #c82333; }
        .contact { background: #485DF4; color: white; padding: 20px; border-radius: 8px; margin-top: 30px; }
        .contact a { color: white; }
        .success { display: none; background: #d4edda; border: 1px solid #28a745; padding: 20px; border-radius: 8px; text-align: center; }
        .success h2 { color: #155724; }
    </style>
</head>
<body>
    <div class="logo">🎙️</div>
    <h1>Solicitar Eliminación de Cuenta</h1>
    <p>Usa este formulario para solicitar la eliminación de tu cuenta de Maity y todos los datos asociados.</p>

    <div class="warning">
        <div class="warning-title">⚠️ Importante</div>
        <p>Al eliminar tu cuenta, se borrarán permanentemente:</p>
        <ul>
            <li>Tu perfil y datos de cuenta</li>
            <li>Todas tus conversaciones y transcripciones</li>
            <li>Tus memorias y action items</li>
            <li>Tu perfil de voz (si lo creaste)</li>
            <li>Historial de uso y métricas</li>
        </ul>
        <p><strong>Esta acción no se puede deshacer.</strong></p>
    </div>

    <div id="form-container">
        <h2>Formulario de Solicitud</h2>

        <form id="deleteForm">
            <div class="form-group">
                <label for="email">Correo electrónico de tu cuenta *</label>
                <input type="email" id="email" name="email" required placeholder="tu@email.com">
            </div>

            <div class="form-group">
                <label for="reason">Motivo de eliminación (opcional)</label>
                <textarea id="reason" name="reason" placeholder="Cuéntanos por qué deseas eliminar tu cuenta..."></textarea>
            </div>

            <div class="form-group">
                <label>
                    <input type="checkbox" id="confirm" required>
                    Entiendo que esta acción es permanente y todos mis datos serán eliminados.
                </label>
            </div>

            <button type="submit">Solicitar Eliminación de Cuenta</button>
        </form>
    </div>

    <div id="success" class="success">
        <h2>✅ Solicitud Enviada</h2>
        <p>Hemos recibido tu solicitud de eliminación de cuenta.</p>
        <p>Procesaremos tu solicitud en un plazo de <strong>7 días hábiles</strong>.</p>
        <p>Recibirás un correo de confirmación cuando se complete.</p>
    </div>

    <div class="contact">
        <p>¿Tienes preguntas? Contáctanos directamente:</p>
        <p><strong>Email:</strong> <a href="mailto:julio.gonzalez@maity.com.mx">julio.gonzalez@maity.com.mx</a></p>
    </div>

    <script>
        document.getElementById('deleteForm').addEventListener('submit', function(e) {
            e.preventDefault();
            const email = document.getElementById('email').value;
            const reason = document.getElementById('reason').value;

            // Send email request
            const subject = encodeURIComponent('Solicitud de eliminación de cuenta - Maity');
            const body = encodeURIComponent(
                'Solicitud de eliminación de cuenta\\n\\n' +
                'Email: ' + email + '\\n' +
                'Motivo: ' + (reason || 'No especificado') + '\\n\\n' +
                'Por favor eliminar mi cuenta y todos los datos asociados.'
            );

            window.location.href = 'mailto:julio.gonzalez@maity.com.mx?subject=' + subject + '&body=' + body;

            document.getElementById('form-container').style.display = 'none';
            document.getElementById('success').style.display = 'block';
        });
    </script>
</body>
</html>
"""


# Vercel requires the app to be exposed at module level
# The handler is automatically picked up by Vercel
