import Foundation
import os

/// Countries selectable on the phone-number login screen.
/// The JID derives from the full number (WhatsApp/Telegram style), so the
/// country prefix is part of the identity: `+53 5123...` -> `<number>@domain`.
enum CountryCode: String, CaseIterable, Identifiable, Sendable {
    case cuba = "+53"
    case unitedStates = "+1"
    case russia = "+7"
    case spain = "+34"
    case france = "+33"
    case unitedKingdom = "+44"
    case germany = "+49"
    case peru = "+51"
    case mexico = "+52"
    case brazil = "+55"
    case chile = "+56"
    case colombia = "+57"
    case venezuela = "+58"
    case argentina = "+54"
    case uruguay = "+598"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .cuba: return "Cuba"
        case .unitedStates: return "United States"
        case .russia: return "Russia"
        case .spain: return "Spain"
        case .france: return "France"
        case .unitedKingdom: return "United Kingdom"
        case .germany: return "Germany"
        case .peru: return "Peru"
        case .mexico: return "Mexico"
        case .brazil: return "Brazil"
        case .chile: return "Chile"
        case .colombia: return "Colombia"
        case .venezuela: return "Venezuela"
        case .argentina: return "Argentina"
        case .uruguay: return "Uruguay"
        }
    }

    var prefix: String { rawValue }
}

@MainActor
@Observable
final class PhoneLoginViewModel {
    var selectedCountry: CountryCode = .cuba
    var phoneNumber = ""
    var isLoading = false
    var errorMessage: String?

    /// Demo-only: the code "sent" by the simulated request. Replaced by the
    /// backend response once the SMS service exists.
    private(set) var generatedCode: String?
    /// The phone number as displayed on the OTP screen (masked, WA style).
    private(set) var maskedPhone: String?

    /// Full E.164-style number: country prefix + local digits.
    var fullNumber: String {
        selectedCountry.prefix + digitsOnly(phoneNumber)
    }

    func requestCode() async {
        let digits = digitsOnly(phoneNumber)
        guard (6...15).contains(digits.count) else {
            errorMessage = "Enter a valid phone number"
            return
        }
        isLoading = true
        errorMessage = nil

        // TODO(backend): POST /v1/auth/request-code { "phone": fullNumber }
        // The server generates and hashes the OTP (CSPRNG, TTL 5 min, rate
        // limited) and sends it via SMS. Until then, simulate locally.
        try? await Task.sleep(for: .milliseconds(600))
        generatedCode = OTPCodeGenerator.generate()
        maskedPhone = mask(fullNumber)
        isLoading = false
    }

    private func digitsOnly(_ text: String) -> String {
        text.filter(\.isNumber)
    }

    private func mask(_ full: String) -> String {
        let digits = digitsOnly(full)
        guard digits.count > 4 else { return full }
        let head = String(digits.prefix(2))
        let tail = String(digits.suffix(3))
        return "+\(head) ••• \(tail)"
    }
}
