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
            // 通知经 Notifier.app 子应用投递（自己的 bundle id + App 图标）：
            // 授权与通知来源都是「OPPO Pods Manager」，横幅显示耳机图标。
            // 兜底：主 helper（osascript 路径，来源显示为脚本编辑器）。
            var helper = Path.Combine(AppContext.BaseDirectory, "OppodsRfcommHelper");
            var notifier = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
                "..", "PlugIns", "Notifier.app", "Contents", "MacOS", "Notifier"));
            var target = File.Exists(notifier) ? notifier : helper;
            if (!File.Exists(target))
            {
                Log.D("NOTIFY", $"notify binary missing: {target}");
                return;
            }
            Log.D("NOTIFY", $"using {target}");

            var psi = new ProcessStartInfo
            {
                FileName = target,
                UseShellExecute = false,
                CreateNoWindow = true,
                // 不重定向任何流：未重定向时访问 p.StandardError 会抛异常；
                // helper 的诊断走 stderr 直接透传到本进程 stderr，丢弃即可
                RedirectStandardError = false,
            };
            psi.ArgumentList.Add("notify");
            psi.ArgumentList.Add(title);
            psi.ArgumentList.Add(string.IsNullOrEmpty(subtitle) ? "-" : subtitle);
            psi.ArgumentList.Add(body ?? "");
            var p = Process.Start(psi);
            if (p == null) return;
            Log.D("NOTIFY", $"spawned pid={p.Id} title={title}");
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
