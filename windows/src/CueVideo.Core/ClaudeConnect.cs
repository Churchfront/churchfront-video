using System.Text.Json;
using System.Text.Json.Nodes;

namespace CueVideo;

/// <summary>
/// Adds Churchfront Video to the Claude desktop app, so a church's Claude can set it up and run
/// it (through cuevideo-mcp.exe, beside this app). One button in Setup.
///
/// Claude Desktop on Windows reads its local connectors from
/// %APPDATA%\Claude\claude_desktop_config.json (and, for the Microsoft Store version, the same
/// file inside its package folder), under "mcpServers". One entry, "churchfront-video", is
/// added or updated and everything else in the file is left as it was. The first time an
/// existing file is changed, a copy is kept beside it.
/// </summary>
public static class ClaudeConnect
{
    public const string ServerName = "churchfront-video";

    public enum State { NoClaude, NotConnected, Connected, StalePath, RunFromTemporaryPlace }

    private static string AppData => Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    private static string LocalAppData => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    /// <summary>Every place Claude Desktop may read its settings from on this computer.</summary>
    public static List<string> ConfigPaths
    {
        get
        {
            var o = new List<string> { Path.Combine(AppData, "Claude", "claude_desktop_config.json") };
            try
            {
                var pk = Path.Combine(LocalAppData, "Packages");
                if (Directory.Exists(pk))
                    foreach (var d in Directory.GetDirectories(pk, "Claude_*"))
                        o.Add(Path.Combine(d, "LocalCache", "Roaming", "Claude", "claude_desktop_config.json"));
            }
            catch { }
            return o;
        }
    }

    public static string ConfigPath => ConfigPaths[0];

    /// <summary>The MCP server beside this copy of the app.</summary>
    public static string ServerPath => Path.Combine(AppContext.BaseDirectory, "cuevideo-mcp.exe");

    public static bool ClaudeInstalled =>
        Directory.Exists(Path.Combine(LocalAppData, "AnthropicClaude"))
        || Directory.Exists(Path.Combine(AppData, "Claude"))
        || ConfigPaths.Count > 1
        || Directory.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Claude"));

    /// <summary>Running from inside a zip file Windows unpacked to a temporary folder: the
    /// path would stop working, so ask for it to be unpacked properly first.</summary>
    public static bool RunningFromTemporaryPlace =>
        AppContext.BaseDirectory.StartsWith(Path.GetTempPath(), StringComparison.OrdinalIgnoreCase);

    public static State Current()
    {
        if (RunningFromTemporaryPlace) return State.RunFromTemporaryPlace;
        if (!ClaudeInstalled) return State.NoClaude;
        var entry = ReadConfig(ConfigPath)?["mcpServers"]?[ServerName];
        if (entry == null) return State.NotConnected;
        return string.Equals(CueATEM.CueJson.Str(entry["command"]), ServerPath, StringComparison.OrdinalIgnoreCase) ? State.Connected : State.StalePath;
    }

    private static JsonObject? ReadConfig(string path)
    {
        try { return JsonNode.Parse(File.ReadAllText(path), documentOptions: new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip }) as JsonObject; }
        catch { return null; }
    }

    private static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>Adds (or points at this copy) the churchfront-video entry. Returns an error message, or null when it worked.</summary>
    public static string? Connect()
    {
        if (RunningFromTemporaryPlace) return "Unzip Churchfront Video to a folder of its own (such as Documents or Program Files) and open it from there first.";
        if (!File.Exists(ServerPath)) return $"cuevideo-mcp.exe is missing from {AppContext.BaseDirectory}. Reinstall Churchfront Video.";
        // The main file always; the Store version's copy only where its folder already exists.
        var paths = ConfigPaths.Where((p, i) => i == 0 || Directory.Exists(Path.GetDirectoryName(Path.GetDirectoryName(p)))).ToList();
        foreach (var path in paths)
        {
            var config = new JsonObject();
            if (File.Exists(path))
            {
                string text;
                try { text = File.ReadAllText(path); } catch { return "Couldn't read Claude's settings file."; }
                if (text.Trim().Length > 0)
                {
                    var obj = ReadConfig(path);
                    if (obj == null) return $"Claude's settings file has a problem, so it was left alone: {path}";
                    config = obj;
                }
                var backup = Path.Combine(Path.GetDirectoryName(path)!, "claude_desktop_config.before-churchfront-video.json");
                try { if (!File.Exists(backup)) File.Copy(path, backup); } catch { }
            }
            var servers = config["mcpServers"] as JsonObject ?? new JsonObject();
            servers[ServerName] = new JsonObject { ["command"] = ServerPath, ["args"] = new JsonArray() };
            config["mcpServers"] = servers;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                ConfigStore.WriteAtomic(path, config.ToJsonString(Pretty));
            }
            catch (Exception e) { return $"Couldn't save Claude's settings: {e.Message}"; }
        }
        return Current() == State.Connected ? null : "Saved, but Claude's settings didn't read back as expected.";
    }

    /// <summary>Takes the churchfront-video entry out again, leaving the rest of the file alone.</summary>
    public static string? Disconnect()
    {
        foreach (var path in ConfigPaths)
        {
            var config = ReadConfig(path);
            if (config?["mcpServers"] is not JsonObject servers || !servers.ContainsKey(ServerName)) continue;
            servers.Remove(ServerName);
            try { ConfigStore.WriteAtomic(path, config.ToJsonString(Pretty)); }
            catch (Exception e) { return $"Couldn't save Claude's settings: {e.Message}"; }
        }
        return null;
    }

    public const string FirstPrompt = "Help me set up Churchfront Video for our church. Find our ATEM switcher and PTZ cameras on the network, check with me which camera is which, and set them up.";
}
