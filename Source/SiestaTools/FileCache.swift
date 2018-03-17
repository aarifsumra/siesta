//
//  FileCache.swift
//  Siesta
//
//  Created by Paul on 2017/11/22.
//  Copyright © 2017 Bust Out Solutions. All rights reserved.
//

#if COCOAPODS
    import CommonCryptoModule
#else
    import Siesta
    import CommonCrypto
#endif

private typealias File = URL

private let fileCacheFormatVersion: [UInt8] = [0]

private let decoder = PropertyListDecoder()
private let encoder: PropertyListEncoder =
    {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return encoder
    }()

public struct FileCache<ContentType>: EntityCache
    where ContentType: Codable
    {
    private let keyPrefix: Data
    private let cacheDir: File

    public init(poolName: String = "Default", partition: PartitioningStrategy) throws
        {
        let cacheDir = try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "")  // no bundle → directly inside cache dir
            .appendingPathComponent("Siesta")
            .appendingPathComponent(poolName)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        self.init(inDirectory: cacheDir, partition: partition)
        }

    public init(inDirectory cacheDir: URL, partition: PartitioningStrategy)
        {
        self.cacheDir = cacheDir
        keyPrefix =
            fileCacheFormatVersion  // prevents us from parsing old cache entries using some new future format
             + partition.data       // prevents one user from seeing another’s cached requests
             + [0]                  // separator for URL
        }

    public struct PartitioningStrategy
        {
        fileprivate let data: Data

        public static var sharedByAllUsers: PartitioningStrategy
            { return PartitioningStrategy(data: Data()) }

        public static func perUser<T>(identifiedBy partitionID: T) throws -> PartitioningStrategy
            where T: Codable
            {
            return PartitioningStrategy(data:
                try encoder.encode([partitionID])
                    .shortenWithSHA256)
            }
        }

    // MARK: - Keys and filenames

    public func key(for resource: Resource) -> Key?
        { return Key(resource: resource, prefix: keyPrefix) }

    public struct Key: CustomStringConvertible
        {
        fileprivate var url, hash: String

        fileprivate init(resource: Resource, prefix: Data)
            {
            url = resource.url.absoluteString
            hash = Data(prefix + url.utf8)
                .sha256
                .urlSafeBase64EncodedString
            }

        public var description: String
            { return "FileCache.Key(\(url))" }
        }

    private func file(for key: Key) -> File
        { return cacheDir.appendingPathComponent(key.hash + ".plist") }

    // MARK: - Reading and writing

    public func readEntity(forKey key: Key) throws -> Entity<ContentType>?
        {
        do  {
            return try
                decoder.decode(EncodableEntity<ContentType>.self,
                    from: Data(contentsOf: file(for: key)))
                .entity
            }
        catch CocoaError.fileReadNoSuchFile
            { }  // a cache miss is just fine; don't log it
        return nil
        }

    public func writeEntity(_ entity: Entity<ContentType>, forKey key: Key) throws
        {
        try encoder.encode(EncodableEntity(entity))
            .write(to: file(for: key), options: [.atomic, .completeFileProtection])
        }

    public func removeEntity(forKey key: Key) throws
        {
        try FileManager.default.removeItem(at: file(for: key))
        }
    }

/// Ideally, Entity itself would be codable when its ContentType is codable. To do this, Swift would need to:
///
///   1. allow conditional conformance, and
///   2. allow extensions to synthesize encode/decode.
///
/// This struct is a stopgap until the language can do all that.
///
private struct EncodableEntity<ContentType>: Codable
    where ContentType: Codable
    {
    var timestamp: TimeInterval
    var headers: [String:String]
    var charset: String?
    var content: ContentType

    init(_ entity: Entity<ContentType>)
        {
        timestamp = entity.timestamp
        headers = entity.headers
        charset = entity.charset
        content = entity.content
        }

    var entity: Entity<ContentType>
        { return Entity(content: content, charset: charset, headers: headers, timestamp: timestamp) }
    }

private extension Data
    {
    var sha256: Data
        {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = withUnsafeBytes
            { CC_SHA256($0, CC_LONG(count), &hash) }
        return Data(hash)
        }

    var shortenWithSHA256: Data
        {
        return count > 32 ? sha256 : self
        }

    var urlSafeBase64EncodedString: String
        {
        return base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        }
    }
