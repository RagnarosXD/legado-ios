// Linux 上没有 CryptoKit，这里给出与 Insecure.MD5.hash 同签名的最小实现，供类型检查使用
import Foundation

enum Insecure {
    enum MD5 {
        static func hash(data: Data) -> [UInt8] {
            return Array(repeating: 0, count: 16)
        }
    }
}
