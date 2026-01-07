# Google Sign In con Supabase - Setup y Debugging

## Requisitos

### Google Cloud Console
1. **Android OAuth Client** con:
   - Package name: `com.maity.app`
   - SHA-1 del debug keystore (ver comando abajo)

2. **Web OAuth Client** con:
   - Authorized redirect URI: `https://nhlrtflkxoojvhbyocet.supabase.co/auth/v1/callback`

### Supabase Dashboard
En Authentication > Providers > Google:
- Client ID: `410083914404-0eld8h1l6s722prioe4tka56tfsrs66m.apps.googleusercontent.com`
- Client Secret: (del Web OAuth Client)

## Obtener SHA-1 del Debug Keystore

```bash
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
```

El SHA-1 debe coincidir con el registrado en el Android OAuth Client de Google Cloud Console.

## Errores Comunes

### ApiException: 10 (DEVELOPER_ERROR)
**Causa:** SHA-1 no coincide con el registrado en Google Cloud Console.

**Solución:**
1. Verificar que `android/app/build.gradle` use el debug keystore:
```groovy
buildTypes {
    release {
        signingConfig signingConfigs.debug
        // ...
    }
    debug {
        // NO necesita signingConfig explícito
    }
}
```

2. NO usar signingConfigs personalizados a menos que sea necesario para producción.

### Unacceptable audience in id_token
**Causa:** El Web Client ID en el código no coincide con el configurado en Supabase.

**Solución:**
1. Verificar `.env`:
```
GOOGLE_CLIENT_ID=410083914404-0eld8h1l6s722prioe4tka56tfsrs66m.apps.googleusercontent.com
```

2. Regenerar archivo de environment:
```bash
flutter pub run build_runner build --delete-conflicting-outputs
```

3. Verificar que Supabase Dashboard tenga el mismo Web Client ID.

### Google Sign In modal no abre
**Causa:** Configuración de signing incorrecta.

**Solución:** Ver "ApiException: 10" arriba.

## Archivos Clave

| Archivo | Propósito |
|---------|-----------|
| `.env` | Variables de entorno (GOOGLE_CLIENT_ID) |
| `lib/env/prod_env.g.dart` | Archivo generado (regenerar si hay problemas) |
| `android/app/build.gradle` | Configuración de signing Android |
| `lib/services/supabase_auth_service.dart` | Implementación de Google Sign In |

## Checklist Nueva Máquina

1. [ ] Obtener SHA-1 del debug keystore local
2. [ ] Registrar SHA-1 en Google Cloud Console (Android OAuth Client)
3. [ ] Verificar `.env` tiene el Web Client ID correcto
4. [ ] Ejecutar `flutter pub run build_runner build --delete-conflicting-outputs`
5. [ ] Ejecutar `flutter clean && flutter run`
