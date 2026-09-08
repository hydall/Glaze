import 'package:flutter/material.dart';

class RollingNumber extends StatelessWidget {
  final String value;
  final TextStyle? style;

  const RollingNumber({super.key, required this.value, this.style});

  @override
  Widget build(BuildContext context) {
    bool isDecimal = false;
    List<Widget> children = [];
    
    // Assign stable IDs based on position from the right so that digits stay in their proper places (ones, tens, etc.).
    final str = value;
    for (int i = 0; i < str.length; i++) {
      final char = str[i];
      if (char == '.' || char == ',') {
        isDecimal = true;
      }
      final bool isDigit = int.tryParse(char) != null;
      final bool isFast = isDecimal && isDigit;
      
      if (!isDigit) {
        children.add(Text(char, style: style));
      } else {
        children.add(
          _RollingDigit(
            key: ValueKey('pos-${str.length - i}'),
            digit: char,
            isFast: isFast,
            style: style,
          ),
        );
      }
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

class _RollingDigit extends StatelessWidget {
  final String digit;
  final bool isFast;
  final TextStyle? style;

  const _RollingDigit({super.key, required this.digit, this.isFast = false, this.style});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSwitcher(
        duration: Duration(milliseconds: isFast ? 50 : 200),
        transitionBuilder: (Widget child, Animation<double> animation) {
          final inAnimation = Tween<Offset>(
            begin: const Offset(0.0, 1.0),
            end: Offset.zero,
          ).animate(animation);
          final outAnimation = Tween<Offset>(
            begin: const Offset(0.0, -1.0),
            end: Offset.zero,
          ).animate(animation);
          
          if (child.key == ValueKey<String>(digit)) {
            // New child (entering)
            return SlideTransition(
              position: inAnimation,
              child: FadeTransition(opacity: animation, child: child),
            );
          } else {
            // Old child (exiting)
            return SlideTransition(
              position: outAnimation,
              child: FadeTransition(opacity: animation, child: child),
            );
          }
        },
        layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
          return Stack(
            alignment: Alignment.center,
            children: <Widget>[
              ...previousChildren,
              ?currentChild,
            ],
          );
        },
        child: Text(
          digit,
          key: ValueKey<String>(digit),
          style: style,
        ),
      ),
    );
  }
}
