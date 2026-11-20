//
//  ICSilenceTrimLevel.swift
//  InstacastPlus
//
//  The selectable strengths of pause shortening and the compressor values behind them.
//  The values were calibrated offline with Tools/SilenceTrim/silence_trim_analyze.swift on real
//  episodes (see Tools/SilenceTrim/README.md for the measured results).
//

import Foundation

@objc enum ICSilenceTrimLevel: Int {
    case off = 0
    case mild = 1
    case medium = 2
    case strong = 3

    static let allLevels: [ICSilenceTrimLevel] = [.off, .mild, .medium, .strong]

    var compressorParameters: ICSilenceCompressor.Parameters? {
        switch self {
        case .off:
            return nil
        case .mild:
            // Only clear pauses, gently: about 3-8 % shorter on the calibration episodes.
            return ICSilenceCompressor.Parameters(silenceRate: 2.0,
                                                  maximumPauseDuration: 1.0,
                                                  leadingGuard: 0.06,
                                                  trailingGuard: 0.04)
        case .medium:
            // Comparable to Overcast's Smart Speed: about 5-11 % shorter.
            return ICSilenceCompressor.Parameters(silenceRate: 3.5,
                                                  maximumPauseDuration: 0.7,
                                                  leadingGuard: 0.045,
                                                  trailingGuard: 0.028)
        case .strong:
            // Pauses nearly vanish, hesitations included: about 7-14 % shorter.
            return ICSilenceCompressor.Parameters(silenceRate: 8.0,
                                                  maximumPauseDuration: 0.45,
                                                  leadingGuard: 0.03,
                                                  trailingGuard: 0.018)
        }
    }

    var diagnosticName: String {
        switch self {
        case .off: return "off"
        case .mild: return "mild"
        case .medium: return "medium"
        case .strong: return "strong"
        }
    }
}
