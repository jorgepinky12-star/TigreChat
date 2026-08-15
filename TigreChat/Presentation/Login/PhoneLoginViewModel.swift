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
        case .cuba: return String(localized: "Cuba")
        case .unitedStates: return String(localized: "United States")
        case .russia: return String(localized: "Russia")
        case .spain: return String(localized: "Spain")
        case .france: return String(localized: "France")
        case .unitedKingdom: return String(localized: "United Kingdom")
        case .germany: return String(localized: "Germany")
        case .peru: return String(localized: "Peru")
        case .mexico: return String(localized: "Mexico")
        case .brazil: return String(localized: "Brazil")
        case .chile: return String(localized: "Chile")
        case .colombia: return String(localized: "Colombia")
        case .venezuela: return String(localized: "Venezuela")
        case .argentina: return String(localized: "Argentina")
        case .uruguay: return String(localized: "Uruguay")
        }
    }

    var prefix: String { rawValue }
}

@MainActor
@Observable
final class PhoneLoginViewModel {
    var selectedCountry: CountryCode = .brazil
    var phoneNumber = ""
    var isLoading = false
    var errorMessage: String?

    /// The phone number as displayed on the OTP screen (masked, WA style).
    /// Also acts as the "code requested" flag that drives navigation.
    private(set) var maskedPhone: String?

    /// Backend client shared with the OTP step (it keeps the clientToken).
    let service: AuthService

    init(service: AuthService) {
        self.service = service
    }

    /// Full E.164-style number: country prefix + local digits.
    var fullNumber: String {
        selectedCountry.prefix + digitsOnly(phoneNumber)
    }

    func requestCode() async {
        let digits = digitsOnly(phoneNumber)
        guard (6...15).contains(digits.count) else {
            errorMessage = String(localized: "Enter a valid phone number")
            return
        }
        isLoading = true
        errorMessage = nil

        do {
            try await service.requestCode(phone: fullNumber)
            maskedPhone = mask(fullNumber)
        } catch {
            errorMessage = (error as? SMSAuthError)?.errorDescription
                ?? String(localized: "Could not reach the server. Try again.")
        }
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
