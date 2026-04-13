# Maity Mobile - Setup de Desarrollo (macOS)

Guia paso a paso para configurar un nuevo equipo Mac para desarrollo de Maity Mobile.

## Prerequisitos

- macOS con Xcode instalado (App Store)
- Cuenta de Apple Developer (con acceso al team `8YLD233TA2`)
- Cable Lightning a USB **de datos** (no solo de carga — los cables genericos baratos muchas veces solo cargan)

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

> **Nota**: El proyecto usa Flutter 3.24.1 (`.fvmrc`). Para usar la misma version exacta, instala FVM:
> ```bash
> brew tap leoafarias/fvm
> brew install fvm
> fvm install 3.24.1
> fvm use 3.24.1
> # Despues usa `fvm flutter run` en lugar de `flutter run`
> ```
> Si usas la version de Homebrew (mas reciente), funciona pero genera cambios en `pubspec.lock` que no debes commitear.

## 2. Configurar Xcode

### 2.1 Agregar cuenta Apple Developer
1. Abre **Xcode → Settings (⌘,) → Accounts**
2. Clic en **+** → Add Apple ID
3. Inicia sesion con tu Apple ID del team de desarrollo

### 2.2 Instalar certificado intermedio de Apple (WWDR)
**Critico**: Sin este certificado, `security find-identity` reporta "0 valid identities" aunque el cert de desarrollo exista en el keychain.

```bash
curl -sO https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
security add-certificates AppleWWDRCAG3.cer
rm AppleWWDRCAG3.cer
```

Verificar:
```bash
security find-identity -v -p codesigning
# Debe mostrar: "Apple Development: Tu Nombre (ID)"
# Si muestra "0 valid identities", el cert intermedio no se instalo bien
```

### 2.3 Crear certificado de desarrollo
Cada Mac necesita su propio certificado de Apple Development (Apple permite hasta 3 por cuenta).

1. **Xcode → Settings → Accounts** → selecciona tu Apple ID → tu Team
2. **Manage Certificates** → clic en **+** → **Apple Development**

Verificar en **Acceso a Llaveros** (Keychain Access):
- Busca "Apple Development"
- El certificado debe poder **expandirse** y mostrar una llave privada debajo
- Si NO se expande: no tiene llave privada, fue descargado del portal pero creado en otra Mac. Borralo y crealo de nuevo con el paso anterior.
- Si dice "no fiable": doble clic → seccion **Confiar** → cambiar a **Confiar siempre**

> **Nota**: El cert de Distribution (para App Store/TestFlight) es compartido entre el equipo. Para equipos grandes se recomienda **Fastlane Match**.

### 2.4 Instalar iOS Platform
Si Xcode muestra "iOS X.X is not installed":

1. **Xcode → Settings (⌘,) → Components** (o Platforms)
2. Descarga **iOS**

### 2.5 Registrar dispositivo (iPhone)
1. Conecta el iPhone al Mac con cable de **datos**
2. En el iPhone: **Confiar en esta computadora** → ingresa codigo
3. En el iPhone: **Ajustes → Privacidad y seguridad → Modo de desarrollador** → activar (requiere reinicio)
4. Parear en Xcode: **Xcode → Window → Devices and Simulators** → selecciona el iPhone
   - Si aparece como "unpaired", haz clic y acepta en el iPhone
   - Si pide registrar el dispositivo en el portal, acepta
5. Crear provisioning profile: abre el workspace en Xcode:
   ```bash
   open ios/Runner.xcworkspace
   ```
   Selecciona **Runner** (proyecto) → target **Runner** → **Signing & Capabilities**:
   - Activa **Automatically manage signing**
   - Selecciona tu **Team**
   - Xcode creara el provisioning profile automaticamente con los capabilities requeridos (Associated Domains, Push Notifications, Sign In with Apple)

Verificar conexion USB:
```bash
system_profiler SPUSBDataType | grep -A5 iPhone
# Si no aparece, el cable no transmite datos
```

Verificar conexion wireless:
```bash
xcrun devicectl list devices
```

> **Nota**: El iPhone tambien puede conectarse por wireless (misma red WiFi), pero la instalacion es mas lenta.

## 3. Configurar el proyecto

### 3.1 Instalar dependencias
```bash
cd /ruta/al/proyecto/maity-mobile

# Dependencias Flutter
flutter pub get

# Dependencias iOS (CocoaPods) — genera Runner.xcworkspace
cd ios && pod install && cd ..
```

### 3.2 Variables de entorno
Copia `.env.example` o `.env.template` a `.env` (debe llamarse exactamente `.env`, no `.env.local`):

```bash
cp .env.template .env
# Edita .env con los valores reales
```

Variables requeridas:
```
OPENAI_API_KEY=...
DEEPGRAM_API_KEY=...
GOOGLE_CLIENT_ID=...
SUPABASE_URL=https://nhlrtflkxoojvhbyocet.supabase.co
SUPABASE_ANON_KEY=...
MIXPANEL_PROJECT_TOKEN=...
MAITY_BACKEND_URL=...
```

> **Importante**: Si el archivo no se llama exactamente `.env`, `envied` genera todos los valores como `null` y la app crashea al iniciar (Supabase no se inicializa).

### 3.3 Generar archivos de codigo
El proyecto usa code generation (envied, json_serializable, flutter_gen, pigeon).

```bash
# Generar modelos, env, assets
dart run build_runner build --delete-conflicting-outputs

# Generar Pigeon (Apple Watch bridge)
dart run pigeon --input lib/watch_interface.dart
```

**Verificar que el env se genero bien**:
```bash
grep "supabaseUrl" lib/env/prod_env.g.dart
# Debe mostrar la URL, NO 'null'
```

Si los valores salen `null` despues de crear/renombrar el `.env`:
```bash
# Limpiar cache y regenerar
dart run build_runner clean
rm lib/env/prod_env.g.dart lib/env/dev_env.g.dart
dart run build_runner build --delete-conflicting-outputs
```

### 3.4 GoogleService-Info.plist
El build script espera el plist por flavor:
```bash
mkdir -p ios/Config/Prod
cp ios/Runner/GoogleService-Info.plist ios/Config/Prod/GoogleService-Info.plist
```

## 4. Correr la app

### En iPhone (debug)
```bash
flutter run -d 'NOMBRE_IPHONE' --flavor prod
```

### En iPhone (release — mejor rendimiento, menos RAM)
```bash
flutter run -d 'NOMBRE_IPHONE' --flavor prod --release
```

> **Nota sobre release local**: Release-prod esta configurado con signing Manual (Apple Distribution) para App Store. Para correr release en dispositivo local, necesitas cambiar temporalmente a Automatic signing en `project.pbxproj` (seccion Release-prod): `CODE_SIGN_STYLE = Automatic`, `CODE_SIGN_IDENTITY = "Apple Development"`, `PROVISIONING_PROFILE_SPECIFIER = ""`. **No commitees estos cambios.**

### En macOS (desktop)
```bash
flutter run -d macos --flavor prod
```

### Desde Xcode
1. `open ios/Runner.xcworkspace`
2. Selecciona scheme **prod**, destino tu iPhone
3. **Product → Run (⌘R)**

## 5. Configurar git (nueva Mac)
```bash
git config --global user.name "Tu Nombre"
git config --global user.email "tu@email.com"
```

## Troubleshooting

### "No valid code signing certificates were found"
- Verifica que el certificado intermedio de Apple este instalado (paso 2.2)
- Verifica que tu cert de desarrollo existe: `security find-identity -v -p codesigning`
- Si el cert aparece en Acceso a Llaveros pero dice "no fiable", doble clic → **Confiar** → **Confiar siempre**

### "0 valid identities found" pero el cert esta en Keychain
Falta el certificado intermedio WWDR:
```bash
curl -sO https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
security add-certificates AppleWWDRCAG3.cer
rm AppleWWDRCAG3.cer
```

### "requires a provisioning profile with Associated Domains..."
Abre el workspace en Xcode, ve a Signing & Capabilities, activa "Automatically manage signing" con tu Team. Xcode creara el profile con los capabilities necesarios.

### "Command PhaseScriptExecution failed" / "Copy Google Plist file"
Falta `ios/Config/Prod/GoogleService-Info.plist`:
```bash
mkdir -p ios/Config/Prod
cp ios/Runner/GoogleService-Info.plist ios/Config/Prod/GoogleService-Info.plist
```

### "Waiting for iPhone to connect..." (se queda ahi)
- Verifica conexion USB: `system_profiler SPUSBDataType | grep -A5 iPhone`
- Si no aparece: el cable solo es de carga, usa otro cable
- La conexion wireless funciona pero es mas lenta

### iPhone aparece como "unpaired"
1. Xcode → Window → Devices and Simulators
2. Selecciona el iPhone → parear
3. En el iPhone acepta "Confiar en esta computadora"

### Supabase no se inicializa / app crashea al abrir
Los valores del `.env` no se generaron correctamente:
```bash
grep "supabaseUrl" lib/env/prod_env.g.dart
# Si dice 'null', regenera:
dart run build_runner clean
rm lib/env/prod_env.g.dart lib/env/dev_env.g.dart
dart run build_runner build --delete-conflicting-outputs
```
Causas comunes: el archivo se llama `.env.local` en vez de `.env`, o se genero el codigo antes de crear el `.env`.

### Archivos generados faltantes (`.g.dart`, `assets.gen.dart`)
```bash
dart run build_runner build --delete-conflicting-outputs
dart run pigeon --input lib/watch_interface.dart
```

### Crash por memoria al grabar (EXC_RESOURCE MEMORY)
El modelo Parakeet (~640MB) consume mucha RAM. En modo debug Flutter usa mas memoria.
- Usa `--release` para produccion
- iPhone 12 (4GB RAM) puede tener problemas en debug con el modelo cargado

### Lock files modificados sin querer
Si `pubspec.lock` o `Podfile.lock` cambiaron por usar una version diferente de Flutter:
```bash
git checkout -- pubspec.lock ios/Podfile.lock
```
Usa FVM para evitar esto.

### Google Sign-In
- iOS: No requiere SHA fingerprints (eso es solo Android). Usa el Client ID del `GoogleService-Info.plist` vinculado al Bundle ID.
- No se necesita configuracion adicional al cambiar de Mac o certificado.

## Resumen de comandos (orden completo)

```bash
# 1. Instalar herramientas
brew install --cask flutter
brew install cocoapods

# 2. Certificado intermedio Apple
curl -sO https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
security add-certificates AppleWWDRCAG3.cer
rm AppleWWDRCAG3.cer

# 3. Crear cert de desarrollo en Xcode (manual, ver paso 2.3)

# 4. Dependencias
cd /ruta/al/proyecto/maity-mobile
flutter pub get
cd ios && pod install && cd ..

# 5. Variables de entorno
cp .env.template .env
# Editar .env con valores reales

# 6. Code generation
dart run build_runner clean
dart run build_runner build --delete-conflicting-outputs
dart run pigeon --input lib/watch_interface.dart

# 7. GoogleService-Info.plist
mkdir -p ios/Config/Prod
cp ios/Runner/GoogleService-Info.plist ios/Config/Prod/GoogleService-Info.plist

# 8. Correr
flutter run -d 'NOMBRE_IPHONE' --flavor prod

# 9. Git config
git config --global user.name "Tu Nombre"
git config --global user.email "tu@email.com"
```

## Notas

- **Certificados por Mac**: Cada Mac genera su propio cert de Apple Development. Es normal y esperado.
- **Flavors**: El proyecto tiene 2 flavors: `dev` y `prod`. Para desarrollo normal usa `prod`.
- **Signing**: Debug usa Automatic signing. Release-prod usa Manual signing con "Apple Distribution" (para App Store/TestFlight via CI o Mac con cert de distribucion).
- **No commitear**: cambios en `project.pbxproj` de signing (Automatic/Manual), ni lock files modificados por version diferente de Flutter.
