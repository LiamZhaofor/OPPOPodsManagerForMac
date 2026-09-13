using System;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace OppoPodsManager;

/// <summary>
/// macOS 系统通知（Notification Center）：拉起 helper 的 notify 一次性模式，
/// 经 UNUserNotificationCenter 投递（bundle 继承 App 身份，授权一次常驻生效）。
/// </summary>
public static class MacNativeNotify
{
    public static void Show(string title, string subtitle, string body)
    {
        try
        {
            var helper = Path.Combine(AppContext.BaseDirectory, "OppodsRfcommHelper");
            if (!File.Exists(helper))
            {
                Log.D("NOTIFY", $"helper missing: {helper}");
                return;
            }

            var psi = new ProcessStartInfo
            {
                FileName = helper,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardError = true,
            };
            psi.ArgumentList.Add("notify");
            psi.ArgumentList.Add(title);
            psi.ArgumentList.Add(string.IsNullOrEmpty(subtitle) ? "-" : subtitle);
            psi.ArgumentList.Add(body ?? "");
            var p = Process.Start(psi);
            if (p == null) return;
            Log.D("NOTIFY", $"spawned pid={p.Id} title={title}");
            p.ErrorDataReceived += (_, e) => { if (e.Data != null) Log.D("NOTIFY", e.Data); };
            p.BeginErrorReadLine();
            _ = p.StandardError.ReadToEndAsync().ContinueWith(_ => { try { p.Dispose(); } catch { } });
        }
        catch (Exception ex)
        {
            Log.Ex("NOTIFY", "Show", ex);
        }
    }

    /// <summary>电量摘要（左/右/盒，含充电标记），与 Toast 面板同源的合并口径。</summary>
    public static string BatterySummary(PodState? s)
    {
        if (s == null) return "";
        string Fmt((int, bool)? d, string label) =>
            d == null ? $"{label} -%" : $"{label} {d.Value.Item1}%{(d.Value.Item2 ? "⚡" : "")}";
        (int, bool)? L = s.Battery.TryGetValue("L", out var l) ? l : null;
        (int, bool)? R = s.Battery.TryGetValue("R", out var r) ? r : null;
        (int, bool)? C = s.Battery.TryGetValue("C", out var c) ? c : null;
        L = L == null ? null : (L.Value.Item1, L.Value.Item2 || s.WearingL == "入盒");
        R = R == null ? null : (R.Value.Item1, R.Value.Item2 || s.WearingR == "入盒");
        var parts = new[] { Fmt(L, "左耳"), Fmt(R, "右耳"), Fmt(C, "充电盒") };
        return string.Join(" · ", parts.Where(p => !string.IsNullOrEmpty(p)));
    }
}
