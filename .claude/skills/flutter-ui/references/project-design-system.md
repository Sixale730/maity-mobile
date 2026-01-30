# Design System del Proyecto Maity

## Archivo fuente

El design system completo esta en `lib/utils/ui_guidelines.dart`. Siempre referir a este archivo como fuente de verdad.

## Reglas criticas

1. **NUNCA hardcodear colores** - Usar `AppColors.xxx`
2. **NUNCA hardcodear spacing** - Usar `AppStyles.spacingXX`
3. **NUNCA hardcodear radius** - Usar `AppStyles.radiusXX`
4. **NUNCA hardcodear text styles desde cero** - Usar `AppStyles.xxx` y `.copyWith()` si necesitas variantes
5. **NUNCA usar Material 3 `useMaterial3: true`** - El proyecto usa `useMaterial3: false`
6. **NUNCA cambiar el ThemeData global** sin permiso explicito del usuario

## Colores por contexto de uso

| Contexto | Color | Valor |
|----------|-------|-------|
| CTA principal | `AppColors.officialBlue` | #485DF4 |
| CTA hover/light | `AppColors.officialBlueLight` | #8B9DF7 |
| Fondo de pagina | `AppColors.backgroundPrimary` | #000000 |
| Fondo de card | `AppColors.backgroundSecondary` | #1F1F25 |
| Fondo de input | `AppColors.backgroundTertiary` | #35343B |
| Texto principal | `AppColors.textPrimary` | #FFFFFF |
| Texto secundario | `AppColors.textSecondary` | white 80% |
| Texto terciario | `AppColors.textTertiary` | white 60% |
| Error | `AppColors.error` | red.shade800 |
| Exito | `AppColors.success` | green.shade600 |

## Jerarquia de texto

| Estilo | Uso | Tamano |
|--------|-----|--------|
| `AppStyles.title` | Titulos de seccion, headers | 18px w600 |
| `AppStyles.subtitle` | Subtitulos, nombres de items | 16px w500 |
| `AppStyles.body` | Texto de contenido, parrafos | 15px h1.4 |
| `AppStyles.caption` | Info secundaria, timestamps | 14px |
| `AppStyles.small` | Metadata, badges | 12px |
| `AppStyles.label` | Labels de formulario, tabs | 12px w500 |

## Escala de spacing

```
4px  (XS)  - Gap minimo entre iconos y texto inline
8px  (S)   - Padding interno de chips, separacion vertical compacta
12px (M)   - Padding de contenido en cards pequenas
16px (L)   - Margen horizontal de pagina, separacion entre cards
24px (XL)  - Separacion entre secciones
32px (XXL) - Margen superior/inferior de pagina
```

## Anatomia de una pagina tipica

```
Scaffold (black bg)
  └── CustomScrollView
      ├── SliverAppBar (floating, black bg)
      │   └── Title + Actions
      ├── SliverPadding (spacingL horizontal)
      │   └── SliverList
      │       ├── SearchWidget (si aplica)
      │       ├── Filter chips (si aplica)
      │       ├── Content cards
      │       └── ...
      └── SliverToBoxAdapter
          └── Bottom spacing (spacingXXL)
```

## Patrones de estado

### Loading
```dart
if (provider.isLoading) {
  return _buildShimmer();
}
```
Usar `Shimmer.fromColors` con `baseColor: Colors.grey.shade800` y `highlightColor: Colors.grey.shade700`.

### Empty
```dart
if (provider.items.isEmpty) {
  return _buildEmptyState();
}
```
Icono 64px en `textTertiary` + titulo + subtitulo centrados.

### Error
```dart
if (provider.error != null) {
  return _buildErrorState(provider.error!, onRetry: provider.refresh);
}
```
Icono error + mensaje + boton retry.

### Content
El estado normal con la lista/grid de items.

## Settings sections

Las secciones de settings siguen este patron:

```dart
Container(
  margin: EdgeInsets.symmetric(horizontal: AppStyles.spacingL),
  decoration: BoxDecoration(
    color: Color(0xFF1C1C1E),
    borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
  ),
  child: Column(
    children: [
      _buildSettingItem(icon, title, subtitle, onTap),
      Divider(height: 1, color: Colors.grey.shade800),
      _buildSettingItem(icon, title, subtitle, onTap),
    ],
  ),
)
```

## Iconos

- Preferir `Icons.xxx_outlined` para estados normales
- Preferir `Icons.xxx` (filled) para estados activos/seleccionados
- Tamano default: 24px para acciones, 20px en listas, 16px inline
- Color default: `AppColors.textSecondary`
- Color activo: `AppColors.officialBlue`

## Bottom Navigation

```dart
BottomNavigationBar(
  type: BottomNavigationBarType.fixed,
  backgroundColor: AppColors.backgroundSecondary,
  selectedItemColor: AppColors.officialBlue,
  unselectedItemColor: AppColors.textTertiary,
  selectedFontSize: 12,
  unselectedFontSize: 12,
)
```
