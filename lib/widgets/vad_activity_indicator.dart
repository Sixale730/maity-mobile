import 'package:flutter/material.dart';

/// Pulsing dot indicator that shows when the VAD detects active speech.
///
/// Replaces the live preview text — provides immediate visual feedback
/// that the app is "hearing" the user without triggering expensive
/// transcript rebuilds every second.
class VadActivityIndicator extends StatefulWidget {
  final ValueNotifier<bool> vadSpeechActive;

  const VadActivityIndicator({
    super.key,
    required this.vadSpeechActive,
  });

  @override
  State<VadActivityIndicator> createState() => _VadActivityIndicatorState();
}

class _VadActivityIndicatorState extends State<VadActivityIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.3).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _opacityAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    widget.vadSpeechActive.addListener(_onVadStateChanged);
    if (widget.vadSpeechActive.value) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(VadActivityIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.vadSpeechActive != widget.vadSpeechActive) {
      oldWidget.vadSpeechActive.removeListener(_onVadStateChanged);
      widget.vadSpeechActive.addListener(_onVadStateChanged);
    }
  }

  void _onVadStateChanged() {
    if (widget.vadSpeechActive.value) {
      if (!_controller.isAnimating) {
        _controller.repeat(reverse: true);
      }
    } else {
      _controller.stop();
      _controller.reset();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.vadSpeechActive.removeListener(_onVadStateChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.vadSpeechActive.value) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Transform.scale(
                scale: _scaleAnimation.value,
                child: Opacity(
                  opacity: _opacityAnimation.value,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFFF93A6E),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 6),
          Text(
            'Listening…',
            style: TextStyle(
              color: Colors.grey.shade500,
              fontStyle: FontStyle.italic,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
