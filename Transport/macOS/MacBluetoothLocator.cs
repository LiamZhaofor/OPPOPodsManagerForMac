using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OppoPodsManager;

public sealed class MacBluetoothLocator : IDeviceLocator
{
    public (ulong addr, string? name) Locate()
    {
        try
        {
            var devices = GetPairedDevices();
            // 优先找耳机类设备
            var earbuds = devices.Where(d => IsEarbudDevice(d.name)).ToList();
            var candidates = earbuds.Count > 0 ? earbuds : devices;

            foreach (var d in candidates)
                if (IsSupportedBrand(d.name)) return d;

            Log.D("BT", "MacLocate: no OPPO device found");
            return (0, null);
        }
        catch (Exception ex)
        {
            Log.Ex("BT", "MacLocate", ex);
            return (0, null);
        }
    }

    public IReadOnlyList<(ulong addr, string name)> LocateAllConnected()
    {
        var result = new List<(ulong addr, string name)>();
        try
        {
            var devices = GetPairedDevices();
            foreach (var d in devices)
                if (d.name != null && IsSupportedBrand(d.name))
                    result.Add((d.addr, d.name));
        }
        catch (Exception ex) { Log.Ex("BT", "MacLocateAll", ex); }
        return result;
    }

    private static List<(ulong addr, string? name)> GetPairedDevices()
    {
        var output = RunProcess("system_profiler", "SPBluetoothDataType -json");
        if (string.IsNullOrEmpty(output)) return new List<(ulong addr, string?)>();

        var devices = ParseSystemProfilerJson(output);
        if (devices.Count == 0)
            devices = ParseByRegex(output); // 兜底：结构化解析失败时按老版本文本格式扫描

        foreach (var d in devices)
            Log.D("BT", $"MacLocate: found \"{d.name}\" addr=0x{d.addr:X12}");
        return devices;
    }

    // system_profiler 的 JSON schema 在 macOS 26/27 变了：SPBluetoothDataType 顶层是数组，
    // 设备挂在 device_connected / device_not_connected 下且名字是设备对象的 key（没有
    // device_name 字段），地址改用 ":" 分隔；老版本是普通对象 + device_name 字段、
    // "-" 分隔地址。这里不做 schema 假设，递归收集一切带 device_address 的对象，
    // 名字取 device_name/name 字段，取不到时回退到该对象在父级里的 key。
    private static List<(ulong addr, string? name)> ParseSystemProfilerJson(string output)
    {
        var result = new List<(ulong addr, string?)>();
        var seen = new HashSet<ulong>();
        try
        {
            using var doc = JsonDocument.Parse(output);
            CollectDevices(doc.RootElement, null, result, seen);
        }
        catch (Exception ex)
        {
            Log.Ex("BT", "MacLocate json", ex);
            return new List<(ulong addr, string?)>();
        }
        return result;
    }

    private static void CollectDevices(JsonElement el, string? parentKey,
        List<(ulong addr, string? name)> result, HashSet<ulong> seen)
    {
        switch (el.ValueKind)
        {
            case JsonValueKind.Object:
                string? name = null;
                ulong addr = 0;
                foreach (var prop in el.EnumerateObject())
                {
                    if (prop.Value.ValueKind != JsonValueKind.String) continue;
                    if (prop.Name.Equals("device_address", StringComparison.OrdinalIgnoreCase))
                        addr = ParseBtAddr(prop.Value.GetString() ?? "");
                    else if (prop.Name.Equals("device_name", StringComparison.OrdinalIgnoreCase)
                          || prop.Name.Equals("name", StringComparison.OrdinalIgnoreCase))
                        name = prop.Value.GetString();
                }
                if (addr != 0 && seen.Add(addr))
                    result.Add((addr, name ?? parentKey));

                foreach (var prop in el.EnumerateObject())
                    if (prop.Value.ValueKind is JsonValueKind.Object or JsonValueKind.Array)
                        CollectDevices(prop.Value, prop.Name, result, seen);
                break;

            case JsonValueKind.Array:
                foreach (var item in el.EnumerateArray())
                    CollectDevices(item, parentKey, result, seen);
                break;
        }
    }

    // 老版本 macOS 的兜底解析：device_name 字段与 dash 分隔的地址按行顺序配对
    private static List<(ulong addr, string? name)> ParseByRegex(string output)
    {
        var devices = new List<(ulong addr, string? name)>();
        var addrRegex = new Regex(@"""([0-9a-fA-F]{2}(?:-[0-9a-fA-F]{2}){5})""", RegexOptions.Compiled);
        var nameRegex = new Regex(@"""name""\s*:\s*""([^""]+)""", RegexOptions.Compiled);

        var lines = output.Split('\n');
        string? currentName = null;
        for (int i = 0; i < lines.Length; i++)
        {
            var nameMatch = nameRegex.Match(lines[i]);
            if (nameMatch.Success) currentName = nameMatch.Groups[1].Value;

            var addrMatch = addrRegex.Match(lines[i]);
            if (addrMatch.Success && currentName != null)
            {
                var addr = ParseBtAddr(addrMatch.Groups[1].Value);
                if (addr != 0) devices.Add((addr, currentName));
                currentName = null;
            }
        }
        return devices;
    }

    private static ulong ParseBtAddr(string addrStr)
    {
        var hex = addrStr.Replace("-", "").Replace(":", "");
        return ulong.TryParse(hex, System.Globalization.NumberStyles.HexNumber, null, out var a) ? a : 0;
    }

    private static string? RunProcess(string fileName, string arguments)
    {
        try
        {
            using var proc = Process.Start(new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            if (proc == null) return null;
            var output = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit(10000);
            return output;
        }
        catch { return null; }
    }

    private static bool IsEarbudDevice(string? name)
    {
        if (string.IsNullOrEmpty(name)) return false;
        var lower = name.ToLowerInvariant();
        foreach (var kw in new[] { "buds", "enco", "air", "clip", "free", "bullets" })
            if (lower.Contains(kw)) return true;
        return false;
    }

    private static bool IsSupportedBrand(string? name)
    {
        if (string.IsNullOrEmpty(name)) return false;
        foreach (var brand in OppoProtocol.SupportedBrands)
            if (name.Contains(brand, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }
}
