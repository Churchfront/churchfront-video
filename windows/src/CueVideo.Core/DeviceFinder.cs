using System.Collections.Concurrent;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using CueATEM;

namespace CueVideo;

/// <summary>
/// Finds the switcher and cameras on this computer's network, so nobody has to look up an IP
/// address. Three passes, run together:
/// - ATEM switchers: the ATEM hello packet (UDP 9910) to every address on each local /24.
/// - Canon PTZ cameras: Canon's HTTP control page (/-wvhttp-01-/info.cgi) on the same addresses.
/// - Everything that announces itself over mDNS (Bonjour): NDI sources (PTZOptics, BirdDog and
///   most NDI cameras), Blackmagic devices and web pages, with each one's address.
/// Nothing is changed: the result is a list for update_config.
/// </summary>
public static class DeviceFinder
{
    public sealed record Found(string Kind, string Name, string Host);

    /// <summary>Calls back (on a background thread) with what answered, and the networks searched.</summary>
    public static void Find(double seconds, Action<List<Found>, List<string>> done)
    {
        Task.Run(async () =>
        {
            var nets = LocalNetworks();
            var found = new ConcurrentDictionary<Found, byte>();
            void Add(Found f) => found.TryAdd(f, 0);
            var atem = Task.Run(() => { foreach (var f in ProbeATEM(nets.Select(n => n.Net).ToList(), seconds)) Add(f); });
            var mdns = Task.Run(() => { foreach (var f in Mdns(nets.Select(n => n.Local).ToList(), seconds)) Add(f); });
            var canon = ProbeCanon(nets.Select(n => n.Net).ToList(), seconds - 0.5, Add);
            try { await Task.WhenAll(atem, mdns, canon); } catch { }
            string[] order = { "ATEM", "Canon", "NDI", "Blackmagic", "Web" };
            int Rank(Found f) { var i = Array.FindIndex(order, o => f.Kind.StartsWith(o, StringComparison.Ordinal)); return i < 0 ? 9 : i; }
            static long IpKey(string h) => IPAddress.TryParse(h, out var ip) && ip.AddressFamily == AddressFamily.InterNetwork
                ? BitConverter.ToUInt32(ip.GetAddressBytes().Reverse().ToArray()) : long.MaxValue;
            var list = found.Keys.OrderBy(Rank).ThenBy(f => IpKey(f.Host)).ThenBy(f => f.Name).ToList();
            done(list, nets.Select(n => $"{n.Net}.0/24").ToList());
        });
    }

    /// <summary>Each IPv4 network this computer is on (up, not loopback, not link-local): its
    /// first three octets, and this computer's address on it.</summary>
    public static List<(string Net, IPAddress Local)> LocalNetworks()
    {
        var o = new List<(string, IPAddress)>();
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var ua in ni.GetIPProperties().UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                var ip = ua.Address.ToString();
                if (ip.StartsWith("169.254.") || ip.StartsWith("127.")) continue;
                var net = string.Join(".", ip.Split('.').Take(3));
                if (!o.Any(x => x.Item1 == net)) o.Add((net, ua.Address));
            }
        }
        return o;
    }

    private static IEnumerable<string> Hosts(string net) => Enumerable.Range(1, 254).Select(i => $"{net}.{i}");

    private static async Task ProbeCanon(List<string> nets, double seconds, Action<Found> add)
    {
        using var http = new HttpClient(new SocketsHttpHandler { UseProxy = false, ConnectTimeout = TimeSpan.FromSeconds(Math.Max(1, seconds)) })
        { Timeout = TimeSpan.FromSeconds(Math.Max(1, seconds)) };
        var tasks = nets.SelectMany(Hosts).Select(async host =>
        {
            try
            {
                using var r = await http.GetAsync($"http://{host}/-wvhttp-01-/info.cgi");
                if (r.StatusCode != HttpStatusCode.OK) return;
                var text = await r.Content.ReadAsStringAsync();
                if (!text.Contains("c.1.") && !text.Contains("s.")) return;
                add(new Found("Canon PTZ camera (proto canonXC)", CanonName(text) ?? "Canon camera", host));
            }
            catch { }
        });
        await Task.WhenAll(tasks);
    }

    private static string? CanonName(string text)
    {
        var kv = CanonLinkParse(text);
        foreach (var k in new[] { "c.1.name.utf8", "s.hardware", "s.product" })
            if (kv.TryGetValue(k, out var v) && v.Trim().Length > 0) return v.Trim();
        return null;
    }

    private static Dictionary<string, string> CanonLinkParse(string text)
    {
        var o = new Dictionary<string, string>();
        foreach (var line in text.Split('\n', '\r'))
        {
            var i = line.IndexOf(":=", StringComparison.Ordinal);
            if (i < 0) i = line.IndexOf("==", StringComparison.Ordinal);
            if (i < 0) { i = line.IndexOf('='); if (i >= 0) { o[line[..i]] = line[(i + 1)..]; continue; } }
            if (i >= 0) o[line[..i]] = line[(i + 2)..];
        }
        return o;
    }

    /// <summary>Sends the ATEM hello to every address and collects whoever answers.</summary>
    private static List<Found> ProbeATEM(List<string> nets, double wait)
    {
        var o = new HashSet<Found>();
        using var u = new UdpClient(AddressFamily.InterNetwork);
        ATEMClient.IgnoreConnReset(u);
        byte[] hello = { 0x10, 0x14, 0x53, 0xAB, 0, 0, 0, 0, 0, 0x3A, 0, 0, 0x01, 0, 0, 0, 0, 0, 0, 0 };
        foreach (var h in nets.SelectMany(Hosts))
        {
            try { u.Send(hello, hello.Length, new IPEndPoint(IPAddress.Parse(h), 9910)); } catch { }
        }
        u.Client.ReceiveTimeout = 250;
        var end = DateTime.UtcNow.AddSeconds(wait);
        while (DateTime.UtcNow < end)
        {
            try
            {
                var from = new IPEndPoint(IPAddress.Any, 0);
                var d = u.Receive(ref from);
                if (d.Length >= 12 && (d[0] & 0xF8) != 0) o.Add(new Found("ATEM switcher (atemHost)", "ATEM switcher", from.Address.ToString()));
            }
            catch { }
        }
        return o.ToList();
    }

    // MARK: mDNS

    private static readonly (string Type, string Kind)[] MdnsTypes =
    {
        ("_ndi._tcp.local", "NDI source (use the name for ndi fields; a PTZ camera here usually takes proto sonyUDP or rawTCP)"),
        ("_blackmagic._tcp.local", "Blackmagic device"),
        ("_http._tcp.local", "Web page (a camera, converter or other device with a control page)"),
    };

    /// <summary>Asks each network for the services above (one-shot mDNS queries, answered to
    /// our own port) and resolves each to an IPv4 address.</summary>
    private static List<Found> Mdns(List<IPAddress> locals, double wait)
    {
        var results = new ConcurrentDictionary<Found, byte>();
        var threads = new List<Thread>();
        foreach (var local in locals)
        {
            var t = new Thread(() =>
            {
                try
                {
                    using var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
                    s.Bind(new IPEndPoint(local, 0));
                    s.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, local.GetAddressBytes());
                    s.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 255);
                    s.ReceiveTimeout = 250;
                    var q = Query(MdnsTypes.Select(m => m.Type));
                    var group = new IPEndPoint(IPAddress.Parse("224.0.0.251"), 5353);
                    s.SendTo(q, group);
                    var end = DateTime.UtcNow.AddSeconds(wait);
                    var resent = false;
                    var buf = new byte[9000];
                    var ptr = new Dictionary<string, string>();       // instance → service type
                    var srv = new Dictionary<string, string>();       // instance → target host
                    var addr = new Dictionary<string, string>();      // host → IPv4
                    var sender = new Dictionary<string, string>();    // instance → who sent it
                    while (DateTime.UtcNow < end)
                    {
                        if (!resent && DateTime.UtcNow > end.AddSeconds(-wait / 2)) { resent = true; try { s.SendTo(q, group); } catch { } }
                        EndPoint from = new IPEndPoint(IPAddress.Any, 0);
                        int n;
                        try { n = s.ReceiveFrom(buf, ref from); } catch { continue; }
                        try { ParseMdns(buf.AsSpan(0, n).ToArray(), ((IPEndPoint)from).Address.ToString(), ptr, srv, addr, sender); } catch { }
                    }
                    foreach (var (inst, type) in ptr)
                    {
                        var kind = MdnsTypes.First(m => m.Type.Equals(type, StringComparison.OrdinalIgnoreCase)).Kind;
                        var ip = srv.TryGetValue(inst, out var host) && addr.TryGetValue(host, out var a) ? a : sender.GetValueOrDefault(inst);
                        if (ip == null || ip.StartsWith("169.254.") || ip.StartsWith("127.")) continue;
                        var name = inst.EndsWith("." + type, StringComparison.OrdinalIgnoreCase) ? inst[..^(type.Length + 1)] : inst;
                        results.TryAdd(new Found(kind, name.Replace("\\032", " "), ip), 0);
                    }
                }
                catch { }
            }) { IsBackground = true };
            threads.Add(t); t.Start();
        }
        foreach (var t in threads) t.Join(TimeSpan.FromSeconds(wait + 1));
        return results.Keys.ToList();
    }

    private static byte[] Query(IEnumerable<string> names)
    {
        var list = names.ToList();
        var o = new List<byte> { 0, 0, 0, 0, 0, (byte)list.Count, 0, 0, 0, 0, 0, 0 };
        foreach (var n in list)
        {
            foreach (var label in n.Split('.')) { var b = Encoding.UTF8.GetBytes(label); o.Add((byte)b.Length); o.AddRange(b); }
            o.Add(0);
            o.AddRange(new byte[] { 0, 12, 0x80, 1 });   // PTR, class IN with the unicast-response bit
        }
        return o.ToArray();
    }

    private static void ParseMdns(byte[] d, string from, Dictionary<string, string> ptr, Dictionary<string, string> srv,
                                  Dictionary<string, string> addr, Dictionary<string, string> sender)
    {
        if (d.Length < 12) return;
        int qd = (d[4] << 8) | d[5], an = (d[6] << 8) | d[7], ns = (d[8] << 8) | d[9], ar = (d[10] << 8) | d[11];
        int p = 12;
        for (int i = 0; i < qd; i++) { Name(d, ref p); p += 4; }
        for (int i = 0; i < an + ns + ar && p < d.Length; i++)
        {
            var name = Name(d, ref p);
            if (p + 10 > d.Length) return;
            int type = (d[p] << 8) | d[p + 1];
            int len = (d[p + 8] << 8) | d[p + 9];
            p += 10;
            var start = p;
            if (start + len > d.Length) return;
            switch (type)
            {
                case 12:
                {
                    var q = start; var inst = Name(d, ref q);
                    if (MdnsTypes.Any(m => m.Type.Equals(name, StringComparison.OrdinalIgnoreCase))) { ptr[inst] = MdnsTypes.First(m => m.Type.Equals(name, StringComparison.OrdinalIgnoreCase)).Type; sender[inst] = from; }
                    break;
                }
                case 33:
                {
                    var q = start + 6; srv[name] = Name(d, ref q);
                    break;
                }
                case 1:
                    if (len == 4) addr[name] = $"{d[start]}.{d[start + 1]}.{d[start + 2]}.{d[start + 3]}";
                    break;
            }
            p = start + len;
        }
    }

    /// <summary>A DNS name, following compression pointers.</summary>
    private static string Name(byte[] d, ref int p)
    {
        var parts = new List<string>();
        int pos = p, jumps = 0;
        bool jumped = false;
        while (pos < d.Length)
        {
            int len = d[pos];
            if (len == 0) { pos++; break; }
            if ((len & 0xC0) == 0xC0)
            {
                if (pos + 1 >= d.Length || ++jumps > 20) break;
                var to = ((len & 0x3F) << 8) | d[pos + 1];
                if (!jumped) { p = pos + 2; jumped = true; }
                pos = to;
                continue;
            }
            if (pos + 1 + len > d.Length) break;
            parts.Add(Encoding.UTF8.GetString(d, pos + 1, len));
            pos += 1 + len;
        }
        if (!jumped) p = pos;
        return string.Join(".", parts);
    }
}
