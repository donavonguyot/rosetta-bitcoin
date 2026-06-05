import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class RocksDBNative {
    private typealias OptionsCreate = @convention(c) () -> OpaquePointer?
    private typealias OptionsDestroy = @convention(c) (OpaquePointer?) -> Void
    private typealias OptionsSetCreateIfMissing = @convention(c) (OpaquePointer?, UInt8) -> Void
    private typealias Open = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> OpaquePointer?
    private typealias Close = @convention(c) (OpaquePointer?) -> Void
    private typealias ReadOptionsCreate = @convention(c) () -> OpaquePointer?
    private typealias ReadOptionsDestroy = @convention(c) (OpaquePointer?) -> Void
    private typealias WriteOptionsCreate = @convention(c) () -> OpaquePointer?
    private typealias WriteOptionsDestroy = @convention(c) (OpaquePointer?) -> Void
    private typealias Put = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafePointer<CChar>?, Int, UnsafePointer<CChar>?, Int, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    private typealias Get = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafePointer<CChar>?, Int, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UnsafeMutablePointer<CChar>?
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
        let open: Open
        let close: Close
        let readOptionsCreate: ReadOptionsCreate
        let readOptionsDestroy: ReadOptionsDestroy
        let writeOptionsCreate: WriteOptionsCreate
        let writeOptionsDestroy: WriteOptionsDestroy
        let put: Put
        let get: Get
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
                return API(handle: handle, optionsCreate: optionsCreate, optionsDestroy: optionsDestroy, optionsSetCreateIfMissing: optionsSetCreateIfMissing, open: open, close: close, readOptionsCreate: readOptionsCreate, readOptionsDestroy: readOptionsDestroy, writeOptionsCreate: writeOptionsCreate, writeOptionsDestroy: writeOptionsDestroy, put: put, get: get, delete: delete, writeBatchCreate: writeBatchCreate, writeBatchDestroy: writeBatchDestroy, writeBatchPut: writeBatchPut, writeBatchDelete: writeBatchDelete, write: write, free: free)
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
    let path: String

    init?(path: String) {
        guard let api = API.load() else { return nil }
        guard let options = api.optionsCreate() else { return nil }
        defer { api.optionsDestroy(options) }
        api.optionsSetCreateIfMissing(options, 1)
        var err: UnsafeMutablePointer<CChar>?
        guard let db = api.open(options, path, &err) else {
            if let err { api.free(err) }
            return nil
        }
        self.api = api
        self.db = db
        self.path = path
    }

    deinit {
        api.close(db)
    }

    func put(key: String, value: Data) throws {
        guard let writeOptions = api.writeOptionsCreate() else {
            throw SwiftBitnodeError.message("rocksdb write options allocation failed")
        }
        defer { api.writeOptionsDestroy(writeOptions) }
        var err: UnsafeMutablePointer<CChar>?
        try key.withCString { keyPtr in
            try value.withUnsafeBytes { valueBytes in
                let valuePtr = valueBytes.bindMemory(to: CChar.self).baseAddress
                api.put(db, writeOptions, keyPtr, strlen(keyPtr), valuePtr, value.count, &err)
                if let err {
                    let message = String(cString: err)
                    api.free(err)
                    throw SwiftBitnodeError.message("rocksdb put failed: \(message)")
                }
            }
        }
    }

    func get(key: String) throws -> Data? {
        guard let readOptions = api.readOptionsCreate() else {
            throw SwiftBitnodeError.message("rocksdb read options allocation failed")
        }
        defer { api.readOptionsDestroy(readOptions) }
        var err: UnsafeMutablePointer<CChar>?
        var length = 0
        let value: UnsafeMutablePointer<CChar>? = key.withCString { keyPtr in
            api.get(db, readOptions, keyPtr, strlen(keyPtr), &length, &err)
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

    func delete(key: String) throws {
        guard let writeOptions = api.writeOptionsCreate() else {
            throw SwiftBitnodeError.message("rocksdb write options allocation failed")
        }
        defer { api.writeOptionsDestroy(writeOptions) }
        var err: UnsafeMutablePointer<CChar>?
        key.withCString { keyPtr in
            api.delete(db, writeOptions, keyPtr, strlen(keyPtr), &err)
        }
        if let err {
            let message = String(cString: err)
            api.free(err)
            throw SwiftBitnodeError.message("rocksdb delete failed: \(message)")
        }
    }

    func writeBatch(puts: [(String, Data)], deletes: [String]) throws {
        guard let batch = api.writeBatchCreate() else {
            throw SwiftBitnodeError.message("rocksdb write batch allocation failed")
        }
        defer { api.writeBatchDestroy(batch) }
        for (key, value) in puts {
            key.withCString { keyPtr in
                value.withUnsafeBytes { valueBytes in
                    api.writeBatchPut(batch, keyPtr, strlen(keyPtr), valueBytes.bindMemory(to: CChar.self).baseAddress, value.count)
                }
            }
        }
        for key in deletes {
            key.withCString { keyPtr in
                api.writeBatchDelete(batch, keyPtr, strlen(keyPtr))
            }
        }
        guard let writeOptions = api.writeOptionsCreate() else {
            throw SwiftBitnodeError.message("rocksdb write options allocation failed")
        }
        defer { api.writeOptionsDestroy(writeOptions) }
        var err: UnsafeMutablePointer<CChar>?
        api.write(db, writeOptions, batch, &err)
        if let err {
            let message = String(cString: err)
            api.free(err)
            throw SwiftBitnodeError.message("rocksdb batch write failed: \(message)")
        }
    }
}
