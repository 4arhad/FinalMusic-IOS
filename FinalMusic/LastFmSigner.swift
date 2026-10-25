import Foundation
import CryptoKit

// Port of LastFmSigner: MD5 over alphabetically sorted key+value pairs with
// the secret appended, per https://www.last.fm/api/authspec.
public enum LastFmSigner {
    public static func normalizeKey(_ raw: String) -> String {
        let whitespace = CharacterSet(charactersIn: " \n\t\u{00A0}\u{200B}\u{200C}\u{200D}\u{FEFF}")
        return raw
            .unicodeScalars
            .filter { scalar in
                !whitespace.contains(scalar) && scalar.isASCII &&
                (("0"..."9").contains(Character(scalar)) ||
                 ("a"..."f").contains(Character(scalar)) ||
                 ("A"..."F").contains(Character(scalar)))
            }
            .map { Character($0) }
            .reduce("") { $0 + String($1) }
            .lowercased()
    }

    public static let skipKeys: Set<String> = ["format", "callback", "api_sig"]

    public static func sign(params: [String: String], secret: String) -> String {
        let base = params
            .filter { !skipKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined() + secret
        return md5(base)
    }

    public static func md5(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

