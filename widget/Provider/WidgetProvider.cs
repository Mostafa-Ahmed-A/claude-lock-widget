using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Windows.Widgets.Providers;

namespace ClaudeLockWidget.Provider;

/// <summary>One pinned widget instance (lock screen or Widgets board).</summary>
public sealed class CompactWidgetInfo
{
    public string WidgetId { get; init; } = "";
    public string DefinitionId { get; init; } = "";
    public bool IsActive { get; set; }
}

/// <summary>
/// Shows the picture and text published by ClaudeLockWidget.ps1. All callbacks are wrapped so an
/// exception can never take the provider (and with it the widget) down.
/// </summary>
[ComVisible(true)]
[ComDefaultInterface(typeof(IWidgetProvider))]
[Guid(ClsIdText)]
public sealed class WidgetProvider : IWidgetProvider
{
    // Must match the CLSID in AppxManifest (com:Class Id and CreateInstance ClassId).
    public const string ClsIdText = "CF8E2135-69D1-48E2-B0CE-EB2C647D2047";
    public static readonly Guid ClsId = new(ClsIdText);

    // "header": null lets the picture use the whole tile (documented widget header customization).
    // The transparent "glass" picture has light text, so it is used everywhere except a light-theme host,
    // where the opaque "card" picture is used instead.
    private const string CardTemplate = """
        {
          "type": "AdaptiveCard",
          "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
          "version": "1.6",
          "speak": "${alt}",
          "header": null,
          "body": [
            { "type": "Image", "url": "${image}", "altText": "${alt}", "size": "Stretch", "horizontalAlignment": "Center",
              "$when": "${$host.hostTheme != \"light\"}" },
            { "type": "Image", "url": "${imageCard}", "altText": "${alt}", "size": "Stretch", "horizontalAlignment": "Center",
              "$when": "${$host.hostTheme == \"light\"}" }
          ]
        }
        """;

    private const string WaitingTemplate = """
        {
          "type": "AdaptiveCard",
          "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
          "version": "1.5",
          "body": [
            { "type": "TextBlock", "text": "Claude usage", "weight": "Bolder", "wrap": true },
            { "type": "TextBlock", "text": "Waiting for the first update. Finish a task in Claude Code, or run refresh-now.cmd.", "wrap": true, "isSubtle": true, "size": "Small" }
          ]
        }
        """;

    private static readonly object Gate = new();
    private static readonly Dictionary<string, CompactWidgetInfo> Running = new();
    private static readonly ManualResetEvent NoWidgetsLeft = new(false);
    private static FileSystemWatcher? watcher;
    private static Timer? debounce;
    private static Timer? poll;
    private static DateTime lastStateWrite = DateTime.MinValue;
    private static bool instanceCreated;
    private static bool started;

    public WidgetProvider()
    {
        try
        {
            lock (Gate) { instanceCreated = true; }
            RecoverRunningWidgets();
            EnsureStarted();
            Log.Info($"Provider instance created; {Running.Count} widget(s) recovered.");
        }
        catch (Exception ex) { Log.Error("Provider constructor failed", ex); }
    }

    // ------------------------------------------------------------- IWidgetProvider

    public void CreateWidget(WidgetContext widgetContext)
    {
        Guarded(nameof(CreateWidget), () =>
        {
            var info = new CompactWidgetInfo { WidgetId = widgetContext.Id, DefinitionId = widgetContext.DefinitionId };
            lock (Gate) { Running[info.WidgetId] = info; NoWidgetsLeft.Reset(); }
            Log.Info($"CreateWidget {info.DefinitionId} ({info.WidgetId})");
            Push(info);
        });
    }

    public void DeleteWidget(string widgetId, string customState)
    {
        Guarded(nameof(DeleteWidget), () =>
        {
            lock (Gate)
            {
                Running.Remove(widgetId);
                if (Running.Count == 0) { NoWidgetsLeft.Set(); }
            }
            Log.Info($"DeleteWidget {widgetId}");
        });
    }

    public void OnActionInvoked(WidgetActionInvokedArgs actionInvokedArgs)
    {
        // The widget has no actions; refreshing is the only thing a click could mean.
        Guarded(nameof(OnActionInvoked), PushAll);
    }

    public void OnWidgetContextChanged(WidgetContextChangedArgs contextChangedArgs)
    {
        Guarded(nameof(OnWidgetContextChanged), () =>
        {
            var id = contextChangedArgs.WidgetContext.Id;
            CompactWidgetInfo? info;
            lock (Gate) { Running.TryGetValue(id, out info); }
            if (info is not null) { Push(info); }
        });
    }

    public void Activate(WidgetContext widgetContext)
    {
        Guarded(nameof(Activate), () =>
        {
            CompactWidgetInfo? info;
            lock (Gate)
            {
                Running.TryGetValue(widgetContext.Id, out info);
                if (info is not null) { info.IsActive = true; }
            }
            // The lock screen asks for fresh content when it appears: always re-send.
            if (info is not null) { Push(info); }
        });
    }

    public void Deactivate(string widgetId)
    {
        Guarded(nameof(Deactivate), () =>
        {
            lock (Gate) { if (Running.TryGetValue(widgetId, out var info)) { info.IsActive = false; } }
        });
    }

    // ------------------------------------------------------------------ lifetime

    /// <summary>Blocks until the last widget has been removed (or Windows never created one).</summary>
    public static void RunUntilNoWidgets()
    {
        var since = DateTime.UtcNow;
        while (true)
        {
            if (NoWidgetsLeft.WaitOne(TimeSpan.FromSeconds(60))) { return; }
            lock (Gate)
            {
                if (Running.Count == 0 && (instanceCreated || DateTime.UtcNow - since > TimeSpan.FromMinutes(10))) { return; }
            }
        }
    }

    private static void RecoverRunningWidgets()
    {
        // After a crash or reboot Windows still has our widgets pinned; ask which ones.
        foreach (var widgetInfo in WidgetManager.GetDefault().GetWidgetInfos())
        {
            var ctx = widgetInfo.WidgetContext;
            lock (Gate)
            {
                if (!Running.ContainsKey(ctx.Id))
                {
                    Running[ctx.Id] = new CompactWidgetInfo { WidgetId = ctx.Id, DefinitionId = ctx.DefinitionId };
                }
            }
        }
        lock (Gate) { if (Running.Count > 0) { NoWidgetsLeft.Reset(); } }
        PushAll();
    }

    private static void EnsureStarted()
    {
        lock (Gate)
        {
            if (started) { return; }
            started = true;
        }

        Directory.CreateDirectory(StateReader.Directory);
        debounce = new Timer(_ => Guarded("debounce", PushAll), null, Timeout.Infinite, Timeout.Infinite);
        watcher = new FileSystemWatcher(StateReader.Directory, "widget-state.json")
        {
            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size | NotifyFilters.CreationTime,
            EnableRaisingEvents = true,
        };
        FileSystemEventHandler onChange = (_, _) => debounce.Change(400, Timeout.Infinite);
        watcher.Changed += onChange;
        watcher.Created += onChange;
        watcher.Renamed += (_, _) => debounce.Change(400, Timeout.Infinite);

        // Safety net in case a file event is ever missed (network drives, sleep/resume, ...).
        poll = new Timer(_ => Guarded("poll", () =>
        {
            var write = File.Exists(StateReader.StatePath) ? File.GetLastWriteTimeUtc(StateReader.StatePath) : DateTime.MinValue;
            if (write != lastStateWrite) { PushAll(); }
        }), null, TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(30));
    }

    // ------------------------------------------------------------------- updating

    private static void PushAll()
    {
        CompactWidgetInfo[] snapshot;
        lock (Gate) { snapshot = Running.Values.ToArray(); }
        if (snapshot.Length == 0) { return; }

        var state = StateReader.TryRead();
        lastStateWrite = File.Exists(StateReader.StatePath) ? File.GetLastWriteTimeUtc(StateReader.StatePath) : DateTime.MinValue;
        foreach (var info in snapshot) { Send(info, state); }
    }

    private static void Push(CompactWidgetInfo info) => Send(info, StateReader.TryRead());

    private static void Send(CompactWidgetInfo info, WidgetState? state)
    {
        try
        {
            var options = new WidgetUpdateRequestOptions(info.WidgetId);
            if (state is null)
            {
                options.Template = WaitingTemplate;
                options.Data = "{}";
                options.CustomState = "waiting";
            }
            else
            {
                options.Template = CardTemplate;
                options.Data = JsonSerializer.Serialize(new Dictionary<string, string>
                {
                    ["image"] = state.ImageDataUri,
                    ["imageCard"] = state.ImageCardDataUri,
                    ["alt"] = state.Alt,
                });
                options.CustomState = state.Stamp;
            }
            WidgetManager.GetDefault().UpdateWidget(options);
        }
        catch (Exception ex) { Log.Error($"UpdateWidget failed for {info.WidgetId}", ex); }
    }

    private static void Guarded(string what, Action action)
    {
        try { action(); }
        catch (Exception ex) { Log.Error(what + " failed", ex); }
    }
}
