import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class RocksDBNative {
    static var tuningMetadata: [String: Any] {
        [
            "write_buffer_size": 64 * 1024 * 1024,
            "max_write_buffer_number": 4,
            "max_background_jobs": 4,
            "max_open_files": -1,
            "increase_parallelism": 4,
            "reusable_read_options": true,
            "reusable_write_options": true,
            "wal_disabled": false
        ]
    }

    private typealias OptionsCreate = @convention(c) () -> OpaquePointer?
    private typealias OptionsDestroy = @convention(c) (OpaquePointer?) -> Void
    private typealias OptionsSetCreateIfMissing = @convention(c) (OpaquePointer?, UInt8) -> Void
    private typealias OptionsSetWriteBufferSize = @convention(c) (OpaquePointer?, Int) -> Void
    private typealias OptionsSetMaxWriteBufferNumber = @convention(c) (OpaquePointer?, Int32) -> Void
    private typealias OptionsSetMaxBackgroundJobs = @convention(c) (OpaquePointer?, Int32) -> Void
    private typealias OptionsSetMaxOpenFiles = @convention(c) (OpaquePointer?, Int32) -> Void
    private typealias OptionsIncreaseParallelism = @convention(c) (OpaquePointer?, Int32) -> Void
    private typealias Open = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> OpaquePointer?
    private typealias Close = @convention(c) (OpaquePointer?) -> Void
    private typealias ReadOptionsCreate = @convention(c) () -> OpaquePointer?
    private typealias ReadOptionsDestroy = @convention(c) (OpaquePointer?) -> Void
    private typealias WriteOptionsCreate = @convention(c) () -> OpaquePointer?
    private typealias WriteOptionsDestroy = @convention(c) (OpaquePointer?) -> Void
    private typealias Put = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafePointer<CChar>?, Int, UnsafePointer<CChar>?, Int, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    private typealias Get = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafePointer<CChar>?, Int, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UnsafeMutablePointer<CChar>?
    private typealias MultiGet = @convention(c) (OpaquePointer?, OpaquePointer?, Int, UnsafeMutablePointer<UnsafePointer<CChar>?>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    private typealias Delete = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafePointer<CChar>?, Int, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    private typealias WriteBatchCreate = @convention(c) () -> OpaquePointer?
    private typealias WriteBatchDestroy = @convention(c) (OpaquePointer?) -> Void
    private typealias WriteBatchPut = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int, UnsafePointer<CChar>?, Int) -> Void
    private typealias WriteBatchDelete = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Void
    private typealias Write = @convention(c) (OpaquePointer?, OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    private typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private struct API {
        let handle: UnsafeMutableRawPointer
        let optionsCreate: OptionsCreate
        let optionsDestroy: OptionsDestroy
        let optionsSetCreateIfMissing: OptionsSetCreateIfMissing
        let optionsSetWriteBufferSize: OptionsSetWriteBufferSize?
        let optionsSetMaxWriteBufferNumber: OptionsSetMaxWriteBufferNumber?
        let optionsSetMaxBackgroundJobs: OptionsSetMaxBackgroundJobs?
        let optionsSetMaxOpenFiles: OptionsSetMaxOpenFiles?
        let optionsIncreaseParallelism: OptionsIncreaseParallelism?
        let open: Open
        let close: Close
        let readOptionsCreate: ReadOptionsCreate
        let readOptionsDestroy: ReadOptionsDestroy
        let writeOptionsCreate: WriteOptionsCreate
        let writeOptionsDestroy: WriteOptionsDestroy
        let put: Put
        let get: Get
        let multiGet: MultiGet?
        let delete: Delete
        let writeBatchCreate: WriteBatchCreate
        let writeBatchDestroy: WriteBatchDestroy
        let writeBatchPut: WriteBatchPut
        let writeBatchDelete: WriteBatchDelete
        let write: Write
        let free: Free

        static func load() -> API? {
            for name in ["librocksdb.so", "librocksdb.so.7", "librocksdb.dylib"] {
                guard let handle = dlopen(name, RTLD_NOW) else { continue }
                guard
                    let optionsCreate = symbol(handle, "rocksdb_options_create", OptionsCreate.self),
                    let optionsDestroy = symbol(handle, "rocksdb_options_destroy", OptionsDestroy.self),
                    let optionsSetCreateIfMissing = symbol(handle, "rocksdb_options_set_create_if_missing", OptionsSetCreateIfMissing.self),
                    let open = symbol(handle, "rocksdb_open", Open.self),
                    let close = symbol(handle, "rocksdb_close", Close.self),
                    let readOptionsCreate = symbol(handle, "rocksdb_readoptions_create", ReadOptionsCreate.self),
                    let readOptionsDestroy = symbol(handle, "rocksdb_readoptions_destroy", ReadOptionsDestroy.self),
                    let writeOptionsCreate = symbol(handle, "rocksdb_writeoptions_create", WriteOptionsCreate.self),
                    let writeOptionsDestroy = symbol(handle, "rocksdb_writeoptions_destroy", WriteOptionsDestroy.self),
                    let put = symbol(handle, "rocksdb_put", Put.self),
                    let get = symbol(handle, "rocksdb_get", Get.self),
                    let delete = symbol(handle, "rocksdb_delete", Delete.self),
                    let writeBatchCreate = symbol(handle, "rocksdb_writebatch_create", WriteBatchCreate.self),
                    let writeBatchDestroy = symbol(handle, "rocksdb_writebatch_destroy", WriteBatchDestroy.self),
                    let writeBatchPut = symbol(handle, "rocksdb_writebatch_put", WriteBatchPut.self),
                    let writeBatchDelete = symbol(handle, "rocksdb_writebatch_delete", WriteBatchDelete.self),
                    let write = symbol(handle, "rocksdb_write", Write.self),
                    let free = symbol(handle, "rocksdb_free", Free.self)
                else {
                    dlclose(handle)
                    continue
                }
                let multiGet = symbol(handle, "rocksdb_multi_get", MultiGet.self)
                return API(
                    handle: handle,
                    optionsCreate: optionsCreate,
                    optionsDestroy: optionsDestroy,
                    optionsSetCreateIfMissing: optionsSetCreateIfMissing,
                    optionsSetWriteBufferSize: symbol(handle, "rocksdb_options_set_write_buffer_size", OptionsSetWriteBufferSize.self),
                    optionsSetMaxWriteBufferNumber: symbol(handle, "rocksdb_options_set_max_write_buffer_number", OptionsSetMaxWriteBufferNumber.self),
                    optionsSetMaxBackgroundJobs: symbol(handle, "rocksdb_options_set_max_background_jobs", OptionsSetMaxBackgroundJobs.self),
                    optionsSetMaxOpenFiles: symbol(handle, "rocksdb_options_set_max_open_files", OptionsSetMaxOpenFiles.self),
                    optionsIncreaseParallelism: symbol(handle, "rocksdb_options_increase_parallelism", OptionsIncreaseParallelism.self),
                    open: open,
                    close: close,
                    readOptionsCreate: readOptionsCreate,
                    readOptionsDestroy: readOptionsDestroy,
                    writeOptionsCreate: writeOptionsCreate,
                    writeOptionsDestroy: writeOptionsDestroy,
                    put: put,
                    get: get,
                    multiGet: multiGet,
                    delete: delete,
                    writeBatchCreate: writeBatchCreate,
                    writeBatchDestroy: writeBatchDestroy,
                    writeBatchPut: writeBatchPut,
                    writeBatchDelete: writeBatchDelete,
                    write: write,
                    free: free
                )
            }
            return nil
        }

        private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
    }

    private let api: API
    private let db: OpaquePointer
    private let readOptions: OpaquePointer
    private let writeOptions: OpaquePointer
    let path: String

    init?(path: String) {
        guard let api = API.load() else { return nil }
        guard let options = api.optionsCreate() else { return nil }
        defer { api.optionsDestroy(options) }
        api.optionsSetCreateIfMissing(options, 1)
        api.optionsSetWriteBufferSize?(options, 64 * 1024 * 1024)
        api.optionsSetMaxWriteBufferNumber?(options, 4)
        api.optionsSetMaxBackgroundJobs?(options, 4)
        api.optionsSetMaxOpenFiles?(options, -1)
        api.optionsIncreaseParallelism?(options, 4)
        var err: UnsafeMutablePointer<CChar>?
        guard let db = api.open(options, path, &err) else {
            if let err { api.free(err) }
            return nil
        }
        guard let readOptions = api.readOptionsCreate(),
              let writeOptions = api.writeOptionsCreate() else {
            api.close(db)
            return nil
        }
        self.api = api
        self.db = db
        self.readOptions = readOptions
        self.writeOptions = writeOptions
        self.path = path
    }

    deinit {
        api.readOptionsDestroy(readOptions)
        api.writeOptionsDestroy(writeOptions)
        api.close(db)
    }

    func put(key: String, value: Data) throws {
        try put(key: Data(key.utf8), value: value)
    }

    func put(key: Data, value: Data) throws {
        var err: UnsafeMutablePointer<CChar>?
        try key.withUnsafeBytes { keyBytes in
            try value.withUnsafeBytes { valueBytes in
                let keyPtr = keyBytes.bindMemory(to: CChar.self).baseAddress
                let valuePtr = valueBytes.bindMemory(to: CChar.self).baseAddress
                api.put(db, writeOptions, keyPtr, key.count, valuePtr, value.count, &err)
                if let err {
                    let message = String(cString: err)
                    api.free(err)
                    throw SwiftBitnodeError.message("rocksdb put failed: \(message)")
                }
            }
        }
    }

    func get(key: String) throws -> Data? {
        try get(key: Data(key.utf8))
    }

    func get(key: Data) throws -> Data? {
        var err: UnsafeMutablePointer<CChar>?
        var length = 0
        let value: UnsafeMutablePointer<CChar>? = key.withUnsafeBytes { keyBytes in
            let keyPtr = keyBytes.bindMemory(to: CChar.self).baseAddress
            return api.get(db, readOptions, keyPtr, key.count, &length, &err)
        }
        if let err {
            let message = String(cString: err)
            api.free(err)
            throw SwiftBitnodeError.message("rocksdb get failed: \(message)")
        }
        guard let value else { return nil }
        defer { api.free(value) }
        return Data(bytes: value, count: length)
    }

    func get(keys: [String]) throws -> [String: Data] {
        let raw = try get(keys: keys.map { Data($0.utf8) })
        var out: [String: Data] = [:]
        for key in keys {
            if let value = raw[Data(key.utf8)] {
                out[key] = value
            }
        }
        return out
    }

    func get(keys: [Data]) throws -> [Data: Data] {
        guard !keys.isEmpty else { return [:] }
        guard let multiGet = api.multiGet else {
            var out: [Data: Data] = [:]
            for key in keys {
                if let value = try get(key: key) {
                    out[key] = value
                }
            }
            return out
        }
        let keyBuffers: [UnsafeMutableRawPointer] = keys.map { key in
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(1, key.count), alignment: 1)
            key.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress, key.count > 0 {
                    pointer.copyMemory(from: base, byteCount: key.count)
                }
            }
            return pointer
        }
        defer {
            for pointer in keyBuffers {
                pointer.deallocate()
            }
        }
        var keyPointers = keyBuffers.map { Optional(UnsafePointer<CChar>($0.assumingMemoryBound(to: CChar.self))) }
        var keySizes = keys.map(\.count)
        var values = Array<UnsafeMutablePointer<CChar>?>(repeating: nil, count: keys.count)
        var valueSizes = Array<Int>(repeating: 0, count: keys.count)
        var errors = Array<UnsafeMutablePointer<CChar>?>(repeating: nil, count: keys.count)
        multiGet(db, readOptions, keys.count, &keyPointers, &keySizes, &values, &valueSizes, &errors)

        var out: [Data: Data] = [:]
        for index in keys.indices {
            if let err = errors[index] {
                let message = String(cString: err)
                api.free(err)
                throw SwiftBitnodeError.message("rocksdb multi_get failed: \(message)")
            }
            if let value = values[index] {
                out[keys[index]] = Data(bytes: value, count: valueSizes[index])
                api.free(value)
            }
        }
        return out
    }

    func delete(key: String) throws {
        try delete(key: Data(key.utf8))
    }

    func delete(key: Data) throws {
        var err: UnsafeMutablePointer<CChar>?
        key.withUnsafeBytes { keyBytes in
            let keyPtr = keyBytes.bindMemory(to: CChar.self).baseAddress
            api.delete(db, writeOptions, keyPtr, key.count, &err)
        }
        if let err {
            let message = String(cString: err)
            api.free(err)
            throw SwiftBitnodeError.message("rocksdb delete failed: \(message)")
        }
    }

    func writeBatch(puts: [(String, Data)], deletes: [String]) throws {
        try writeBatch(
            puts: puts.map { (Data($0.0.utf8), $0.1) },
            deletes: deletes.map { Data($0.utf8) }
        )
    }

    func writeBatch(puts: [(Data, Data)], deletes: [Data]) throws {
        guard let batch = api.writeBatchCreate() else {
            throw SwiftBitnodeError.message("rocksdb write batch allocation failed")
        }
        defer { api.writeBatchDestroy(batch) }
        for (key, value) in puts {
            key.withUnsafeBytes { keyBytes in
                value.withUnsafeBytes { valueBytes in
                    api.writeBatchPut(batch, keyBytes.bindMemory(to: CChar.self).baseAddress, key.count, valueBytes.bindMemory(to: CChar.self).baseAddress, value.count)
                }
            }
        }
        for key in deletes {
            key.withUnsafeBytes { keyBytes in
                api.writeBatchDelete(batch, keyBytes.bindMemory(to: CChar.self).baseAddress, key.count)
            }
        }
        var err: UnsafeMutablePointer<CChar>?
        api.write(db, writeOptions, batch, &err)
        if let err {
            let message = String(cString: err)
            api.free(err)
            throw SwiftBitnodeError.message("rocksdb batch write failed: \(message)")
        }
    }
}
