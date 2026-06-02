using CsBitNode.Util;

namespace CsBitNode.Storage;

public sealed class BlockStore
{
    private readonly string _blocksDir;
    private readonly byte[] _magic;
    private int _fileNumber;
    private FileStream? _currentFile;

    public BlockStore(string blocksDir, byte[] magic)
    {
        _blocksDir = blocksDir;
        _magic = magic;
        Directory.CreateDirectory(_blocksDir);
        _fileNumber = FindLatestFileNumber();
        OpenCurrentFile(append: true);
    }

    public sealed record StoredBlock(int FileNumber, int FileOffset, int BlockSize);

    public StoredBlock WriteBlock(byte[] payload)
    {
        if (_currentFile is null)
            OpenCurrentFile(append: true);
        var offset = (int)_currentFile!.Length;
        using var writer = new BinaryWriter(_currentFile, System.Text.Encoding.UTF8, leaveOpen: true);
        writer.Write(_magic);
        writer.Write(payload.Length);
        writer.Write(payload);
        _currentFile.Flush();
        return new StoredBlock(_fileNumber, offset, payload.Length);
    }

    public byte[] ReadBlock(int fileNumber, int offset, int size)
    {
        var path = BlockFilePath(fileNumber);
        using var stream = File.OpenRead(path);
        stream.Seek(offset, SeekOrigin.Begin);
        var magic = new byte[4];
        stream.ReadExactly(magic);
        if (!magic.AsSpan().SequenceEqual(_magic))
            throw new InvalidDataException("block file magic mismatch");
        var lenBuf = new byte[4];
        stream.ReadExactly(lenBuf);
        var len = BitConverter.ToInt32(lenBuf, 0);
        if (len != size)
            throw new InvalidDataException($"block size mismatch expected {size} got {len}");
        var payload = new byte[len];
        stream.ReadExactly(payload);
        return payload;
    }

    private string BlockFilePath(int fileNumber) =>
        Path.Combine(_blocksDir, $"blk{fileNumber:D5}.dat");

    private int FindLatestFileNumber()
    {
        if (!Directory.Exists(_blocksDir))
            return 0;
        var files = Directory.GetFiles(_blocksDir, "blk*.dat");
        if (files.Length == 0)
            return 0;
        return files
            .Select(f => int.Parse(Path.GetFileNameWithoutExtension(f)[3..]))
            .Max();
    }

    private void OpenCurrentFile(bool append)
    {
        _currentFile?.Dispose();
        var path = BlockFilePath(_fileNumber);
        _currentFile = new FileStream(path, append ? FileMode.OpenOrCreate : FileMode.Create, FileAccess.ReadWrite, FileShare.Read);
        if (append)
            _currentFile.Seek(0, SeekOrigin.End);
    }
}

public sealed class BlockStorage
{
    private readonly BlockStore _store;

    public BlockStorage(BlockStore store) => _store = store;

    public BlockStore.StoredBlock Store(byte[] payload) => _store.WriteBlock(payload);

    public byte[] Load(int fileNumber, int offset, int size) =>
        _store.ReadBlock(fileNumber, offset, size);
}
