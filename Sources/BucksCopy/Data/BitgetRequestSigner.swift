import CryptoKit
import Foundation

struct BitgetRequestSigner {
    func sign(
        timestamp: String,
        method: String,
        requestPath: String,
        queryString: String?,
        body: String,
        secretKey: String
    ) -> String {
        let normalizedQuery = queryString.map { $0.isEmpty ? "" : "?\($0)" } ?? ""
        let message = timestamp + method.uppercased() + requestPath + normalizedQuery + body
        let key = SymmetricKey(data: Data(secretKey.utf8))
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: key
        )
        return Data(authenticationCode).base64EncodedString()
    }
}
