// The colour roles of every theme (lib/theme.dart): borders, text and focus ring are readable against what they sit
// on, and each button state is one clear step from the next.
// Run: flutter test test/colors_test.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/theme.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Perceived lightness (CIE L*, 0 to 100).
double lightness(Color c) {
  final y = c.computeLuminance();
  return y > 0.008856 ? 116 * math.pow(y, 1 / 3) - 16 : 903.3 * y;
}

void main() {
  final themes = <String, AppColors>{
    'light': AppColors.light,
    'silk light': AppColors.silkLight,
    'dusk': AppColors.dusk,
    'dark': AppColors.dark,
    'dark 2': AppColors.dark2,
    'dark 3': AppColors.dark3,
  };

  for (final MapEntry(key: name, value: c) in themes.entries) {
    group(name, () {
      test('borders are at least 3:1 against the page, and grow with the state', () {
        expect(contrast(c.buttonBorder, c.page), greaterThanOrEqualTo(3));
        expect(contrast(c.buttonHoverBorder, c.page), greaterThanOrEqualTo(3));
        expect(contrast(c.optionBorder, c.page), greaterThanOrEqualTo(3));
        expect(contrast(c.buttonHoverBorder, c.page), greaterThan(contrast(c.buttonBorder, c.page) + 0.3));
        expect(contrast(c.optionBorder, c.page), greaterThan(contrast(c.buttonHoverBorder, c.page)));
      });

      test('text is at least 4.5:1 on what it sits on', () {
        for (final fill in [c.buttonFill, c.buttonHoverFill, c.buttonPressedFill]) {
          expect(contrast(c.buttonText, fill), greaterThanOrEqualTo(4.5));
        }
        expect(contrast(c.optionText, c.optionFill), greaterThanOrEqualTo(4.5));
        for (final fill in [c.mainFill, c.mainHoverFill, c.mainPressedFill]) {
          expect(contrast(c.mainText, fill), greaterThanOrEqualTo(4.5));
        }
        for (final text in [c.text, c.textSecondary, c.textMuted]) {
          expect(contrast(text, c.page), greaterThanOrEqualTo(4.5));
          expect(contrast(text, c.sidebar), greaterThanOrEqualTo(4.5));
        }
        expect(contrast(c.sideText, c.sidebar), greaterThanOrEqualTo(4.5));
        expect(contrast(c.sideMuted, c.sidebar), greaterThanOrEqualTo(4.5));
        for (final fill in [c.rowHover, c.rowPressed, c.rowSelected]) {
          expect(contrast(c.text, fill), greaterThanOrEqualTo(4.5));
          expect(contrast(c.sideText, fill), greaterThanOrEqualTo(4.5));
        }
      });

      test('the focus ring shows on the page and on the sidebar', () {
        expect(contrast(c.focusRing, c.page), greaterThanOrEqualTo(3));
        expect(contrast(c.focusRing, c.sidebar), greaterThanOrEqualTo(3));
      });

      test('a disabled button is quiet but can be seen', () {
        expect(contrast(c.disabledBorder, c.page), inInclusiveRange(1.2, 2.5));
        expect(contrast(c.disabledText, c.page), inInclusiveRange(2, 4.5));
      });

      test('each button state is one clear step from the next', () {
        final normal = lightness(c.buttonFill);
        final hover = lightness(c.buttonHoverFill);
        final pressed = lightness(c.buttonPressedFill);
        final option = lightness(c.optionFill);
        expect((hover - normal).abs(), greaterThanOrEqualTo(3));
        expect((pressed - normal).abs(), greaterThanOrEqualTo(1.5));
        expect((pressed - hover).abs(), greaterThanOrEqualTo(3));
        expect((option - hover).abs(), greaterThanOrEqualTo(3));
        expect((option - normal).abs(), greaterThanOrEqualTo(5));
        final main = lightness(c.mainFill);
        expect((lightness(c.mainHoverFill) - main).abs(), greaterThanOrEqualTo(3));
        expect((lightness(c.mainPressedFill) - main).abs(), greaterThanOrEqualTo(3));
        // The main button stands apart from a normal one.
        expect((main - normal).abs(), greaterThanOrEqualTo(40));
      });

      test('a row with no border shows under the pointer on the page and on the sidebar', () {
        for (final row in [c.rowHover, c.rowPressed, c.rowSelected]) {
          expect(contrast(row, c.page), greaterThanOrEqualTo(1.15));
          expect(contrast(row, c.sidebar), greaterThanOrEqualTo(1.15));
        }
        final hover = lightness(c.rowHover);
        final selected = lightness(c.rowSelected);
        final pressed = lightness(c.rowPressed);
        expect((selected - hover).abs(), greaterThanOrEqualTo(3));
        expect((pressed - selected).abs(), greaterThanOrEqualTo(3));
      });
    });
  }

  test('the black theme has the owner\'s values', () {
    const c = AppColors.dark3;
    expect(c.page, const Color(0xFF060606));
    expect(c.buttonFill, const Color(0xFF181818));
    expect(c.buttonBorder, const Color(0xFF5C5C5C));
    expect(c.buttonText, const Color(0xFFE6E6E6));
    expect(c.buttonHoverFill, const Color(0xFF262626));
    expect(c.buttonHoverBorder, const Color(0xFF737373));
    expect(c.buttonPressedFill, const Color(0xFF141414));
    expect(c.optionFill, const Color(0xFF2E2E2E));
    expect(c.optionBorder, const Color(0xFF8A8A8A));
    expect(c.mainFill, const Color(0xFFCFCFCF));
    expect(c.disabledBorder, const Color(0xFF2A2A2A));
    expect(c.disabledText, const Color(0xFF5C5C5C));
    expect(c.textMuted, const Color(0xFF858585));
  });
}
