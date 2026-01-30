---
name: flutter-ui
description: Experto en Flutter UI/UX, Material Design 3, y el design system Maity
---

# Flutter UI Skill

Conocimiento de dominio para redisenar y mejorar interfaces en Flutter con Material Design 3, adaptado al design system del proyecto Maity.

## Design System del Proyecto

### Colores (AppColors)

```dart
// Acentos - USAR SIEMPRE ESTOS, nunca hardcodear
officialBlue: Color(0xFF485DF4)        // Accion principal, links, CTAs
officialBlueLight: Color(0xFF8B9DF7)   // Variante clara
officialBlueDark: Color(0xFF0D1A4A)    // Variante oscura

// Fondos
backgroundPrimary: Colors.black        // Fondo principal
backgroundSecondary: Color(0xFF1F1F25) // Cards, containers
backgroundTertiary: Color(0xFF35343B)  // Inputs, chips

// Texto
textPrimary: Colors.white
textSecondary: white 80% opacity
textTertiary: white 60% opacity

// Semanticos
error: Colors.red.shade800
success: Colors.green.shade600
```

### Spacing (AppStyles)

```
spacingXS:  4px   // Entre elementos minimos
spacingS:   8px   // Padding interno compacto
spacingM:  12px   // Padding estandar
spacingL:  16px   // Separacion entre secciones
spacingXL:  24px  // Margenes de pagina
spacingXXL: 32px  // Separacion mayor
```

### Radius (AppStyles)

```
radiusSmall:    6px   // Chips, badges
radiusMedium:   8px   // Inputs, botones
radiusLarge:   12px   // Cards, containers
radiusCircular: 100px // Avatares, pills
```

### Text Styles (AppStyles)

```dart
title:    fontSize 18, w600  // Titulos de seccion
subtitle: fontSize 16, w500  // Subtitulos
body:     fontSize 15, h1.4  // Texto principal
caption:  fontSize 14        // Texto secundario
small:    fontSize 12        // Metadata
label:    fontSize 12, w500  // Labels de formulario
```

### Decoraciones Pre-construidas

```dart
AppStyles.cardDecoration      // Card con shadow y radius 12
AppStyles.inputDecoration     // Input con fill y border
```

## Patrones de Widgets

### Pagina con Provider

```dart
class MyPage extends StatefulWidget {
  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final ScrollController _scrollController = ScrollController();

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return Consumer<MyProvider>(
      builder: (context, provider, child) {
        return CustomScrollView(
          controller: _scrollController,
          slivers: [
            // Content
          ],
        );
      },
    );
  }
}
```

### Card Estandar

```dart
Container(
  margin: EdgeInsets.symmetric(
    horizontal: AppStyles.spacingL,
    vertical: AppStyles.spacingS,
  ),
  decoration: AppStyles.cardDecoration,
  child: Padding(
    padding: EdgeInsets.all(AppStyles.spacingL),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Title', style: AppStyles.title),
        SizedBox(height: AppStyles.spacingS),
        Text('Content', style: AppStyles.body),
      ],
    ),
  ),
)
```

### Loading Skeleton (Shimmer)

```dart
Shimmer.fromColors(
  baseColor: Colors.grey.shade800,
  highlightColor: Colors.grey.shade700,
  child: Container(
    height: 80,
    decoration: BoxDecoration(
      color: Colors.grey.shade800,
      borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
    ),
  ),
)
```

### Dialog Platform-Aware

```dart
showDialog(
  context: context,
  builder: (context) => Platform.isIOS
    ? CupertinoAlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          CupertinoDialogAction(child: Text('Cancel'), onPressed: () => Navigator.pop(context)),
          CupertinoDialogAction(child: Text('OK'), onPressed: onConfirm),
        ],
      )
    : AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(child: Text('Cancel'), onPressed: () => Navigator.pop(context)),
          TextButton(child: Text('OK'), onPressed: onConfirm),
        ],
      ),
);
```

### Layout Adaptivo (Mobile/Desktop)

```dart
class MyWidget extends BaseAdaptiveWidget {
  @override
  Widget buildMobile(BuildContext context) {
    return SingleColumnLayout(...);
  }

  @override
  Widget buildDesktop(BuildContext context) {
    return TwoPaneLayout(...);
  }
}
```

Breakpoint: 1100px (< mobile, >= desktop)

### Bottom Sheet Modal

```dart
showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  builder: (context) => DraggableScrollableSheet(
    initialChildSize: 0.7,
    builder: (context, scrollController) => Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundSecondary,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppStyles.radiusLarge)),
      ),
      child: ListView(controller: scrollController, children: [...]),
    ),
  ),
);
```

## Principios UX

1. **Consistencia**: Usar SIEMPRE AppStyles y AppColors, nunca valores hardcodeados
2. **Feedback visual**: Shimmer para loading, SnackBar para acciones, dialogs para confirmaciones
3. **Touch targets**: Minimo 48x48 para elementos interactivos
4. **Jerarquia visual**: title > subtitle > body > caption > small
5. **Espaciado consistente**: Seguir la escala de spacing (4, 8, 12, 16, 24, 32)
6. **Dark theme**: Todo sobre fondo negro, contraste suficiente
7. **i18n**: Textos visibles siempre con AppLocalizations
8. **Animaciones sutiles**: Duracion 200-300ms, curves Curves.easeInOut
9. **Empty states**: Siempre mostrar estado vacio con icono + mensaje
10. **Error states**: Mostrar error con opcion de reintentar

## Navegacion

| Tab | Pagina | Provider |
|-----|--------|----------|
| 0 | ConversationsPage | ConversationProvider |
| 1 | ActionItemsPage | ActionItemsProvider |
| 2 | MemoriesPage | MemoriesProvider |
| 3 | UsagePage | UsageProvider |

Settings: `SettingsDrawer.show(context)` via bottom sheet modal.
Chat: Pagina independiente con navigation push.

## Snackbars

```dart
showSnackbar(context, 'Mensaje neutral');
showSnackbarError(context, 'Algo salio mal');
showSnackbarSuccess(context, 'Guardado exitosamente');
```

## Widgets Reutilizables Existentes

- `AnimatedLoadingButton` - Boton con loader animado
- `GradientButton` - Boton con borde gradiente
- `ConfirmationDialog` - Dialog platform-aware con checkbox opcional
- `ExpandableTextWidget` - Texto expandible con markdown
- `DeviceAnimationWidget` - Widget animado del wearable
- `ConversationBottomBar` - Barra inferior de conversacion
- `WaveformSection` - Waveform de audio con progreso
- `SearchWidget` - Barra de busqueda con filtros
- `RecoveryDialog` - Dialog de recuperacion de transcripcion
