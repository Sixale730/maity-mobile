import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:omi/backend/schema/schema.dart';
import 'package:omi/providers/action_items_provider.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:provider/provider.dart';
import 'package:omi/l10n/app_localizations.dart';

class ActionItemFormSheet extends StatefulWidget {
  final ActionItemWithMetadata? actionItem; // null for create, non-null for edit
  final VoidCallback? onRefresh;

  const ActionItemFormSheet({
    super.key,
    this.actionItem,
    this.onRefresh,
  });

  bool get isEditing => actionItem != null;

  @override
  State<ActionItemFormSheet> createState() => _ActionItemFormSheetState();
}

class _ActionItemFormSheetState extends State<ActionItemFormSheet> {
  late TextEditingController _textController;
  late bool _isCompleted;
  DateTime? _selectedDueDate;

  @override
  void initState() {
    super.initState();
    if (widget.isEditing) {
      _textController = TextEditingController(text: widget.actionItem!.description);
      _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: _textController.text.length),
      );
      _isCompleted = widget.actionItem!.completed;
      _selectedDueDate = widget.actionItem!.dueAt;
    } else {
      _textController = TextEditingController();
      _isCompleted = false;
      _selectedDueDate = null;
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _saveActionItem() async {
    final l10n = AppLocalizations.of(context);
    if (_textController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n?.actionItemDescriptionEmpty ?? 'Action item description cannot be empty.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final provider = Provider.of<ActionItemsProvider>(context, listen: false);

    Navigator.pop(context);

    if (widget.isEditing) {
      // Editing existing item
      String newDescription = _textController.text.trim();
      bool descriptionChanged = newDescription != widget.actionItem!.description;
      bool dueDateChanged = _selectedDueDate != widget.actionItem!.dueAt;
      bool completionChanged = _isCompleted != widget.actionItem!.completed;

      if (!descriptionChanged && !dueDateChanged && !completionChanged) {
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n?.actionItemUpdated ?? 'Action item updated'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }

      try {
        if (descriptionChanged) {
          await provider.updateActionItemDescription(widget.actionItem!, newDescription);
        }

        if (dueDateChanged) {
          await provider.updateActionItemDueDate(widget.actionItem!, _selectedDueDate);
        }

        if (completionChanged) {
          await provider.updateActionItemState(widget.actionItem!, _isCompleted);
        }

        // Track action item edit
        if (descriptionChanged || dueDateChanged) {
          MixpanelManager().actionItemEdited(
            actionItemId: widget.actionItem!.id,
            titleChanged: descriptionChanged,
            dateChanged: dueDateChanged,
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n?.failedToUpdateActionItem ?? 'Failed to update action item'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n?.actionItemCreated ?? 'Action item created'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }

      try {
        final createdItem = await provider.createActionItem(
          description: _textController.text.trim(),
          dueAt: _selectedDueDate,
          completed: _isCompleted,
        );

        if (createdItem != null) {
          // Track manually added action item
          MixpanelManager().actionItemManuallyAdded(
            actionItemId: createdItem.id,
            timestamp: DateTime.now(),
          );
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n?.failedToCreateActionItem ?? 'Failed to create action item'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n?.failedToCreateActionItem ?? 'Failed to create action item'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    }
  }

  void _deleteActionItem() async {
    if (!widget.isEditing) return;
    final l10n = AppLocalizations.of(context);

    Navigator.pop(context);

    final provider = Provider.of<ActionItemsProvider>(context, listen: false);
    final success = await provider.deleteActionItem(widget.actionItem!);

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n?.actionItemDeleted(widget.actionItem!.description) ?? 'Action item deleted'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n?.failedToDeleteActionItem ?? 'Failed to delete action item'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _openDateTimePicker() async {
    final DateTime? result = await showCupertinoModalPopup<DateTime>(
      context: context,
      builder: (context) => DateTimePickerSheet(
        initialDateTime: _selectedDueDate,
        minimumDate: widget.isEditing ? widget.actionItem!.createdAt : DateTime.now(),
      ),
    );

    if (result != null) {
      setState(() {
        _selectedDueDate = result;
      });
    }
  }

  void _clearDueDate() {
    setState(() {
      _selectedDueDate = null;
    });
  }

  String _formatDueDateWithTime(DateTime date) {
    final weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];

    // Format date as "Wednesday, June 25"
    final dayName = weekdays[date.weekday - 1];
    final monthName = months[date.month - 1];

    // Format time as "8:12am"
    final hour = date.hour;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'pm' : 'am';
    final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);

    return '$dayName, $monthName ${date.day} - $displayHour:$minute$period';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1F1F25),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Completed status toggle
                Row(
                  children: [
                    SizedBox(
                      height: 24,
                      width: 24,
                      child: Checkbox(
                        value: _isCompleted,
                        activeColor: Colors.deepPurpleAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(5),
                        ),
                        onChanged: (bool? value) async {
                          if (value == null) return;

                          HapticFeedback.lightImpact();

                          setState(() {
                            _isCompleted = value;
                          });

                          // Only update immediately if editing
                          if (widget.isEditing) {
                            final provider = Provider.of<ActionItemsProvider>(context, listen: false);
                            await provider.updateActionItemState(widget.actionItem!, value);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isCompleted ? (AppLocalizations.of(context)?.completed ?? 'Completed') : (AppLocalizations.of(context)?.markComplete ?? 'Mark complete'),
                      style: TextStyle(
                        color: Colors.grey.shade300,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
                // Delete button (only for edit mode)
                if (widget.isEditing)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () {
                      // Show delete confirmation dialog
                      final l10n = AppLocalizations.of(context);
                      showDialog(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          backgroundColor: const Color(0xFF1F1F25),
                          title: Text(
                            l10n?.deleteActionItem ?? 'Delete Action Item',
                            style: const TextStyle(color: Colors.white),
                          ),
                          content: Text(
                            l10n?.areYouSureDeleteActionItem ?? 'Are you sure you want to delete this action item?',
                            style: TextStyle(color: Colors.grey.shade300),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogContext, false),
                              child: Text(
                                l10n?.cancel ?? 'Cancel',
                                style: TextStyle(color: Colors.grey.shade400),
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                Navigator.pop(dialogContext, true); // Close dialog
                                _deleteActionItem();
                              },
                              child: Text(
                                l10n?.delete ?? 'Delete',
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // Text field for editing/creating the action item
            TextField(
              controller: _textController,
              autofocus: true,
              maxLines: null,
              textInputAction: TextInputAction.done,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                height: 1.4,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                isDense: true,
                hintText: widget.isEditing ? null : (AppLocalizations.of(context)?.whatNeedsToBeDone ?? 'What needs to be done?'),
                hintStyle: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 16,
                ),
              ),
              onSubmitted: (value) {
                FocusScope.of(context).unfocus();
                if (value.trim().isNotEmpty) {
                  _saveActionItem();
                }
              },
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: _openDateTimePicker,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.schedule_outlined,
                      size: 20,
                      color: Colors.grey.shade400,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        _selectedDueDate != null ? _formatDueDateWithTime(_selectedDueDate!) : (AppLocalizations.of(context)?.addDueDate ?? 'Add due date'),
                        style: TextStyle(
                          color: _selectedDueDate != null ? Colors.white : Colors.grey.shade500,
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                    if (_selectedDueDate != null)
                      GestureDetector(
                        onTap: () {
                          _clearDueDate();
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.close,
                            size: 18,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.keyboard_return,
                        size: 13,
                        color: Colors.grey.shade400,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        widget.isEditing ? (AppLocalizations.of(context)?.pressDoneToSave ?? 'Press done to save') : (AppLocalizations.of(context)?.pressDoneToCreate ?? 'Press done to create'),
                        style: TextStyle(
                          color: Colors.grey.shade400,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${_textController.text.length}/200',
                  style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class DateTimePickerSheet extends StatefulWidget {
  final DateTime? initialDateTime;
  final DateTime? minimumDate;

  const DateTimePickerSheet({
    super.key,
    this.initialDateTime,
    this.minimumDate,
  });

  @override
  State<DateTimePickerSheet> createState() => _DateTimePickerSheetState();
}

class _DateTimePickerSheetState extends State<DateTimePickerSheet> {
  late DateTime _selectedDateTime;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final minimumDate = widget.minimumDate ?? now;

    if (widget.initialDateTime != null) {
      _selectedDateTime = widget.initialDateTime!.isBefore(minimumDate) ? minimumDate : widget.initialDateTime!;
    } else {
      _selectedDateTime = now.isBefore(minimumDate) ? minimumDate : now;
    }
  }

  @override
  Widget build(BuildContext context) {
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final currentMonth = months[_selectedDateTime.month - 1];
    final currentYear = _selectedDateTime.year;
    final minimumDate = widget.minimumDate ?? DateTime.now();

    // Check if we can go to previous month
    final canGoPrevious = _selectedDateTime.year > minimumDate.year ||
        (_selectedDateTime.year == minimumDate.year && _selectedDateTime.month > minimumDate.month);

    return Material(
      color: Colors.transparent,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.65,
        decoration: const BoxDecoration(
          color: Color(0xFF1F1F25),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle bar
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 20),
              decoration: BoxDecoration(
                color: Colors.grey.shade600,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header with navigation
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 17,
                      ),
                    ),
                  ),

                  // Month/Year navigation
                  Row(
                    children: [
                      CupertinoButton(
                        padding: const EdgeInsets.all(8),
                        onPressed: canGoPrevious
                            ? () {
                                final newMonth = _selectedDateTime.month == 1 ? 12 : _selectedDateTime.month - 1;
                                final newYear =
                                    _selectedDateTime.month == 1 ? _selectedDateTime.year - 1 : _selectedDateTime.year;

                                setState(() {
                                  _selectedDateTime = DateTime(
                                    newYear,
                                    newMonth,
                                    _selectedDateTime.day,
                                    _selectedDateTime.hour,
                                    _selectedDateTime.minute,
                                  );
                                });
                              }
                            : null,
                        child: Icon(
                          Icons.chevron_left,
                          color: canGoPrevious ? Colors.grey.shade400 : Colors.grey.shade700,
                          size: 24,
                        ),
                      ),
                      Text(
                        '$currentMonth $currentYear',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      CupertinoButton(
                        padding: const EdgeInsets.all(8),
                        onPressed: () {
                          setState(() {
                            _selectedDateTime = DateTime(
                              _selectedDateTime.month == 12 ? _selectedDateTime.year + 1 : _selectedDateTime.year,
                              _selectedDateTime.month == 12 ? 1 : _selectedDateTime.month + 1,
                              _selectedDateTime.day,
                              _selectedDateTime.hour,
                              _selectedDateTime.minute,
                            );
                          });
                        },
                        child: Icon(
                          Icons.chevron_right,
                          color: Colors.grey.shade400,
                          size: 24,
                        ),
                      ),
                    ],
                  ),

                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.pop(context, _selectedDateTime),
                    child: const Text(
                      'Done',
                      style: TextStyle(
                        color: Colors.deepPurpleAccent,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),

            // Selected date and time display
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.deepPurpleAccent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Colors.deepPurpleAccent.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.calendar_today_outlined,
                    color: Colors.deepPurpleAccent,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${months[_selectedDateTime.month - 1]} ${_selectedDateTime.day}, ${_selectedDateTime.year}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.access_time,
                    color: Colors.deepPurpleAccent,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_selectedDateTime.hour > 12 ? _selectedDateTime.hour - 12 : (_selectedDateTime.hour == 0 ? 12 : _selectedDateTime.hour)}:${_selectedDateTime.minute.toString().padLeft(2, '0')} ${_selectedDateTime.hour >= 12 ? 'PM' : 'AM'}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.deepPurpleAccent,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Simplified Date and Time Picker
            Expanded(
              child: Theme(
                data: ThemeData.dark().copyWith(
                  cupertinoOverrideTheme: const CupertinoThemeData(
                    brightness: Brightness.dark,
                    primaryColor: Colors.deepPurpleAccent,
                    textTheme: CupertinoTextThemeData(
                      dateTimePickerTextStyle: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                      ),
                    ),
                  ),
                ),
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.dateAndTime,
                  initialDateTime: _selectedDateTime,
                  minimumDate: widget.minimumDate ?? DateTime.now(),
                  maximumDate: DateTime.now().add(const Duration(days: 365 * 5)),
                  use24hFormat: false,
                  backgroundColor: const Color(0xFF1F1F25),
                  onDateTimeChanged: (DateTime newDateTime) {
                    setState(() {
                      _selectedDateTime = newDateTime;
                    });
                  },
                ),
              ),
            ),

            // Bottom safe area
            SizedBox(height: MediaQuery.of(context).padding.bottom + 10),
          ],
        ),
      ),
    );
  }
}
