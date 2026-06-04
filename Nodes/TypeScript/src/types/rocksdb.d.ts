declare module "rocksdb" {
  export interface RocksDbBatchOperation {
    type: "put" | "del";
    key: Buffer;
    value?: Buffer;
  }

  export interface RocksDbIterator {
    next(callback: (error: Error | null, key?: Buffer, value?: Buffer) => void): void;
    end(callback: (error?: Error | null) => void): void;
  }

  export interface RocksDbDatabase {
    open(options: Record<string, unknown>, callback: (error?: Error | null) => void): void;
    close(callback: (error?: Error | null) => void): void;
    get(key: Buffer, options: Record<string, unknown>, callback: (error: Error | null, value?: Buffer) => void): void;
    getMany(
      keys: readonly Buffer[],
      options: Record<string, unknown>,
      callback: (error: Error | null, values?: Array<Buffer | undefined>) => void,
    ): void;
    put(key: Buffer, value: Buffer, options: Record<string, unknown>, callback: (error?: Error | null) => void): void;
    del(key: Buffer, options: Record<string, unknown>, callback: (error?: Error | null) => void): void;
    batch(
      operations: readonly RocksDbBatchOperation[],
      options: Record<string, unknown>,
      callback: (error?: Error | null) => void,
    ): void;
    iterator(options?: Record<string, unknown>): RocksDbIterator;
    getProperty(property: string): string;
  }

  export default function rocksdb(location: string): RocksDbDatabase;
}
