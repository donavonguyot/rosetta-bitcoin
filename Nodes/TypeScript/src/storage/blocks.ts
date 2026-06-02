import {
  appendFileSync,
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readSync,
  statSync,
} from "node:fs";
import { join } from "node:path";

const MAX_FILE_BYTES = 128 * 1024 * 1024;

export interface BlockWriteResult {
  fileName: string;
  fileNumber: number;
  offset: number;
  size: number;
}

/** Append-only block flat files (Bitcoin Core blk*.dat style). */
export class BlockStore {
  private fileIndex = 0;
  private filePath: string;
  private offset = 0;

  constructor(
    private readonly blocksDir: string,
    readonly magic: Buffer,
  ) {
    if (magic.length !== 4) {
      throw new Error("network magic must be 4 bytes");
    }
    mkdirSync(this.blocksDir, { recursive: true });
    this.filePath = this.openFile(this.fileIndex);
    if (existsSync(this.filePath)) {
      this.offset = statSync(this.filePath).size;
    }
  }

  write(blockData: Buffer): BlockWriteResult {
    const sizeHeader = Buffer.allocUnsafe(4);
    sizeHeader.writeUInt32LE(blockData.length, 0);
    const record = Buffer.concat([this.magic, sizeHeader, blockData]);
    if (this.offset + record.length > MAX_FILE_BYTES && this.offset > 0) {
      this.fileIndex += 1;
      this.filePath = this.openFile(this.fileIndex);
      this.offset = 0;
    }
    const offset = this.offset;
    appendFileSync(this.filePath, record);
    this.offset += record.length;
    const fileName = this.fileNameForIndex(this.fileIndex);
    return {
      fileName,
      fileNumber: this.fileIndex,
      offset,
      size: blockData.length,
    };
  }

  read(fileName: string, offset: number, size: number): Buffer {
    const path = join(this.blocksDir, fileName);
    const fd = openSync(path, "r");
    try {
      const magic = Buffer.alloc(4);
      readSync(fd, magic, 0, 4, offset);
      const sizeBuf = Buffer.alloc(4);
      readSync(fd, sizeBuf, 0, 4, offset + 4);
      const payloadSize = sizeBuf.readUInt32LE(0);
      if (payloadSize !== size) {
        throw new Error(`Block size mismatch: expected ${size}, file has ${payloadSize}`);
      }
      if (!magic.equals(this.magic)) {
        throw new Error("Block file magic mismatch");
      }
      const data = Buffer.alloc(size);
      const readBytes = readSync(fd, data, 0, size, offset + 8);
      if (readBytes !== size) {
        throw new Error("Unexpected EOF reading block");
      }
      return data;
    } finally {
      closeSync(fd);
    }
  }

  hasDataFile(fileNumber = 0): boolean {
    return existsSync(join(this.blocksDir, this.fileNameForIndex(fileNumber)));
  }

  /** Read the first magic bytes from blk00000.dat to verify chain magic. */
  verifyMagic(): boolean {
    const path = join(this.blocksDir, this.fileNameForIndex(0));
    if (!existsSync(path)) return true;
    const fd = openSync(path, "r");
    try {
      const buf = Buffer.alloc(4);
      readSync(fd, buf, 0, 4, 0);
      return buf.equals(this.magic);
    } finally {
      closeSync(fd);
    }
  }

  private openFile(index: number): string {
    const path = join(this.blocksDir, this.fileNameForIndex(index));
    if (!existsSync(path)) {
      const fd = openSync(path, "w");
      closeSync(fd);
    }
    return path;
  }

  private fileNameForIndex(index: number): string {
    return `blk${String(index).padStart(5, "0")}.dat`;
  }
}
