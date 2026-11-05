import CryptoKit
import Foundation

// Called only by ios_beta.py with stdout captured in memory, never a CI log.
let arguments = CommandLine.arguments
guard arguments.count == 4 else { exit(2) }
let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: arguments[1], encoding: .utf8))
func encoded(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
let now = Int(Date().timeIntervalSince1970)
let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": arguments[2], "typ": "JWT"])
let payload = try JSONSerialization.data(withJSONObject: ["iss": arguments[3], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"])
let unsigned = encoded(header) + "." + encoded(payload)
let signature = try key.signature(for: Data(unsigned.utf8))
print(unsigned + "." + encoded(signature.rawRepresentation))
