import CommonCrypto
import CryptoKit
import Foundation

public enum AndroidBackupAESError: Error, Equatable, Sendable {
  case invalidBase64
  case cryptFailed(Int32)
  case invalidUTF8
}

/// Compatibility codec for Android `BackupAES` at the frozen Legado baseline.
///
/// Android derives the 128-bit key from the first 16 ASCII characters of the
/// lowercase MD5 hex digest, then relies on Java's `AES` default
/// (`AES/ECB/PKCS5Padding`). PKCS5 and PKCS7 are equivalent for AES blocks.
public enum AndroidBackupAES {
  public static func encryptBase64(
    _ plaintext: String,
    backupPassword: String
  ) throws -> String {
    let encrypted = try crypt(
      Data(plaintext.utf8),
      operation: CCOperation(kCCEncrypt),
      backupPassword: backupPassword
    )
    return encrypted.base64EncodedString()
  }

  public static func decryptBase64(
    _ payload: String,
    backupPassword: String
  ) throws -> String {
    guard let encrypted = Data(base64Encoded: payload) else {
      throw AndroidBackupAESError.invalidBase64
    }
    let decrypted = try crypt(
      encrypted,
      operation: CCOperation(kCCDecrypt),
      backupPassword: backupPassword
    )
    guard let value = String(data: decrypted, encoding: .utf8) else {
      throw AndroidBackupAESError.invalidUTF8
    }
    return value
  }

  public static func keyData(backupPassword: String) -> Data {
    let digest = Insecure.MD5.hash(data: Data(backupPassword.utf8))
    let hexadecimal = digest.map { String(format: "%02x", $0) }.joined()
    return Data(hexadecimal.prefix(16).utf8)
  }

  private static func crypt(
    _ input: Data,
    operation: CCOperation,
    backupPassword: String
  ) throws -> Data {
    let key = keyData(backupPassword: backupPassword)
    let outputCapacity = input.count + Int(kCCBlockSizeAES128)
    var output = Data(count: outputCapacity)
    var moved = 0
    let status = key.withUnsafeBytes { keyBytes in
      input.withUnsafeBytes { inputBytes in
        output.withUnsafeMutableBytes { outputBytes in
          CCCrypt(
            operation,
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
            keyBytes.baseAddress,
            key.count,
            nil,
            inputBytes.baseAddress,
            input.count,
            outputBytes.baseAddress,
            outputCapacity,
            &moved
          )
        }
      }
    }
    guard status == kCCSuccess else {
      throw AndroidBackupAESError.cryptFailed(status)
    }
    output.removeSubrange(moved..<output.count)
    return output
  }
}
