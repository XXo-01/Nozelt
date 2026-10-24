import 'package:flutter/material.dart';

import 'flag_countries.dart';

class CountryFlag extends StatelessWidget {
  const CountryFlag(this.emoji, {this.size = 28, super.key});
  final String emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    final points = emoji.runes.toList();
    final code =
        points.length == 2 &&
            points.every((point) => point >= 0x1f1e6 && point <= 0x1f1ff)
        ? String.fromCharCodes(points.map((point) => point - 0x1f1e6 + 65))
        : null;
    if (code == null || !flagCountries.contains(code)) {
      return Icon(Icons.public_rounded, size: size);
    }
    return Image.asset(
      'assets/flags/$code.png',
      width: size * 1.2,
      height: size,
      fit: BoxFit.contain,
      semanticLabel: code,
    );
  }
}
