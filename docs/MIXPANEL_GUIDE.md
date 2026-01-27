# Mixpanel - Guía de Uso

## Estado Actual

| Feature | Estado | Notas |
|---------|--------|-------|
| **Events** | ✅ Funcionando | Llegan correctamente al listener |
| **Users** | ✅ Funcionando | Perfiles identificados correctamente |
| **Replays** | ❌ No disponible | Limitación del Flutter SDK |

## ¿Qué es cada cosa en Mixpanel?

| Sección | Qué muestra | Dónde encontrar |
|---------|-------------|-----------------|
| **Events** | Acciones de usuarios (clicks, vistas, etc.) | Sidebar → Data → Events |
| **Users** | Perfiles de usuarios identificados | Sidebar → Data → Users |
| **Replays** | Videos de sesiones (NO disponible en Flutter) | N/A |

## Cómo ver tus datos en Mixpanel

### 1. Ver Events
1. Click en **Data** → **Events** en el sidebar izquierdo
2. O click en **"View Events in Lexicon"** en el dashboard
3. Verás lista de todos los eventos que tu app envía

### 2. Ver Users
1. Click en **Data** → **Users** en el sidebar izquierdo
2. O click en **"View All Users"** en el dashboard
3. Verás perfiles de usuarios que han usado la app

### 3. Crear Reportes
1. Click en **"Add a report"** en "Your Product"
2. O usa el **Starter Board** que ya tienes
3. Tipos de reportes:
   - **Insights**: Gráficas de eventos over time
   - **Funnels**: Conversión entre pasos
   - **Retention**: Usuarios que regresan

## Sobre Session Replays

**Session Replay NO está disponible para Flutter.** Es una limitación del SDK, no hay nada que configurar.

### Plataformas soportadas por Session Replay:
- Apps nativas Android/iOS
- React Native (Beta)
- Web

### Alternativas para debugging en Flutter:
- Usar eventos detallados para tracking de flujos
- Firebase Crashlytics para errores
- Logs del dispositivo

## Eventos implementados en la app

Ver `lib/utils/analytics/mixpanel.dart` para la lista completa de eventos.

### Métodos principales:
| Método | Descripción |
|--------|-------------|
| `track(event, properties)` | Envía evento personalizado |
| `identify()` | Identifica usuario |
| `setUserProperty(key, value)` | Define propiedad de usuario |
| `deviceConnected()` | Evento: dispositivo BLE conectado |
| `deviceDisconnected()` | Evento: dispositivo BLE desconectado |

## Testing

En la app: **Developer Settings** → **Debug & Diagnostics** → **Test Mixpanel**

Esto envía un evento de prueba para verificar la conexión con Mixpanel.

## Configuración

El token de Mixpanel se configura en `.env`:
```
MIXPANEL_PROJECT_TOKEN=<tu-token>
```

Solo se activa si el token está configurado. Ver `lib/env/env.dart` para variables de entorno.
