import Foundation

/// Rough, published-literature estimates of how much of the unquantized (BF16) model's quality a
/// quantization keeps. They are NOT measured on your model; they summarise typical benchmark/perplexity
/// deltas for modern 7B–70B models (llama.cpp K-quants, MLX affine group quantization, KV-cache studies).
enum Quality {
    /// Bits per weight → retained quality (% of BF16).
    static func weights(bits: Double) -> Double {
        switch bits {
        case 16...: return 100
        case 8..<16: return 99.7
        case 6..<8: return 99.2
        case 5..<6: return 98.6
        case 4..<5: return 97.5
        case 3..<4: return 93
        case 2..<3: return 82
        default: return 70
        }
    }

    /// KV-cache element bits → retained quality (% of a BF16 cache).
    static func kv(bits: Double) -> Double {
        switch bits {
        case 16...: return 100
        case 8..<16: return 99.9
        case 4..<8: return 99.0
        default: return 96
        }
    }

    /// Bits from a quantization label: "4bit", "q4_k_m", "Q8_0", "int8", "bf16", "symmetric_int8", "IQ3_XXS", "MXFP4".
    static func bits(fromLabel raw: String) -> Double? {
        let s = raw.lowercased()
        if s.contains("bf16") || s.contains("fp16") || s.contains("f16") || s == "16bit" { return 16 }
        if s.contains("f32") && !s.contains("scale") { return 32 }
        if s.contains("mxfp4") || s.contains("nvfp4") { return 4 }
        let patterns = ["iq(\\d)", "q(\\d)", "int(\\d+)", "(\\d+)[-_ ]?bit", "fp(\\d)"]
        for p in patterns {
            if let r = s.range(of: p, options: .regularExpression) {
                let digits = s[r].filter(\.isNumber)
                if let v = Double(digits), v > 0, v <= 32 { return v }
            }
        }
        return nil
    }

    static func percent(_ v: Double) -> String { v >= 100 ? "100%" : String(format: "≈%.1f%%", v) }
}
