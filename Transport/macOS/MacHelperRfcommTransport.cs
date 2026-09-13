using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;

namespace OppoPodsManager;

/// <summary>
/// macOS 传输：拉起 IOBluetooth 桥接助手进程（RfcommHelper），经 stdin/stdout 字节流收发。
/// 助手做 SDP 查询拿 HeyMelody SPP 通道号并打开 RFCOMM 通道；本类只做字节搬运与协议成帧。
/// 助手必须由已获得蓝牙 TCC 权限的 App 拉起，命令行直接运行会被 0xe00002bc 拒绝。
/// </summary>
public sealed class MacHelperRfcommTransport : IPodTransport
{
    private const int ConnectWaitMs = 60_000;   // 等一个通道打开（含逐通道扫描）的最长预算
    private const int ProbeWaitMs = 600;        // 等电量响应帧判定通道是否为 SPP
    private const int MaxPipeFrame = 8192;

    private IFrameCodec _codec = new SppFrameCodec(); // 0x81 模式位到达后按链路类型切换
    private readonly List<byte> _framer = new();
    private readonly ConcurrentQueue<PodFrame> _rxQueue = new();
    private readonly IDeviceLocator _locator;
    private readonly object _sendLock = new();

    private Process? _proc;
    private System.Net.Sockets.TcpClient? _tcp;
    private System.Net.Sockets.NetworkStream? _cmd;
    private volatile int _cmdPort;
    private readonly SemaphoreSlim _portSignal = new(0, 1);
    private Thread? _readThread;
    private volatile bool _disposed;
    private readonly SemaphoreSlim _statusSignal = new(0, 1);

    private byte _lastStatusOpcode;   // 0x81 opened / 0x83 exhausted / 0x84 closed
    private byte _lastMode;           // 0x81 携带的链路模式：1=RFCOMM 2=GATT
    private byte _openedChannel;

    public string? DeviceName { get; private set; }
    public string? LastError { get; private set; }
    public bool IsConnected { get; private set; }
    public event Action<PodFrame>? FrameReceived;
    public event Action? Disconnected;

    public MacHelperRfcommTransport() : this(new MacBluetoothLocator()) { }
    public MacHelperRfcommTransport(IDeviceLocator locator) { _locator = locator; }

    public bool Connect()
    {
        try
        {
            Log.D("HELPRFC", "Connect: start");
            IsConnected = false; LastError = null; _disposed = false;
            while (_portSignal.Wait(0)) { } // 清掉上一轮残留的端口信号

            var (addr, name) = _locator.Locate();
            if (addr == 0) { LastError = "No paired OPPO device found"; return false; }
            DeviceName = name;

            _proc = SpawnHelper(AddrToString(addr));
            if (_proc == null) { LastError = "RfcommHelper 未找到（编译产物缺失）"; return false; }
            StartReadLoop();

            // helper 把命令通道端口打到 stderr（PORT=xxx），等它监好后连过去
            // （新二进制首次启动可能被 Gatekeeper 扫描拖慢数秒）
            if (!_portSignal.Wait(20_000)) { LastError = "RfcommHelper 未报告命令端口"; Cleanup(); return false; }
            _tcp = new System.Net.Sockets.TcpClient();
            _tcp.Connect(System.Net.IPAddress.Loopback, _cmdPort);
            _cmd = _tcp.GetStream();
            Log.D("HELPRFC", $"cmd channel connected port={_cmdPort}");

            // 探测：逐候选链路打开 → 发电量查询 → 收到合法响应帧才算命中 melody 控制通道
            var deadline = DateTime.UtcNow.AddMilliseconds(ConnectWaitMs);
            while (!_disposed && DateTime.UtcNow < deadline)
            {
                var st = WaitStatus(ConnectWaitMs);
                if (_disposed) break;
                if (st == 0x81)
                {
                    // 0x81 payload: [0x81, mode, id]；mode=1 RFCOMM(Spp帧) mode=2 GATT(melody帧)
                    bool gatt = _lastMode == 2;
                    _codec = gatt ? new GattFrameCodec() : new SppFrameCodec();
                    lock (_framer) _framer.Clear();
                    while (_rxQueue.TryDequeue(out _)) { }
                    Log.D("HELPRFC", $"Connect: link mode={_lastMode} id={_openedChannel} opened, probing");
                    var probe = _codec.Encode(OppoProtocol.CmdBattery, Array.Empty<byte>());
                    var probeMsg = new byte[probe.Length + 1];
                    probeMsg[0] = 0x01;
                    Buffer.BlockCopy(probe, 0, probeMsg, 1, probe.Length);
                    lock (_sendLock) { WritePipe(probeMsg); }
                    if (WaitAnyFrame(ProbeWaitMs))
                    {
                        IsConnected = true; LastError = null;
                        Log.Result("HELPRFC", "Connect", true, $"\"{name}\" ch={_openedChannel}");
                        return true;
                    }
                    Log.D("HELPRFC", $"Connect: ch={_openedChannel} probe no response, trying next");
                    SendNext();
                }
                else if (st == 0x83) { LastError = "No OPPO RFCOMM channel (helper exhausted)"; break; }
                else break; // 0x84 closed / helper exited
            }

            if (LastError == null) LastError = "RfcommHelper 连接超时";
            Cleanup();
            return false;
        }
        catch (Exception e) { LastError = e.Message; Log.Ex("HELPRFC", "Connect", e); Cleanup(); return false; }
    }

    private Process? SpawnHelper(string addr)
    {
        var helperPath = Path.Combine(AppContext.BaseDirectory, "OppodsRfcommHelper");
        if (!File.Exists(helperPath)) { Log.D("HELPRFC", $"helper missing: {helperPath}"); return null; }

        var psi = new ProcessStartInfo
        {
            FileName = helperPath,
            Arguments = addr,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        var p = Process.Start(psi);
        p.ErrorDataReceived += (_, e) =>
        {
            if (e.Data == null) return;
            Log.D("HELPER", e.Data);
            // helper 的日志行带 "[helper] " 前缀，用 Contains 而非 StartsWith
            int idx = e.Data.IndexOf("PORT=", StringComparison.Ordinal);
            if (idx >= 0 && int.TryParse(e.Data.Substring(idx + 5), out var port))
            {
                _cmdPort = port;
                _portSignal.Release();
            }
        };
        p.BeginErrorReadLine();
        return p;
    }

    private static string AddrToString(ulong addr)
    {
        var parts = new string[6];
        for (int i = 5; i >= 0; i--) { parts[i] = (addr & 0xFF).ToString("X2"); addr >>= 8; }
        return string.Join(":", parts);
    }

    private void StartReadLoop()
    {
        _readThread = new Thread(ReadLoop) { IsBackground = true, Name = "HELPRFC-Read" };
        _readThread.Start();
    }

    private void ReadLoop()
    {
        try
        {
            var stdout = _proc!.StandardOutput.BaseStream;
            var hdr = new byte[4];
            while (!_disposed && ReadExactly(stdout, hdr) == 4)
            {
                int len = hdr[0] | (hdr[1] << 8) | (hdr[2] << 16) | (hdr[3] << 24);
                if (len == 0 || len > MaxPipeFrame) { Log.D("HELPRFC", $"ReadLoop: bad pipe frame len={len}"); break; }
                var payload = new byte[len];
                if (ReadExactly(stdout, payload) != len) break;

                switch (payload[0])
                {
                    case 0x01: // 通道数据
                        lock (_framer)
                        {
                            for (int i = 1; i < payload.Length; i++)
                            {
                                _framer.Add(payload[i]);
                                while (_codec.TryDecode(_framer, out var frame))
                                {
                                    _rxQueue.Enqueue(frame);
                                    try { FrameReceived?.Invoke(frame); }
                                    catch (Exception ex) { Log.Ex("HELPRFC", "ReadLoop dispatch", ex); }
                                }
                            }
                        }
                        break;
                    case 0x81: _openedChannel = payload.Length > 2 ? payload[2] : (byte)0; _lastMode = payload.Length > 1 ? payload[1] : (byte)1; _lastStatusOpcode = 0x81; _statusSignal.Release(); break;
                    case 0x83: _lastStatusOpcode = 0x83; _statusSignal.Release(); break;
                    case 0x84: _lastStatusOpcode = 0x84; _statusSignal.Release(); goto done;
                }
            }
        done:
            Log.D("HELPRFC", "ReadLoop: helper stream ended");
        }
        catch (Exception ex) { if (!_disposed) Log.Ex("HELPRFC", "ReadLoop", ex); }
        finally { if (IsConnected) { IsConnected = false; Disconnected?.Invoke(); } }
    }

    private static int ReadExactly(Stream s, byte[] buf)
    {
        int got = 0;
        while (got < buf.Length)
        {
            int r = s.Read(buf, got, buf.Length - got);
            if (r <= 0) break;
            got += r;
        }
        return got;
    }

    private byte WaitStatus(int timeoutMs)
    {
        _lastStatusOpcode = 0;
        if (!_statusSignal.Wait(timeoutMs)) return 0;
        return _lastStatusOpcode;
    }

    private bool WaitAnyFrame(int timeoutMs)
    {
        var end = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < end)
        {
            if (_rxQueue.Count > 0) return true;
            Thread.Sleep(20);
        }
        return _rxQueue.Count > 0;
    }

    private void SendNext()
    {
        lock (_sendLock) { try { WritePipe(new byte[] { 0x02 }); } catch { } }
    }

    private void WritePipe(byte[] bytes)
    {
        // 命令帧：4 字节小端长度 + payload（与 helper 的 HandleCmd 约定一致）
        var buf = new byte[bytes.Length + 4];
        buf[0] = (byte)(bytes.Length & 0xFF);
        buf[1] = (byte)((bytes.Length >> 8) & 0xFF);
        buf[2] = (byte)((bytes.Length >> 16) & 0xFF);
        buf[3] = (byte)((bytes.Length >> 24) & 0xFF);
        Buffer.BlockCopy(bytes, 0, buf, 4, bytes.Length);
        var s = _cmd!;
        s.Write(buf, 0, buf.Length);
        s.Flush();
        Log.D("HELPRFC", $"wrote {buf.Length}B to cmd socket");
    }

    public void Send(ushort cmd, byte[] payload)
    {
        Log.D("HELPRFC", $"Send 0x{cmd:X4} ({payload?.Length ?? 0}B) conn={IsConnected} cmd={( _cmd != null ? "ok" : "null")}");
        if (!IsConnected || _cmd == null) return;
        byte[] bytes;
        lock (_sendLock) { bytes = _codec.Encode(cmd, payload); }
        // 管道协议：payload[0]=0x01(数据)，其余为写入通道的原始字节
        var msg = new byte[bytes.Length + 1];
        msg[0] = 0x01;
        Buffer.BlockCopy(bytes, 0, msg, 1, bytes.Length);
        lock (_sendLock)
        {
            try { WritePipe(msg); }
            catch (Exception ex) { Log.Ex("HELPRFC", $"Send 0x{cmd:X4}", ex); }
        }
    }

    public void Poll(int timeoutMs)
    {
        if (!IsConnected) return;
        var end = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (true)
        {
            while (_rxQueue.TryDequeue(out var frame)) FrameReceived?.Invoke(frame);
            if (!IsConnected) return;
            if (DateTime.UtcNow >= end) break;
            Thread.Sleep(20);
        }
        while (_rxQueue.TryDequeue(out var frame)) FrameReceived?.Invoke(frame);
    }

    public void Close() { IsConnected = false; Cleanup(); }
    private void Cleanup()
    {
        var p = _proc;
        _proc = null;
        try { _cmd?.Dispose(); } catch { }
        try { _tcp?.Dispose(); } catch { }
        _cmd = null; _tcp = null;
        if (p == null) return;
        try { p.Kill(entireProcessTree: true); } catch { }
        try { p.Dispose(); } catch { }
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Close(); }
}
