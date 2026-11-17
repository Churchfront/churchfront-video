using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using CueATEM;

namespace CueVideo;

/// <summary>
/// A small HTTP interface so other software on this computer (cuevideo-mcp.exe, which Claude
/// uses) can do anything the app's screens can. It listens on 127.0.0.1 only, and every
/// request must carry the key saved in %APPDATA%\CueVideo\control-token.
///
///     GET  /tools                                      the tool list (MCP tool definitions)
///     POST /call  {"name": ..., "arguments": {...}}    run one tool, returns its result
/// </summary>
public sealed class ControlServer
{
    public static ControlServer Shared { get; } = new();
    public const int Port = 9911;
    public string Token { get; private set; } = "";
    public bool Running { get; private set; }
    public string? Error { get; private set; }
    private TcpListener? _listener;

    public static string TokenPath => Path.Combine(ConfigStore.Folder, "control-token");

    public void Start()
    {
        Token = LoadOrMakeToken();
        try
        {
            var l = new TcpListener(IPAddress.Loopback, Port);
            l.Server.ExclusiveAddressUse = true;
            l.Start();
            _listener = l;
            Running = true;
            Task.Run(() => Accept(l));
        }
        catch (Exception e)
        {
            Error = e.Message;
            Console.Error.WriteLine($"Churchfront Video control server didn't start: {e.Message}");
        }
    }

    public void Stop() { try { _listener?.Stop(); } catch { } Running = false; }

    /// <summary>A random key, made once and kept in this user's own folder.</summary>
    public static string LoadOrMakeToken()
    {
        try
        {
            var t = File.ReadAllText(TokenPath).Trim();
            if (t.Length >= 32) return t;
        }
        catch { }
        var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
        Directory.CreateDirectory(ConfigStore.Folder);
        File.WriteAllText(TokenPath, token);
        return token;
    }

    private async Task Accept(TcpListener l)
    {
        while (true)
        {
            TcpClient c;
            try { c = await l.AcceptTcpClientAsync(); } catch { return; }
            _ = Task.Run(() => Serve(c));
        }
    }

    private sealed record Request(string Method, string Path, Dictionary<string, string> Headers, byte[] Body);

    private async Task Serve(TcpClient c)
    {
        using (c)
        {
            try
            {
                c.ReceiveTimeout = 10000;
                var s = c.GetStream();
                var buf = new List<byte>();
                var chunk = new byte[65536];
                Request? req = null;
                while (req == null)
                {
                    var n = await s.ReadAsync(chunk).AsTask().WaitAsync(TimeSpan.FromSeconds(10));
                    if (n <= 0 || buf.Count > 4 << 20) return;
                    buf.AddRange(chunk.AsSpan(0, n).ToArray());
                    req = Parse(buf.ToArray());
                }
                var (status, body) = await Handle(req);
                var data = Encoding.UTF8.GetBytes(CueJson.Sorted(body)!.ToJsonString(CueJson.Pretty));
                var text = status switch { 200 => "OK", 401 => "Unauthorized", 404 => "Not Found", _ => "Bad Request" };
                var head = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {text}\r\nContent-Type: application/json\r\nContent-Length: {data.Length}\r\nConnection: close\r\n\r\n");
                await s.WriteAsync(head);
                await s.WriteAsync(data);
                await s.FlushAsync();
            }
            catch { }
        }
    }

    /// <summary>A whole request, or null while more bytes are needed.</summary>
    private static Request? Parse(byte[] d)
    {
        var end = IndexOf(d, "\r\n\r\n"u8);
        if (end < 0) return null;
        var head = Encoding.UTF8.GetString(d, 0, end).Split("\r\n");
        var first = head[0].Split(' ');
        if (first.Length < 2) return new Request("", "", new(), Array.Empty<byte>());
        var headers = new Dictionary<string, string>();
        foreach (var line in head.Skip(1))
        {
            var i = line.IndexOf(':');
            if (i > 0) headers[line[..i].ToLowerInvariant()] = line[(i + 1)..].Trim();
        }
        var len = headers.TryGetValue("content-length", out var cl) && int.TryParse(cl, out var x) ? x : 0;
        var start = end + 4;
        if (d.Length - start < len) return null;
        return new Request(first[0], first[1], headers, d.AsSpan(start, len).ToArray());
    }

    private static int IndexOf(byte[] d, ReadOnlySpan<byte> pat) => d.AsSpan().IndexOf(pat);

    private Task<(int, JsonNode)> Handle(Request r)
    {
        static JsonNode Err(string m) => new JsonObject { ["error"] = m };
        if (!r.Headers.TryGetValue("x-cuevideo-token", out var t) || !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(t), Encoding.UTF8.GetBytes(Token)))
            return Task.FromResult((401, Err("Missing or wrong key.")));
        var tcs = new TaskCompletionSource<(int, JsonNode)>(TaskCreationOptions.RunContinuationsAsynchronously);
        switch (r.Method, r.Path)
        {
            case ("GET", "/tools"):
                MainThread.Post(() => tcs.TrySetResult((200, new JsonObject { ["tools"] = ControlTools.Definitions() })));
                break;
            case ("POST", "/call"):
                JsonObject? obj = null;
                try { obj = JsonNode.Parse(r.Body)?.AsObject(); } catch { }
                if (obj == null || CueJson.Str(obj["name"]) is not string name)
                    return Task.FromResult((400, Err("Send {\"name\": tool, \"arguments\": {...}}.")));
                var args = obj["arguments"] as JsonObject ?? new JsonObject();
                args = (JsonObject)args.DeepClone();
                MainThread.Post(() => ControlTools.Call(name, args, result => tcs.TrySetResult((200, result))));
                break;
            default:
                return Task.FromResult((404, Err("Use GET /tools or POST /call.")));
        }
        return tcs.Task.WaitAsync(TimeSpan.FromSeconds(150));
    }
}
