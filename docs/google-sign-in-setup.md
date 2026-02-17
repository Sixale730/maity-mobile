# Google Sign-In con Supabase - Guia Completa

## Resumen

Google Sign-In en Android valida que el SHA-1 de la app este registrado como Android OAuth Client en Google Cloud Console. Dependiendo del entorno (debug, release manual, Play Store), la app se firma con una llave distinta, por lo que se necesitan **3 Android OAuth clients** registrados.

## Los 3 SHAs

| # | Entorno | SHA-1 | Cuando se usa |
|---|---------|-------|---------------|
| 1 | **Debug** | `23:AE:6A:8D:42:C0:E2:31:1E:25:3D:75:57:4D:17:3B:E2:DE:76:BB` | `flutter run`, builds de debug |
| 2 | **Upload (release)** | `12:59:75:70:A2:3A:9B:19:52:DC:23:28:0E:D7:9C:6A:BF:94:CF:A7` | APK/AAB firmado localmente, instalacion manual |
| 3 | **Google Play App Signing** | `EE:16:5D:F9:E5:66:9F:BB:4B:D8:2D:A7:58:B2:94:24:D3:CA:7F:EE` | App descargada desde Google Play (Google re-firma) |

### Como obtener cada SHA

**Debug** (keystore compartido en el repo):
```bash
keytool -list -v -keystore android/debug-shared.keystore -storepass android
```

**Upload (release)**:
```bash
keytool -list -v -keystore android/app/upload-keystore.jks
```
(Se te pedira la contrasena del keystore)

**Google Play App Signing**:
1. Ir a [Google Play Console](https://play.google.com/console)
2. Seleccionar la app Maity
3. Setup → App signing
4. Copiar SHA-1 de "App signing key certificate"

> **Nota**: Google Play re-firma toda app subida con su propia llave. Por eso el SHA de Play Store es diferente al de upload.

## Registro en Google Cloud Console

Cada Android OAuth Client solo admite **1 SHA-1**, asi que se necesitan **3 clientes** (uno por entorno).

### Pasos

1. Ir a [Google Cloud Console](https://console.cloud.google.com/) → seleccionar el proyecto correcto
2. APIs & Services → Credentials
3. Para **cada SHA**, crear un "OAuth 2.0 Client ID" tipo **Android**:

| Cliente | Package name | SHA-1 |
|---------|-------------|-------|
| Maity Android (Debug) | `com.maity.app` | `23:AE:6A:8D:42:C0:E2:31:1E:25:3D:75:57:4D:17:3B:E2:DE:76:BB` |
| Maity Android (Upload) | `com.maity.app` | `12:59:75:70:A2:3A:9B:19:52:DC:23:28:0E:D7:9C:6A:BF:94:CF:A7` |
| Maity Android (Play Store) | `com.maity.app` | `EE:16:5D:F9:E5:66:9F:BB:4B:D8:2D:A7:58:B2:94:24:D3:CA:7F:EE` |

### Web OAuth Client

El Web OAuth Client ya existe y no necesita cambios:
- Client ID: `452559089881-sa4cbrni1i9bh31vrp63l5hdks0jtecf.apps.googleusercontent.com`
- Este es el que va en `serverClientId` / `.env` (`GOOGLE_CLIENT_ID`)
- Authorized redirect URI: `https://nhlrtflkxoojvhbyocet.supabase.co/auth/v1/callback`

### Supabase Dashboard

En Authentication → Providers → Google:
- Client ID: (el Web Client ID de arriba)
- Client Secret: (del Web OAuth Client)

## Keystores

### Debug keystore (`android/debug-shared.keystore`)

Keystore compartido que vive en el repositorio. **Todos los desarrolladores usan el mismo**, lo que evita tener que registrar un SHA diferente por maquina.

Referenciado en `android/app/build.gradle`:
```groovy
signingConfigs {
    debug {
        storeFile file('../debug-shared.keystore')
        storePassword 'android'
        keyAlias 'androiddebugkey'
        keyPassword 'android'
    }
}
```

### Upload keystore (`android/app/upload-keystore.jks`)

Keystore para firmar releases que se suben a Google Play. **No se sube al repo** (esta en `.gitignore`). Se comparte de manera segura entre desarrolladores autorizados.

## Checklist por escenario

### Nueva maquina de desarrollo

- [ ] Clonar el repo (el debug keystore ya esta incluido)
- [ ] Verificar `.env` tiene `GOOGLE_CLIENT_ID` correcto
- [ ] `flutter clean && flutter run`
- [ ] Google Sign-In deberia funcionar sin pasos adicionales

> Ya no necesitas registrar tu SHA de debug en Google Cloud Console. El keystore compartido `debug-shared.keystore` tiene un SHA fijo registrado para todos.

### Primera subida a Google Play

- [ ] Subir el AAB a Google Play Console
- [ ] Ir a Setup → App signing → copiar SHA-1 de "App signing key certificate"
- [ ] Registrar ese SHA como Android OAuth Client en Google Cloud Console (ver pasos arriba)

### Nuevo upload keystore

Si se regenera el upload keystore:
- [ ] Obtener el nuevo SHA-1: `keytool -list -v -keystore android/app/upload-keystore.jks`
- [ ] Actualizar el Android OAuth Client "Maity Android (Upload)" en Google Cloud Console con el nuevo SHA
- [ ] Actualizar la tabla de SHAs en este documento

## Troubleshooting

### ApiException: 10 (DEVELOPER_ERROR)

**Causa**: El SHA-1 de la app no coincide con ningun Android OAuth Client registrado en Google Cloud Console.

**Diagnostico**:
1. Determinar en que entorno falla:
   - `flutter run` → falta SHA de Debug
   - APK release instalado manualmente → falta SHA de Upload
   - Descarga de Play Store → falta SHA de Play App Signing
2. Verificar que el SHA correspondiente este registrado con package `com.maity.app`

**Solucion por entorno**:

| Entorno | Verificar |
|---------|-----------|
| Debug | Que `build.gradle` use `debug-shared.keystore`, no `~/.android/debug.keystore` |
| Upload | Que exista Android OAuth Client con SHA del upload keystore |
| Play Store | Que exista Android OAuth Client con SHA de Google Play App Signing |

### Unacceptable audience in id_token

**Causa**: El Web Client ID en el codigo no coincide con el configurado en Supabase.

**Solucion**:
1. Verificar `.env`:
   ```
   GOOGLE_CLIENT_ID=452559089881-sa4cbrni1i9bh31vrp63l5hdks0jtecf.apps.googleusercontent.com
   ```
2. Verificar que Supabase Dashboard tenga el mismo Web Client ID
3. Rebuild: `flutter clean && flutter run`

### Google Sign-In modal no abre

**Causa**: Configuracion de signing incorrecta (SHA no registrado).

**Solucion**: Ver "ApiException: 10" arriba.

### Funciona en debug pero no en Play Store

**Causa**: Solo esta registrado el SHA de debug. Google Play re-firma la app con su propia llave.

**Solucion**: Registrar el SHA de Google Play App Signing como Android OAuth Client (ver seccion "Registro en Google Cloud Console").

### Funciona en debug pero no en release (APK manual)

**Causa**: El APK release se firma con el upload keystore, cuyo SHA es diferente al de debug.

**Solucion**: Registrar el SHA del upload keystore como Android OAuth Client.

## Archivos clave

| Archivo | Proposito |
|---------|-----------|
| `.env` | `GOOGLE_CLIENT_ID` (Web Client ID) |
| `android/debug-shared.keystore` | Keystore debug compartido (en repo) |
| `android/app/upload-keystore.jks` | Keystore release/upload (no en repo) |
| `android/app/build.gradle` | Configuracion de signing Android |
| `lib/services/supabase_auth_service.dart` | Implementacion de Google Sign-In |
