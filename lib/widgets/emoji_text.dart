import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

/// Renders a category-based icon instead of emoji text.
/// Maps conversation categories to Material/FontAwesome icons.
class EmojiText extends StatelessWidget {
  final String emoji;
  final double size;

  const EmojiText(this.emoji, {super.key, this.size = 20});

  @override
  Widget build(BuildContext context) {
    final iconData = _getIconForEmoji(emoji);
    return FaIcon(
      iconData,
      size: size * 0.85,
      color: _getColorForEmoji(emoji),
    );
  }

  static IconData _getIconForEmoji(String emoji) {
    // Map common emojis to FontAwesome icons
    const emojiToIcon = {
      '💬': FontAwesomeIcons.solidComment,
      '🗣️': FontAwesomeIcons.solidComments,
      '🗣': FontAwesomeIcons.solidComments,
      '📅': FontAwesomeIcons.solidCalendar,
      '🗓': FontAwesomeIcons.solidCalendar,
      '🎥': FontAwesomeIcons.video,
      '📹': FontAwesomeIcons.video,
      '🎭': FontAwesomeIcons.masksTheater,
      '😔': FontAwesomeIcons.solidFaceSadTear,
      '😠': FontAwesomeIcons.solidFaceAngry,
      '😊': FontAwesomeIcons.solidFaceSmile,
      '😎': FontAwesomeIcons.solidFaceGrinStars,
      '🎤': FontAwesomeIcons.microphone,
      '🎵': FontAwesomeIcons.music,
      '🎶': FontAwesomeIcons.music,
      '📝': FontAwesomeIcons.solidNoteSticky,
      '✏️': FontAwesomeIcons.pen,
      '📋': FontAwesomeIcons.clipboardList,
      '📌': FontAwesomeIcons.thumbtack,
      '💡': FontAwesomeIcons.lightbulb,
      '🧠': FontAwesomeIcons.brain,
      '🚀': FontAwesomeIcons.rocket,
      '💼': FontAwesomeIcons.briefcase,
      '🏢': FontAwesomeIcons.building,
      '🏠': FontAwesomeIcons.house,
      '📞': FontAwesomeIcons.phone,
      '📱': FontAwesomeIcons.mobileScreen,
      '💻': FontAwesomeIcons.laptop,
      '🖥': FontAwesomeIcons.desktop,
      '📧': FontAwesomeIcons.solidEnvelope,
      '✈️': FontAwesomeIcons.plane,
      '🚗': FontAwesomeIcons.car,
      '🍽': FontAwesomeIcons.utensils,
      '🍕': FontAwesomeIcons.pizzaSlice,
      '☕': FontAwesomeIcons.mugHot,
      '🏥': FontAwesomeIcons.hospitalUser,
      '💊': FontAwesomeIcons.pills,
      '🏋️': FontAwesomeIcons.dumbbell,
      '⚽': FontAwesomeIcons.futbol,
      '🎮': FontAwesomeIcons.gamepad,
      '📚': FontAwesomeIcons.book,
      '🎓': FontAwesomeIcons.graduationCap,
      '💰': FontAwesomeIcons.sackDollar,
      '🛒': FontAwesomeIcons.cartShopping,
      '🔧': FontAwesomeIcons.wrench,
      '⚙️': FontAwesomeIcons.gear,
      '🎉': FontAwesomeIcons.champagneGlasses,
      '🎂': FontAwesomeIcons.cakeCandles,
      '❤️': FontAwesomeIcons.solidHeart,
      '👥': FontAwesomeIcons.userGroup,
      '👤': FontAwesomeIcons.solidUser,
      '🌍': FontAwesomeIcons.earthAmericas,
      '☀️': FontAwesomeIcons.sun,
      '🌙': FontAwesomeIcons.moon,
      '⭐': FontAwesomeIcons.solidStar,
      '🔔': FontAwesomeIcons.solidBell,
      '📊': FontAwesomeIcons.chartBar,
      '📈': FontAwesomeIcons.chartLine,
      '🔑': FontAwesomeIcons.key,
      '🎯': FontAwesomeIcons.bullseye,
      '✅': FontAwesomeIcons.solidCircleCheck,
      '❌': FontAwesomeIcons.xmark,
      '⚠️': FontAwesomeIcons.triangleExclamation,
      '🧑‍💻': FontAwesomeIcons.laptopCode,
    };

    return emojiToIcon[emoji] ?? FontAwesomeIcons.solidMessage;
  }

  static Color _getColorForEmoji(String emoji) {
    const emojiToColor = {
      '💬': Color(0xFF6C9EFF),
      '🗣️': Color(0xFF6C9EFF),
      '🗣': Color(0xFF6C9EFF),
      '📅': Color(0xFF4ECDC4),
      '🗓': Color(0xFF4ECDC4),
      '🎥': Color(0xFFFF6B6B),
      '📹': Color(0xFFFF6B6B),
      '🎭': Color(0xFFCB6CE6),
      '😔': Color(0xFF7B8794),
      '😠': Color(0xFFFF4444),
      '😊': Color(0xFFFFD93D),
      '😎': Color(0xFFFFD93D),
      '🎤': Color(0xFFFF9500),
      '🎵': Color(0xFFCB6CE6),
      '🎶': Color(0xFFCB6CE6),
      '📝': Color(0xFFFFD93D),
      '💡': Color(0xFFFFD93D),
      '🧠': Color(0xFFFF6B9D),
      '🚀': Color(0xFF485DF4),
      '💼': Color(0xFF8B6F47),
      '📞': Color(0xFF4ECDC4),
      '💻': Color(0xFF6C9EFF),
      '🧑‍💻': Color(0xFF6C9EFF),
      '❤️': Color(0xFFFF6B6B),
      '👥': Color(0xFF4ECDC4),
      '🎉': Color(0xFFFFD93D),
      '🎯': Color(0xFFFF4444),
      '✅': Color(0xFF4ECDC4),
    };

    return emojiToColor[emoji] ?? const Color(0xFF8B8B9E);
  }
}
