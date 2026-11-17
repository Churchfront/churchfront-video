using System.IO;
using System.Windows;
using CueATEM;

namespace CueVideo.App;

public static class Program
{
    [STAThread]
    public static int Main()
    {
        var env = Environment.GetEnvironmentVariables();
        var selfTest = env.Keys.Cast<string>().Any(k => k.StartsWith("CUEVIDEO_", StringComparison.Ordinal));
        // One copy at a time: two would fight over the cameras and the control port.
        using var single = new Mutex(true, selfTest ? "ChurchfrontVideo-selftest" : "ChurchfrontVideo-single", out var first);
        if (!first)
        {
            MessageBox.Show("Churchfront Video is already open.", "Churchfront Video", MessageBoxButton.OK, MessageBoxImage.Information);
            return 0;
        }

        var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        MainThread.Poster = a => app.Dispatcher.BeginInvoke(a);
        MainThread.IsMainCheck = () => app.Dispatcher.CheckAccess();
        app.DispatcherUnhandledException += (_, e) => { Log(e.Exception); e.Handled = true; };
        AppDomain.CurrentDomain.UnhandledException += (_, e) => { if (e.ExceptionObject is Exception x) Log(x); };

        var booth = Booth.Shared;
        // Self-tests name their own switcher; otherwise the config file says where it is.
        if (Environment.GetEnvironmentVariable("CUEVIDEO_HOST") is string host && host.Length > 0)
            booth.Atem.Connect(host, int.TryParse(Environment.GetEnvironmentVariable("CUEVIDEO_PORT"), out var p) ? p : 9910);
        if (Environment.GetEnvironmentVariable("CUEVIDEO_FAKECAMS") is string fake)
        {
            var cams = new List<PTZCamera>();
            var names = new[] { "Center", "Left", "Right" };
            for (int i = 0; i < names.Length; i++)
                cams.Add(new PTZCamera
                {
                    Name = names[i], Host = fake, Port = (ushort)(52381 + i), Proto = VISCAProtocol.SonyUDP, AtemInput = i + 1,
                    PresetNames = new() { [1] = "Pulpit", [2] = "Wide", [3] = "Band" },
                });
            booth.Ptz.Cameras = cams;
        }
        booth.Start();
        Snapshots.Imaging = CanonFeedHub.Imaging;

        var win = new MainWindow();
        ControlTools.ShowWindow = w => win.ShowView(w);
        booth.BringToFront = () => win.ShowView("main");
        // Claude's way in (through cuevideo-mcp). Not during self-tests, which may run beside the real app.
        if (!booth.Store.ReadOnly) ControlServer.Shared.Start();
        if (Environment.GetEnvironmentVariable("CUEVIDEO_VIEW") is string v)
        {
            var parts = v.Split(':');
            if (parts[0] == "engineer") win.ShowView(parts.Length > 1 ? parts[1] : "setup");
        }

        // Quitting stops every camera this app is moving and waits a moment for the stops to
        // reach the cameras: a Canon keeps turning at the last speed it was given.
        app.Exit += (_, _) =>
        {
            ControlServer.Shared.Stop();
            booth.Ptz.Shutdown();
        };
        app.MainWindow = win;
        win.Show();
        return app.Run();
    }

    private static void Log(Exception e)
    {
        try
        {
            Directory.CreateDirectory(ConfigStore.Folder);
            File.AppendAllText(Path.Combine(ConfigStore.Folder, "errors.log"), $"{DateTime.Now:u} {e}\n\n");
        }
        catch { }
        try { Booth.Shared.Ptz.StopAllManual(); } catch { }
    }
}
