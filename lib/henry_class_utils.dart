import 'package:flutter/material.dart';
import 'package:clearbridge/clearbridge_colors.dart';

abstract final class HenryClassUtils {
  static String label(String code) => switch (code) {
        'RL' || 'UL' => 'Loop',
        'LL'         => 'Radial Loop',
        'W'  || 'PW' => 'Whorl',
        'CPW'        => 'Central Pocket Whorl',
        'DLW'        => 'Double Loop Whorl',
        'AW'         => 'Accidental Whorl',
        'A'  || 'PA' => 'Plain Arch',
        'TA'         => 'Tented Arch',
        _            => code,
      };

  static String snippet(String code) => switch (code) {
        'RL' || 'UL' =>
          'Loop patterns are the most common fingerprint type — but every loop '
          'is uniquely yours. Your ridge count, spacing, and delta position are '
          'statistically one-of-a-kind among eight billion people.',
        'LL' =>
          'Radial loops are rare — fewer than 4% of people carry one. Unlike '
          'most loops, yours curves toward the thumb-side of the hand, making '
          'it one of fingerprinting\'s less common formations.',
        'W' || 'PW' =>
          'Whorls are concentric spirals found in roughly 30% of thumbprints. '
          'In ancient East Asia, whorls were pressed in clay as personal seals '
          'centuries before formal identification systems existed.',
        'CPW' =>
          'A central pocket whorl contains a tight inner spiral nested inside '
          'its own loop — a double-layer structure found in fewer than 5% of '
          'thumbprints. One of fingerprinting\'s most structurally complex patterns.',
        'DLW' =>
          'Two separate loop systems flowing around each other — a double loop '
          'whorl. So distinct that 19th-century forensic pioneers classified it '
          'as its own category separate from standard whorls.',
        'AW' =>
          'Your print combines multiple pattern types that don\'t conform to any '
          'single class — an accidental whorl. The rarest and most structurally '
          'complex category in the entire Henry classification system.',
        'A' || 'PA' =>
          'Plain arches appear in fewer than 5% of people — no delta, no core, '
          'just a clean wave of ridges flowing from one side to the other. '
          'Simple in form, rare in occurrence.',
        'TA' =>
          'A tented arch has a sharp central spike that gives it a tent-like '
          'silhouette — one of the rarest patterns in human fingerprinting, '
          'found in well under 5% of thumbprints.',
        _ =>
          'Every fingerprint is unique — no two have ever been found to match '
          'in the entire recorded history of forensic science.',
      };

  static IconData icon(String code) => switch (code) {
        'RL' || 'UL' || 'LL'           => Icons.loop_rounded,
        'W' || 'PW' || 'CPW' || 'DLW' || 'AW' => Icons.data_usage_rounded,
        'A' || 'PA' || 'TA'            => Icons.show_chart_rounded,
        _                              => Icons.fingerprint,
      };

  static Color accentColor(String code) => switch (code) {
        'RL' || 'UL' || 'LL'           => ClearBridgeColors.cyan,
        'W' || 'PW' || 'CPW' || 'DLW' || 'AW' => ClearBridgeColors.gold,
        'A' || 'PA' || 'TA'            => ClearBridgeColors.silverBright,
        _                              => ClearBridgeColors.cyan,
      };

  // Rotates daily — index by day-of-month so it feels fresh each session.
  static String dailyFact() {
    const facts = [
      'No two fingerprints are identical — even identical twins have different prints.',
      'Fingerprints form in the womb between weeks 10–16 of pregnancy and never change.',
      'Koalas have fingerprints almost indistinguishable from human prints — forensic experts can mistake them.',
      'Ancient Babylonians pressed fingerprints into clay tablets as personal signatures over 3 000 years ago.',
      'Ridge density (ridges per mm²) is unique per person and stable from birth to death.',
      'About 60–65% of people have loop patterns; 30–35% have whorls; only ~5% have arches.',
      'The FBI\'s NGI fingerprint database holds over 150 million individual records.',
      'Friction ridges work like tyre treads — they channel moisture away to maintain grip.',
      'The first criminal conviction using fingerprint evidence was in Argentina in 1892.',
      'Fingerprints can be lifted from surfaces up to 40 years after they were left.',
    ];
    return facts[DateTime.now().day % facts.length];
  }
}
