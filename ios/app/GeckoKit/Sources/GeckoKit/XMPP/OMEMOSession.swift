import COMEMO
import CommonCrypto
import CryptoKit
import Foundation
import GRDB
import Security

struct OMEMOError: Error, Equatable {
    let code: Int32
    let step: String
}

/// libomemo-c's Signal sessions for one account, with its key material in
/// `GeckoStore` (as the Vala core left it, or freshly made). Legacy OMEMO
/// (eu.siacs.conversations.axolotl, protocol version 3) only. Not
/// thread-safe: use from one actor.
final class OMEMOSession {
    /// A contact device's published keys (XEP-0384 §4.3).
    struct Bundle: Equatable {
        var identityKey: Data
        var signedPreKeyID: UInt32
        var signedPreKey: Data
        var signature: Data
        var preKeys: [UInt32: Data]
    }

    /// The trust callback's question: may this device's identity key be used?
    typealias Trust = (_ jid: String, _ device: UInt32, _ identityKey: Data) -> Bool

    let account: String
    private(set) var deviceID: UInt32 = 0
    private let storage: Storage
    private var context: OpaquePointer?
    private var stores: OpaquePointer?

    /// How many unused pre-keys our bundle offers.
    static let preKeyCount = 100

    /// Opens the account's identity, creating one (device id, identity key,
    /// signed pre-key, pre-keys) the first time.
    init(store: GeckoStore, account: String, trust: @escaping Trust) throws {
        self.account = account
        storage = Storage(store: store, account: account, trust: trust)
        try check(signal_context_create(&context, nil), "context")
        var crypto = Self.crypto
        try check(signal_context_set_crypto_provider(context, &crypto), "crypto")
        try check(signal_protocol_store_context_create(&stores, context), "stores")
        try installStores()
        if let identity = try storage.identity() {
            deviceID = identity.deviceID
        } else {
            try createIdentity()
        }
        try refillPreKeys()
    }

    deinit {
        signal_protocol_store_context_destroy(stores)
        signal_context_destroy(context)
    }

    // MARK: Our keys

    var identityKey: Data { (try? storage.identity())?.publicKey ?? Data() }

    /// What to publish as our bundle.
    func bundle() throws -> Bundle {
        let signed = try storage.store.db.read { db in
            try Data.fetchOne(db, sql: """
                SELECT record FROM omemoPreKey WHERE account = ? AND signed ORDER BY id DESC LIMIT 1
                """, arguments: [account])
        }
        guard let signed else { throw OMEMOError(code: SG_ERR_INVALID_KEY_ID, step: "signed pre-key") }
        var record: OpaquePointer?
        try signed.withUnsafeBytes {
            try check(session_signed_pre_key_deserialize(&record, $0.bindMemory(to: UInt8.self).baseAddress,
                                                         signed.count, context), "signed pre-key")
        }
        defer { unref(record) }
        let signature = Data(bytes: session_signed_pre_key_get_signature(record),
                             count: session_signed_pre_key_get_signature_len(record))
        var bundle = Bundle(identityKey: identityKey, signedPreKeyID: session_signed_pre_key_get_id(record),
                            signedPreKey: try publicKey(of: session_signed_pre_key_get_key_pair(record)),
                            signature: signature, preKeys: [:])
        let preKeys = try storage.store.db.read { db in
            try Data.fetchAll(db, sql: "SELECT record FROM omemoPreKey WHERE account = ? AND NOT signed",
                              arguments: [account])
        }
        for data in preKeys {
            var preKey: OpaquePointer?
            let status = data.withUnsafeBytes {
                session_pre_key_deserialize(&preKey, $0.bindMemory(to: UInt8.self).baseAddress, data.count, context)
            }
            guard status == SG_SUCCESS else { continue }
            bundle.preKeys[session_pre_key_get_id(preKey)] = try publicKey(of: session_pre_key_get_key_pair(preKey))
            unref(preKey)
        }
        return bundle
    }

    /// Tops the pre-keys back up after some were used; true when it made new ones
    /// (the bundle needs publishing again).
    @discardableResult
    func refillPreKeys() throws -> Bool {
        let (count, highest) = try storage.store.db.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT count(*) AS n, coalesce(max(id), 0) AS top FROM omemoPreKey WHERE account = ? AND NOT signed
                """, arguments: [account])
            return (row?["n"] as Int? ?? 0, row?["top"] as Int64? ?? 0)
        }
        guard count < Self.preKeyCount else { return false }
        var head: OpaquePointer?
        // Pre-key ids are 24-bit in the Signal protocol; start after the highest.
        let start = UInt32((highest % 0xFF_FFF0) + 1)
        try check(signal_protocol_key_helper_generate_pre_keys(&head, start, UInt32(Self.preKeyCount - count), context),
                  "pre-keys")
        defer { signal_protocol_key_helper_key_list_free(head) }
        var node = head
        try storage.store.db.write { db in
            while let current = node {
                let preKey = signal_protocol_key_helper_key_list_element(current)
                var buffer: OpaquePointer?
                guard session_pre_key_serialize(&buffer, preKey) == SG_SUCCESS else { break }
                try db.execute(sql: "INSERT OR REPLACE INTO omemoPreKey (account, id, record, signed) VALUES (?, ?, ?, 0)",
                               arguments: [account, Int64(session_pre_key_get_id(preKey)), take(buffer)])
                node = signal_protocol_key_helper_key_list_next(current)
            }
        }
        return true
    }

    private func createIdentity() throws {
        var pair: OpaquePointer?
        try check(signal_protocol_key_helper_generate_identity_key_pair(&pair, context), "identity")
        defer { unref(pair) }
        var publicBuffer: OpaquePointer?, privateBuffer: OpaquePointer?
        try check(ec_public_key_serialize(&publicBuffer, ratchet_identity_key_pair_get_public(pair)), "public key")
        try check(ec_private_key_serialize(&privateBuffer, ratchet_identity_key_pair_get_private(pair)), "private key")
        // Device ids are 31-bit and never 0 (XEP-0384 §5.3.1).
        deviceID = UInt32.random(in: 1...0x7FFF_FFFF)
        var signed: OpaquePointer?
        try check(signal_protocol_key_helper_generate_signed_pre_key(
            &signed, pair, 1, UInt64(Date().timeIntervalSince1970 * 1000), context), "signed pre-key")
        defer { unref(signed) }
        var signedBuffer: OpaquePointer?
        try check(session_signed_pre_key_serialize(&signedBuffer, signed), "signed pre-key")
        let (publicKey, privateKey, record) = (take(publicBuffer), take(privateBuffer), take(signedBuffer))
        try storage.store.db.write { db in
            try db.execute(sql: "INSERT INTO omemoIdentity (account, deviceID, publicKey, privateKey) VALUES (?, ?, ?, ?)",
                           arguments: [account, Int64(deviceID), publicKey, privateKey])
            try db.execute(sql: "INSERT OR REPLACE INTO omemoPreKey (account, id, record, signed) VALUES (?, 1, ?, 1)",
                           arguments: [account, record])
        }
    }

    // MARK: Sessions

    func hasSession(_ jid: String, _ device: UInt32) -> Bool {
        withAddress(jid, device) { signal_protocol_session_contains_session(stores, $0) == 1 }
    }

    /// Starts a session with a device from its bundle, using one of its pre-keys at random.
    func startSession(_ jid: String, _ device: UInt32, bundle: Bundle) throws {
        guard let (preKeyID, preKeyData) = bundle.preKeys.randomElement() else {
            throw OMEMOError(code: SG_ERR_INVALID_KEY, step: "bundle without pre-keys")
        }
        let preKey = try decodePoint(preKeyData), signedPreKey = try decodePoint(bundle.signedPreKey)
        let identity = try decodePoint(bundle.identityKey)
        defer { [preKey, signedPreKey, identity].forEach(unref) }
        var remote: OpaquePointer?
        try bundle.signature.withUnsafeBytes {
            try check(session_pre_key_bundle_create(
                &remote, 0, Int32(bitPattern: device), preKeyID, preKey, bundle.signedPreKeyID, signedPreKey,
                $0.bindMemory(to: UInt8.self).baseAddress, bundle.signature.count, identity), "bundle")
        }
        defer { unref(remote) }
        try withAddress(jid, device) { address in
            var builder: OpaquePointer?
            try check(session_builder_create(&builder, stores, address, context), "builder")
            defer { session_builder_free(builder) }
            session_builder_set_version(builder, UInt32(CIPHERTEXT_CURRENT_VERSION))
            try check(session_builder_process_pre_key_bundle(builder, remote), "process bundle")
        }
    }

    /// Encrypts a message key for one device; `preKey` when the session is
    /// not confirmed yet (the receiver has to set it up from it).
    func encrypt(_ key: Data, for jid: String, _ device: UInt32) throws -> (data: Data, preKey: Bool) {
        try withAddress(jid, device) { address in
            var cipher: OpaquePointer?
            try check(session_cipher_create(&cipher, stores, address, context), "cipher")
            defer { session_cipher_free(cipher) }
            session_cipher_set_version(cipher, UInt32(CIPHERTEXT_CURRENT_VERSION))
            var message: OpaquePointer?
            try key.withUnsafeBytes {
                try check(session_cipher_encrypt(cipher, $0.bindMemory(to: UInt8.self).baseAddress, key.count, &message),
                          "encrypt")
            }
            defer { unref(message) }
            let serialized = ciphertext_message_get_serialized(message)
            return (Data(bytes: signal_buffer_data(serialized), count: signal_buffer_len(serialized)),
                    ciphertext_message_get_type(message) == CIPHERTEXT_PREKEY_TYPE)
        }
    }

    /// Decrypts the message key a device sent us.
    func decrypt(_ data: Data, preKey: Bool, from jid: String, _ device: UInt32) throws -> Data {
        try withAddress(jid, device) { address in
            var cipher: OpaquePointer?
            try check(session_cipher_create(&cipher, stores, address, context), "cipher")
            defer { session_cipher_free(cipher) }
            session_cipher_set_version(cipher, UInt32(CIPHERTEXT_CURRENT_VERSION))
            var plain: OpaquePointer?
            try data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self).baseAddress
                var message: OpaquePointer?
                if preKey {
                    try check(pre_key_signal_message_deserialize(&message, bytes, data.count, context), "read pre-key message")
                    defer { unref(message) }
                    try check(session_cipher_decrypt_pre_key_signal_message(cipher, message, nil, &plain), "decrypt")
                } else {
                    try check(signal_message_deserialize(&message, bytes, data.count, context), "read message")
                    defer { unref(message) }
                    try check(session_cipher_decrypt_signal_message(cipher, message, nil, &plain), "decrypt")
                }
            }
            return take(plain)
        }
    }

    // MARK: libomemo-c plumbing

    private func check(_ status: Int32, _ step: String) throws {
        guard status >= SG_SUCCESS else { throw OMEMOError(code: status, step: step) }
    }

    private func withAddress<T>(_ jid: String, _ device: UInt32,
                                _ body: (UnsafePointer<signal_protocol_address>) throws -> T) rethrows -> T {
        try jid.withCString { name in
            var address = signal_protocol_address(name: name, name_len: strlen(name), device_id: Int32(bitPattern: device))
            return try body(&address)
        }
    }

    private func decodePoint(_ data: Data) throws -> OpaquePointer? {
        var key: OpaquePointer?
        try data.withUnsafeBytes {
            try check(curve_decode_point(&key, $0.bindMemory(to: UInt8.self).baseAddress, data.count, context), "key")
        }
        return key
    }

    private func publicKey(of pair: OpaquePointer?) throws -> Data {
        var buffer: OpaquePointer?
        try check(ec_public_key_serialize(&buffer, ec_key_pair_get_public(pair)), "public key")
        return take(buffer)
    }

    private func installStores() throws {
        let user = Unmanaged.passUnretained(storage).toOpaque()
        var sessions = signal_protocol_session_store()
        sessions.user_data = user
        sessions.load_session_func = { record, userRecord, address, user in
            let storage = Storage.from(user)
            guard let address, let data = storage.session(address.pointee) else { return 0 }
            record?.pointee = signalBuffer(data)
            userRecord?.pointee = nil
            return 1
        }
        sessions.get_sub_device_sessions_func = { list, name, length, user in
            let devices = Storage.from(user).devices(cText(name, length))
            let result = signal_int_list_alloc()
            devices.forEach { signal_int_list_push_back(result, Int32(bitPattern: $0)) }
            list?.pointee = result
            return Int32(devices.count)
        }
        sessions.store_session_func = { address, record, length, _, _, user in
            Storage.from(user).storeSession(address!.pointee, Data(bytes: record!, count: length))
        }
        sessions.contains_session_func = { address, user in
            Storage.from(user).session(address!.pointee) == nil ? 0 : 1
        }
        sessions.delete_session_func = { address, user in
            Storage.from(user).deleteSessions(address!.pointee.jid, device: UInt32(bitPattern: address!.pointee.device_id))
        }
        sessions.delete_all_sessions_func = { name, length, user in
            Storage.from(user).deleteSessions(cText(name, length), device: nil)
        }
        try check(signal_protocol_store_context_set_session_store(stores, &sessions), "session store")

        var preKeys = signal_protocol_pre_key_store()
        preKeys.user_data = user
        preKeys.load_pre_key = { record, id, user in Storage.from(user).loadPreKey(id, signed: false, into: record) }
        preKeys.store_pre_key = { id, record, length, user in
            Storage.from(user).storePreKey(id, signed: false, Data(bytes: record!, count: length))
        }
        preKeys.contains_pre_key = { id, user in Storage.from(user).containsPreKey(id, signed: false) }
        preKeys.remove_pre_key = { id, user in Storage.from(user).removePreKey(id, signed: false) }
        try check(signal_protocol_store_context_set_pre_key_store(stores, &preKeys), "pre-key store")

        var signedPreKeys = signal_protocol_signed_pre_key_store()
        signedPreKeys.user_data = user
        signedPreKeys.load_signed_pre_key = { record, id, user in Storage.from(user).loadPreKey(id, signed: true, into: record) }
        signedPreKeys.store_signed_pre_key = { id, record, length, user in
            Storage.from(user).storePreKey(id, signed: true, Data(bytes: record!, count: length))
        }
        signedPreKeys.contains_signed_pre_key = { id, user in Storage.from(user).containsPreKey(id, signed: true) }
        signedPreKeys.remove_signed_pre_key = { id, user in Storage.from(user).removePreKey(id, signed: true) }
        try check(signal_protocol_store_context_set_signed_pre_key_store(stores, &signedPreKeys), "signed pre-key store")

        var identities = signal_protocol_identity_key_store()
        identities.user_data = user
        identities.get_identity_key_pair = { publicData, privateData, user in
            guard let identity = try? Storage.from(user).identity() else { return SG_ERR_INVALID_KEY }
            publicData?.pointee = signalBuffer(identity.publicKey)
            privateData?.pointee = signalBuffer(identity.privateKey)
            return SG_SUCCESS
        }
        identities.get_local_registration_id = { user, id in
            guard let identity = try? Storage.from(user).identity() else { return SG_ERR_INVALID_KEY }
            // OMEMO uses the device id where Signal has a registration id.
            id?.pointee = identity.deviceID
            return SG_SUCCESS
        }
        identities.save_identity = { address, key, length, user in
            Storage.from(user).saveIdentity(address!.pointee, key.map { Data(bytes: $0, count: length) })
        }
        identities.is_trusted_identity = { address, key, length, user in
            Storage.from(user).isTrusted(address!.pointee, Data(bytes: key!, count: length)) ? 1 : 0
        }
        try check(signal_protocol_store_context_set_identity_key_store(stores, &identities), "identity store")
    }

    /// What the store callbacks act on. Unowned by libomemo-c: the session
    /// keeps it alive for as long as the store context exists.
    private final class Storage {
        let store: GeckoStore
        let account: String
        let trust: Trust

        init(store: GeckoStore, account: String, trust: @escaping Trust) {
            self.store = store
            self.account = account
            self.trust = trust
        }

        static func from(_ user: UnsafeMutableRawPointer?) -> Storage {
            Unmanaged<Storage>.fromOpaque(user!).takeUnretainedValue()
        }

        func identity() throws -> (deviceID: UInt32, publicKey: Data, privateKey: Data)? {
            try store.db.read { db in
                try Row.fetchOne(db, sql: "SELECT * FROM omemoIdentity WHERE account = ?", arguments: [account]).map {
                    (UInt32(truncatingIfNeeded: $0["deviceID"] as Int64), $0["publicKey"], $0["privateKey"])
                }
            }
        }

        func session(_ address: signal_protocol_address) -> Data? {
            try? store.db.read { db in
                try Data.fetchOne(db, sql: "SELECT record FROM omemoSession WHERE account = ? AND jid = ? AND device = ?",
                                  arguments: [account, address.jid, Int64(UInt32(bitPattern: address.device_id))])
            }
        }

        func devices(_ jid: String) -> [UInt32] {
            (try? store.db.read { db in
                try Int64.fetchAll(db, sql: "SELECT device FROM omemoSession WHERE account = ? AND jid = ?",
                                   arguments: [account, jid])
            })?.map { UInt32(truncatingIfNeeded: $0) } ?? []
        }

        func storeSession(_ address: signal_protocol_address, _ record: Data) -> Int32 {
            result {
                try store.db.write { db in
                    try db.execute(sql: "INSERT OR REPLACE INTO omemoSession (account, jid, device, record) VALUES (?, ?, ?, ?)",
                                   arguments: [account, address.jid, Int64(UInt32(bitPattern: address.device_id)), record])
                }
            }
        }

        func deleteSessions(_ jid: String, device: UInt32?) -> Int32 {
            result {
                try store.db.write { db in
                    try db.execute(sql: "DELETE FROM omemoSession WHERE account = ? AND jid = ? AND (? IS NULL OR device = ?)",
                                   arguments: [account, jid, device.map { Int64($0) }, device.map { Int64($0) }])
                }
            }
        }

        func loadPreKey(_ id: UInt32, signed: Bool, into record: UnsafeMutablePointer<OpaquePointer?>?) -> Int32 {
            guard let data = try? store.db.read({ db in
                try Data.fetchOne(db, sql: "SELECT record FROM omemoPreKey WHERE account = ? AND id = ? AND signed = ?",
                                  arguments: [account, Int64(id), signed])
            }) ?? nil else { return SG_ERR_INVALID_KEY_ID }
            record?.pointee = signalBuffer(data)
            return SG_SUCCESS
        }

        func storePreKey(_ id: UInt32, signed: Bool, _ record: Data) -> Int32 {
            result {
                try store.db.write { db in
                    try db.execute(sql: "INSERT OR REPLACE INTO omemoPreKey (account, id, record, signed) VALUES (?, ?, ?, ?)",
                                   arguments: [account, Int64(id), record, signed])
                }
            }
        }

        func containsPreKey(_ id: UInt32, signed: Bool) -> Int32 {
            ((try? store.db.read { db in
                try Bool.fetchOne(db, sql: "SELECT 1 FROM omemoPreKey WHERE account = ? AND id = ? AND signed = ?",
                                  arguments: [account, Int64(id), signed])
            }) ?? nil) == true ? 1 : 0
        }

        func removePreKey(_ id: UInt32, signed: Bool) -> Int32 {
            result {
                try store.db.write { db in
                    try db.execute(sql: "DELETE FROM omemoPreKey WHERE account = ? AND id = ? AND signed = ?",
                                   arguments: [account, Int64(id), signed])
                }
            }
        }

        func saveIdentity(_ address: signal_protocol_address, _ key: Data?) -> Int32 {
            result {
                try store.db.write { db in
                    try db.execute(sql: """
                        INSERT INTO omemoDevice (account, jid, device, identityKey, lastSeen) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(account, jid, device) DO UPDATE SET identityKey = excluded.identityKey,
                            lastSeen = excluded.lastSeen
                        """, arguments: [account, address.jid, Int64(UInt32(bitPattern: address.device_id)), key, Date()])
                }
            }
        }

        func isTrusted(_ address: signal_protocol_address, _ key: Data) -> Bool {
            trust(address.jid, UInt32(bitPattern: address.device_id), key)
        }

        private func result(_ body: () throws -> Void) -> Int32 {
            (try? body()) == nil ? SG_ERR_UNKNOWN : SG_SUCCESS
        }
    }

    /// Random bytes, HMAC-SHA256, SHA-512 and AES (CBC with PKCS#7, CTR) for
    /// libomemo-c, from CryptoKit, CommonCrypto and the system RNG.
    private static let crypto: signal_crypto_provider = {
        var provider = signal_crypto_provider()
        provider.random_func = { data, length, _ in
            SecRandomCopyBytes(kSecRandomDefault, length, data!) == errSecSuccess ? SG_SUCCESS : SG_ERR_UNKNOWN
        }
        provider.hmac_sha256_init_func = { context, key, length, _ in
            let mac = Box(HMAC<SHA256>(key: SymmetricKey(data: Data(bytes: key!, count: length))))
            context?.pointee = Unmanaged.passRetained(mac).toOpaque()
            return SG_SUCCESS
        }
        provider.hmac_sha256_update_func = { context, data, length, _ in
            Box<HMAC<SHA256>>.from(context).value.update(data: UnsafeRawBufferPointer(start: data, count: length))
            return SG_SUCCESS
        }
        provider.hmac_sha256_final_func = { context, output, _ in
            output?.pointee = signalBuffer(Data(Box<HMAC<SHA256>>.from(context).value.finalize()))
            return SG_SUCCESS
        }
        provider.hmac_sha256_cleanup_func = { context, _ in
            if let context { Unmanaged<Box<HMAC<SHA256>>>.fromOpaque(context).release() }
        }
        provider.sha512_digest_init_func = { context, _ in
            context?.pointee = Unmanaged.passRetained(Box(SHA512())).toOpaque()
            return SG_SUCCESS
        }
        provider.sha512_digest_update_func = { context, data, length, _ in
            Box<SHA512>.from(context).value.update(data: UnsafeRawBufferPointer(start: data, count: length))
            return SG_SUCCESS
        }
        provider.sha512_digest_final_func = { context, output, _ in
            let box = Box<SHA512>.from(context)
            output?.pointee = signalBuffer(Data(box.value.finalize()))
            box.value = SHA512()  // libomemo-c may reuse the context
            return SG_SUCCESS
        }
        provider.sha512_digest_cleanup_func = { context, _ in
            if let context { Unmanaged<Box<SHA512>>.fromOpaque(context).release() }
        }
        provider.encrypt_func = { output, cipher, key, keyLength, iv, ivLength, input, length, _ in
            aes(CCOperation(kCCEncrypt), cipher, key, keyLength, iv, input, length, output)
        }
        provider.decrypt_func = { output, cipher, key, keyLength, iv, ivLength, input, length, _ in
            aes(CCOperation(kCCDecrypt), cipher, key, keyLength, iv, input, length, output)
        }
        return provider
    }()
}

/// A mutable value libomemo-c holds by pointer between calls.
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }

    static func from(_ pointer: UnsafeMutableRawPointer?) -> Box {
        Unmanaged<Box>.fromOpaque(pointer!).takeUnretainedValue()
    }
}

// swiftlint:disable:next function_parameter_count
private func aes(_ operation: CCOperation, _ cipher: Int32, _ key: UnsafePointer<UInt8>?, _ keyLength: Int,
                 _ iv: UnsafePointer<UInt8>?, _ input: UnsafePointer<UInt8>?, _ length: Int,
                 _ output: UnsafeMutablePointer<OpaquePointer?>?) -> Int32 {
    var out = [UInt8](repeating: 0, count: length + kCCBlockSizeAES128)
    var moved = 0
    var status: CCCryptorStatus
    if cipher == SG_CIPHER_AES_CBC_PKCS5 {
        status = CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key, keyLength, iv,
                         input, length, &out, out.count, &moved)
    } else if cipher == SG_CIPHER_AES_CTR_NOPADDING {
        var cryptor: CCCryptorRef?
        status = CCCryptorCreateWithMode(operation, CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                         CCPadding(ccNoPadding), iv, key, keyLength, nil, 0, 0,
                                         CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        if status == kCCSuccess {
            status = CCCryptorUpdate(cryptor, input, length, &out, out.count, &moved)
            CCCryptorRelease(cryptor)
        }
    } else {
        return SG_ERR_UNKNOWN
    }
    guard status == kCCSuccess else { return SG_ERR_UNKNOWN }
    output?.pointee = signalBuffer(Data(out.prefix(moved)))
    return SG_SUCCESS
}

private func signalBuffer(_ data: Data) -> OpaquePointer? {
    data.withUnsafeBytes { signal_buffer_create($0.bindMemory(to: UInt8.self).baseAddress, data.count) }
}

/// The bytes of a buffer libomemo-c handed over, which is then freed.
private func take(_ buffer: OpaquePointer?) -> Data {
    guard let buffer else { return Data() }
    defer { signal_buffer_free(buffer) }
    return Data(bytes: signal_buffer_data(buffer), count: signal_buffer_len(buffer))
}

private func unref(_ object: OpaquePointer?) {
    if let object { signal_type_unref(object) }
}

private extension signal_protocol_address {
    var jid: String { cText(name, name_len) }
}

/// A C string of known length (libomemo-c does not terminate its names).
private func cText(_ text: UnsafePointer<CChar>?, _ length: Int) -> String {
    String(decoding: UnsafeRawBufferPointer(start: text, count: length), as: UTF8.self)
}
