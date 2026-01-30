# Material Design 3 - Patrones para Flutter

## ColorScheme.fromSeed

```dart
// Material 3 genera paleta completa desde un seed color
ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: Color(0xFF485DF4),
    brightness: Brightness.dark,
  ),
)
```

En este proyecto NO usamos `fromSeed` - usamos `ColorScheme.dark()` con colores manuales. Respetar eso.

## Componentes Material 3

### Elevated Card (M3)
```dart
Card(
  elevation: 1,
  color: AppColors.backgroundSecondary,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppStyles.radiusLarge),
  ),
  child: Padding(
    padding: EdgeInsets.all(AppStyles.spacingL),
    child: content,
  ),
)
```

### Filled Button (M3)
```dart
FilledButton(
  onPressed: () {},
  style: FilledButton.styleFrom(
    backgroundColor: AppColors.officialBlue,
    foregroundColor: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppStyles.radiusMedium),
    ),
  ),
  child: Text('Action'),
)
```

### Outlined Button (M3)
```dart
OutlinedButton(
  onPressed: () {},
  style: OutlinedButton.styleFrom(
    foregroundColor: AppColors.officialBlue,
    side: BorderSide(color: AppColors.officialBlue),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppStyles.radiusMedium),
    ),
  ),
  child: Text('Secondary'),
)
```

### Text Button (M3)
```dart
TextButton(
  onPressed: () {},
  style: TextButton.styleFrom(
    foregroundColor: AppColors.officialBlue,
  ),
  child: Text('Tertiary'),
)
```

### Search Bar (M3)
```dart
SearchBar(
  hintText: 'Search...',
  backgroundColor: WidgetStatePropertyAll(AppColors.backgroundTertiary),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppStyles.radiusMedium),
    ),
  ),
  leading: Icon(Icons.search, color: AppColors.textTertiary),
  onChanged: (query) {},
)
```

### Chips (M3)
```dart
// Filter Chip
FilterChip(
  label: Text('Category'),
  selected: isSelected,
  onSelected: (val) {},
  selectedColor: AppColors.officialBlue.withValues(alpha: 0.2),
  checkmarkColor: AppColors.officialBlue,
  backgroundColor: AppColors.backgroundTertiary,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppStyles.radiusSmall),
  ),
)

// Input Chip
InputChip(
  label: Text('Tag'),
  onDeleted: () {},
  deleteIconColor: AppColors.textTertiary,
  backgroundColor: AppColors.backgroundTertiary,
)
```

### SegmentedButton (M3)
```dart
SegmentedButton<ViewMode>(
  segments: [
    ButtonSegment(value: ViewMode.list, icon: Icon(Icons.list)),
    ButtonSegment(value: ViewMode.grid, icon: Icon(Icons.grid_view)),
  ],
  selected: {currentMode},
  onSelectionChanged: (newSelection) {},
  style: ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      return states.contains(WidgetState.selected)
        ? AppColors.officialBlue
        : AppColors.backgroundTertiary;
    }),
  ),
)
```

### ListTile (M3 style)
```dart
ListTile(
  leading: CircleAvatar(
    backgroundColor: AppColors.officialBlue.withValues(alpha: 0.15),
    child: Icon(Icons.person, color: AppColors.officialBlue),
  ),
  title: Text('Title', style: AppStyles.subtitle),
  subtitle: Text('Description', style: AppStyles.caption.copyWith(
    color: AppColors.textTertiary,
  )),
  trailing: Icon(Icons.chevron_right, color: AppColors.textTertiary),
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppStyles.radiusMedium),
  ),
)
```

### Bottom Sheet (M3)
```dart
showModalBottomSheet(
  context: context,
  showDragHandle: true,
  backgroundColor: AppColors.backgroundSecondary,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(
      top: Radius.circular(AppStyles.radiusLarge),
    ),
  ),
  builder: (context) => content,
);
```

### Badge (M3)
```dart
Badge(
  label: Text('3'),
  backgroundColor: AppColors.officialBlue,
  child: Icon(Icons.notifications),
)
```

## Animaciones Recomendadas

### Transicion de opacidad
```dart
AnimatedOpacity(
  duration: Duration(milliseconds: 200),
  opacity: isVisible ? 1.0 : 0.0,
  child: widget,
)
```

### Transicion de tamano
```dart
AnimatedContainer(
  duration: Duration(milliseconds: 300),
  curve: Curves.easeInOut,
  height: isExpanded ? 200 : 60,
  child: widget,
)
```

### Hero transitions
```dart
Hero(
  tag: 'item-$id',
  child: widget,
)
```

### Staggered list animation
```dart
AnimatedList(
  key: _listKey,
  itemBuilder: (context, index, animation) {
    return SlideTransition(
      position: animation.drive(
        Tween(begin: Offset(1, 0), end: Offset.zero)
          .chain(CurveTween(curve: Curves.easeOut)),
      ),
      child: itemWidget,
    );
  },
)
```

## Responsive Patterns

### Sliver Layout (scroll eficiente)
```dart
CustomScrollView(
  slivers: [
    SliverAppBar(
      floating: true,
      title: Text('Title'),
      backgroundColor: AppColors.backgroundPrimary,
    ),
    SliverPadding(
      padding: EdgeInsets.all(AppStyles.spacingL),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => itemBuilder(index),
          childCount: items.length,
        ),
      ),
    ),
  ],
)
```

### Grid adaptivo
```dart
LayoutBuilder(
  builder: (context, constraints) {
    final crossAxisCount = constraints.maxWidth > 600 ? 3 : 2;
    return GridView.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: AppStyles.spacingM,
        mainAxisSpacing: AppStyles.spacingM,
      ),
      itemBuilder: (context, index) => itemWidget,
    );
  },
)
```

## Empty States

```dart
Center(
  child: Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(
        Icons.inbox_outlined,
        size: 64,
        color: AppColors.textTertiary,
      ),
      SizedBox(height: AppStyles.spacingL),
      Text(
        'No items yet',
        style: AppStyles.subtitle.copyWith(color: AppColors.textSecondary),
      ),
      SizedBox(height: AppStyles.spacingS),
      Text(
        'Items will appear here when created',
        style: AppStyles.caption.copyWith(color: AppColors.textTertiary),
        textAlign: TextAlign.center,
      ),
    ],
  ),
)
```

## Error States con Retry

```dart
Center(
  child: Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(Icons.error_outline, size: 48, color: AppColors.error),
      SizedBox(height: AppStyles.spacingL),
      Text('Something went wrong', style: AppStyles.subtitle),
      SizedBox(height: AppStyles.spacingS),
      Text(errorMessage, style: AppStyles.caption.copyWith(
        color: AppColors.textTertiary,
      )),
      SizedBox(height: AppStyles.spacingXL),
      FilledButton.icon(
        onPressed: onRetry,
        icon: Icon(Icons.refresh),
        label: Text('Retry'),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.officialBlue,
        ),
      ),
    ],
  ),
)
```
