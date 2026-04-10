# Maity Mobile - Setup de Desarrollo (macOS)

Guia paso a paso para configurar un nuevo equipo Mac para desarrollo de Maity Mobile.

## Prerequisitos

- macOS con Xcode instalado (App Store)
- Cuenta de Apple Developer (con acceso al team `8YLD233TA2`)
- Cable Lightning a USB **de datos** (no solo de carga)

## 1. Instalar herramientas

```bash
# Flutter (via Homebrew)
brew install --cask flutter

# CocoaPods (dependencias iOS)
brew install cocoapods
```

Verificar:
```bash
flutter --version
pod --version
flutter doctor
```

> **Nota**: El proyecto usa Flutter 3.24.1 (`.fvmrc`), pero versiones mas recientes funcionan.

## 2. Configurar Xcode

### 2.1 Agregar cuenta Apple Developer
1. Abre **Xcode → Settings (⌘,) → Accounts**
2. Clic en **+** → Add Apple ID
3. Inicia sesion con tu Apple ID del team de desarrollo

### 2.2 Instalar certificado intermedio de Apple
Sin este certificado, los certificados de desarrollo no seran reconocidos como validos.

```bash
curl -sO https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
security add-certificates AppleWWDRCAG3.cer
rm AppleWWDRCAG3.cer
```

Verificar que funciono:
```bash
security find-identity -v -p codesigning
# Debe mostrar: "Apple Development: Tu Nombre (ID)"
```

### 2.3 Crear certificado de desarrollo
Cada Mac necesita su propio certificado de Apple Development.

1. **Xcode → Settings → Accounts** → selecciona tu Apple ID → tu Team
2. **Manage Certificates** → clic en **+** → **Apple Development**

> **Nota**: Cada dev tiene su propio cert de desarrollo. El cert de Distribution (App Store) es compartido.

### 2.4 Instalar iOS Platform (si es necesario)
Si Xcode muestra "iOS X.X is not installed":

1. **Xcode → Settings (⌘,) → Components** (o Platforms)
2. Descarga **iOS**

### 2.5 Registrar dispositivo
La primera vez que conectes un iPhone nuevo:

1. Conecta el iPhone al Mac
2. En el iPhone: **Confiar en esta computadora** → ingresa codigo
3. En el iPhone: **Ajustes → Privacidad y seguridad → Modo de desarrollador** → activar (requiere reinicio)
4. **Xcode → Window → Devices and Simulators** → selecciona el iPhone → si pide registrar, acepta
5. Abre el workspace en Xcode y compila una vez para que cree el provisioning profile automaticamente:
   ```bash
   open ios/Runner.xcworkspace
   ```
   Selecciona Runner → target Runner → **Signing & Capabilities** → verifica Team y "Automatically manage signing"

## 3. Configurar el proyecto

### 3.1 Instalar dependencias
```bash
cd /ruta/al/proyecto/maity-mobile

# Dependencias Flutter
flutter pub get

# Dependencias iOS (CocoaPods)
cd ios && pod install && cd ..
```

### 3.2 Generar archivos de codigo
El proyecto usa code generation (envied, json_serializable, flutter_gen, pigeon):

```bash
# Generar modelos, env, assets
dart run build_runner build --delete-conflicting-outputs

# Generar Pigeon (Apple Watch bridge)
dart run pigeon --input lib/watch_interface.dart
```

### 3.3 Variables de entorno
Asegurate de tener el archivo `.env` en la raiz del proyecto con:
```
MIXPANEL_PROJECT_TOKEN=...
DEEPGRAM_API_KEY=...
GOOGLE_CLIENT_ID=...
SUPABASE_URL=...
SUPABASE_ANON_KEY=...
```

## 4. Correr la app

### En iPhone (debug)
```bash
flutter run -d 'NOMBRE_IPHONE' --flavor prod
```

### En macOS (desktop)
```bash
flutter run -d macos --flavor prod
```

### Desde Xcode
1. `open ios/Runner.xcworkspace`
2. Selecciona scheme **prod**, destino tu iPhone
3. **Product → Run (⌘R)**

## Troubleshooting

### "No valid code signing certificates were found"
- Verifica que el certificado intermedio de Apple este instalado (paso 2.2)
- Verifica que tu cert de desarrollo existe: `security find-identity -v -p codesigning`
- Si el cert aparece en Keychain Access pero dice "not trusted", abre **Acceso a Llaveros** → doble clic en el cert → **Confiar** → "Confiar siempre"

### "0 valid identities found" pero el cert esta en Keychain
Falta el certificado intermedio. Corre:
```bash
curl -sO https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
security add-certificates AppleWWDRCAG3.cer
rm AppleWWDRCAG3.cer
```

### "requires a provisioning profile with Associated Domains..."
Xcode necesita crear el provisioning profile. Abre el workspace en Xcode, ve a Signing & Capabilities, y asegurate de que "Automatically manage signing" este activo con tu Team seleccionado.

### "Waiting for iPhone to connect..." (se queda ahi)
- El iPhone no esta conectado por USB (cable solo de carga) — usa un cable de datos
- O esta conectado solo por wireless, que es mas lento

### iPhone aparece como "unpaired"
1. Xcode → Window → Devices and Simulators
2. Selecciona el iPhone
3. En el iPhone acepta "Confiar en esta computadora"

### Archivos generados faltantes (`.g.dart`, `assets.gen.dart`)
```bash
dart run build_runner build --delete-conflicting-outputs
dart run pigeon --input lib/watch_interface.dart
```

### Google Sign-In
- iOS: No requiere SHA fingerprints (eso es solo Android). Usa el Client ID del `GoogleService-Info.plist` vinculado al Bundle ID.
- No se necesita configuracion adicional al cambiar de Mac o certificado.

## Notas

- **Certificados por Mac**: Cada Mac genera su propio cert de Apple Development. Es normal y esperado (Apple permite hasta 3).
- **Flavors**: El proyecto tiene 2 flavors: `dev` y `prod`. Para desarrollo normal usa `prod`.
- **Signing**: Debug usa Automatic signing. Release-prod usa Manual signing con "Apple Distribution" (para App Store/TestFlight).
