using System.Text.Json;

namespace ClaudeLockWidget.Provider;

/// <summary>
/// What the PowerShell side last published: the tile picture as a data URI (a transparent "glass" version
/// for dark hosts and an opaque "card" version for light ones) and its spoken description.
/// </summary>
internal sealed record WidgetState(string Stamp, string Alt, string ImageDataUri, string ImageCardDataUri);

internal static class StateReader
{
    public static string Directory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClaudeLockWidget", "widget");

    public static string StatePath => Path.Combine(Directory, "widget-state.json");

    /// <summary>Returns null while nothing has been published yet or while a file is being replaced.</summary>
    public static WidgetState? TryRead()
    {
        try
        {
            if (!File.Exists(StatePath)) { return null; }

            using var doc = JsonDocument.Parse(ReadAllTextShared(StatePath));
            var root = doc.RootElement;

            var image = LoadImage(root.GetProperty("image").GetString());
            if (image is null) { return null; }
            // older state files have no card variant: fall back to the glass one
            var card = root.TryGetProperty("imageCard", out var c) ? LoadImage(c.GetString()) : null;

            var updated = root.TryGetProperty("updatedAt", out var u) ? u.GetString() ?? "" : "";
            var alt = root.TryGetProperty("alt", out var a) ? a.GetString() ?? "" : "Claude Code usage";
            return new WidgetState(updated + "|" + root.GetProperty("image").GetString(), alt, image, card ?? image);
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException or KeyNotFoundException)
        {
            Log.Error("Could not read widget state", ex);
            return null;
        }
    }

    /// <summary>Reads a picture from the widget folder as a data URI (the name comes from our own state file,
    /// but it can never escape the folder).</summary>
    private static string? LoadImage(string? fileName)
    {
        if (string.IsNullOrWhiteSpace(fileName)) { return null; }
        var path = Path.GetFullPath(Path.Combine(Directory, Path.GetFileName(fileName)));
        if (!File.Exists(path)) { return null; }
        return "data:image/png;base64," + Convert.ToBase64String(File.ReadAllBytes(path));
    }

    private static string ReadAllTextShared(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}
