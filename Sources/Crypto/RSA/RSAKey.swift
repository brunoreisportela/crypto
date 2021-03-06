import CNIOOpenSSL
import NIOOpenSSL
import Foundation

/// Represents an in-memory RSA key.
public struct RSAKey {
    // MARK: Static

    /// Creates a new `RSAKey` from a private key pem file.
    public static func `private`(pem: LosslessDataConvertible) throws -> RSAKey {
        return try .init(type: .private, key: .make(type: .private, from: pem.convertToData()))
    }

    /// Creates a new `RSAKey` from a public key pem file.
    public static func `public`(pem: LosslessDataConvertible) throws -> RSAKey {
        return try .init(type: .public, key: .make(type: .public, from: pem.convertToData()))
    }

    /// Creates a new `RSAKey` from a public key certificate file.
    public static func `public`(certificate: LosslessDataConvertible) throws -> RSAKey {
        return try .init(type: .public, key: .make(type: .public, from: certificate.convertToData(), x509: true))
    }

    // MARK: Properties

    /// The specific RSA key type. Either public or private.
    ///
    /// Note: public keys can only verify signatures. A private key
    /// is required to create new signatures.
    public var type: RSAKeyType

    /// The C OpenSSL key ref.
    internal let c: CRSAKey

    // MARK: Init

    /// Creates a new `RSAKey` from a public or private key.
    internal init(type: RSAKeyType, key: CRSAKey) throws {
        self.type = type
        self.c = key
    }
    
    /// Creates a new `RSAKey` from components.
    ///
    /// For example, if you want to use Google's [public OAuth2 keys](https://www.googleapis.com/oauth2/v3/certs),
    /// you could parse the request using:
    ///
    ///     struct CertKeysResponse: APIResponse {
    ///         let keys: [Key]
    ///
    ///         struct Key: Codable {
    ///             let kty: String
    ///             let alg: String
    ///             let kid: String
    ///
    ///             let n: String
    ///             let e: String
    ///             let d: String?
    ///         }
    ///     }
    ///
    /// And then instantiate the key as:
    ///
    ///     try RSAKey.components(n: key.n, e: key.e, d: key.d)
    ///
    /// - throws: `CryptoError` if key generation fails.
    public static func components(n: String, e: String, d: String? = nil) throws -> RSAKey {
        func parseBignum(_ s: String) -> UnsafeMutablePointer<BIGNUM>? {
            return Data(base64URLEncoded: s)?.withByteBuffer { p in
                return BN_bin2bn(p.baseAddress, Int32(p.count), nil)
            }
        }
        
        guard let rsa = RSA_new() else {
            throw CryptoError.openssl(identifier: "rsaNull", reason: "RSA key creation failed")
        }
        
        rsa.pointee.n = parseBignum(n)
        rsa.pointee.e = parseBignum(e)
        
        if let d = d {
            rsa.pointee.d = parseBignum(d)
            return try .init(type: .private, key: CRSAKey(rsa))
        } else {
            return try .init(type: .public, key: CRSAKey(rsa))
        }
    }
}

/// Supported RSA key types.
public enum RSAKeyType {
    /// A public RSA key. Used for verifying signatures.
    case `public`
    /// A private RSA key. Used for creating and verifying signatures.
    case `private`
}

/// Reference pointer to an OpenSSL rsa_st key.
/// This wrapper is important for ensuring the key is freed when it is no longer in use.
final class CRSAKey {
    /// The wrapped pointer.
    let pointer: UnsafeMutablePointer<rsa_st>

    /// Creates a new `CRSAKey` from a pointer.
    internal init(_ pointer: UnsafeMutablePointer<rsa_st>) {
        self.pointer = pointer
    }

    /// Creates a new `CRSAKey` from type, data. Specifying `x509` true will treat the data as a certificate.
    static func make(type: RSAKeyType, from data: Data, x509: Bool = false) throws -> CRSAKey {
        let bio = BIO_new(BIO_s_mem())
        defer { BIO_free(bio) }

        let nullTerminatedData = data + Data(bytes: [0])
        _ = nullTerminatedData.withUnsafeBytes { key in
            return BIO_puts(bio, key)
        }

        let maybePkey: UnsafeMutablePointer<EVP_PKEY>?

        if x509 {
            guard let x509 = PEM_read_bio_X509(bio, nil, nil, nil) else {
                throw CryptoError.openssl(identifier: "rsax509", reason: "Key creation from certificate failed")
            }

            defer { X509_free(x509) }
            maybePkey = X509_get_pubkey(x509)
        } else {
            switch type {
            case .public: maybePkey = PEM_read_bio_PUBKEY(bio, nil, nil, nil)
            case .private: maybePkey = PEM_read_bio_PrivateKey(bio, nil, nil, nil)
            }
        }

        guard let pkey = maybePkey else {
            throw CryptoError.openssl(identifier: "rsaPkeyNull", reason: "RSA key creation failed")
        }
        defer { EVP_PKEY_free(pkey) }

        guard let rsa = EVP_PKEY_get1_RSA(pkey) else {
            throw CryptoError.openssl(identifier: "rsaPkeyGet1", reason: "RSA key creation failed")
        }
        return .init(rsa)
    }

    deinit { RSA_free(pointer) }
}
