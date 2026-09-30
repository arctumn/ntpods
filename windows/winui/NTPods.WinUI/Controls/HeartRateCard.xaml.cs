using System;
using System.Collections.Generic;
using System.Linq;
using NTPods.WinUI.Ipc;
using NTPods.WinUI.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace NTPods.WinUI.Controls;

/// Heart-rate monitoring toggle + BPM readout + a full-width graph (AirPods Pro 3).
/// The graph shows either the live stream (last minute) or a past session read
/// from the daemon's heart-rate database. The toggle is user-driven — the snapshot
/// has no "monitoring on" flag, only the BPM value — so Update touches only the reading.
public sealed partial class HeartRateCard : UserControl
{
    // Live: the last minute at the stream's 1 Hz. Scaling follows HeartRateMiniGraph
    // in upstream PR #702: centred on the window, with a minimum span so a 1-bpm
    // wobble doesn't fill the whole height.
    private const int MaxGraphSamples = 60;
    private const double MinGraphBpmSpan = 20;

    public DaemonClient? Client { get; set; }

    private bool _applying;
    private ushort? _latestBpm;
    private readonly List<(DateTime At, ushort Bpm)> _live = new();
    // The picker's entries after "Live" (index 0); null = live.
    private readonly List<HeartRateHistory.Session> _sessions = new();
    private HeartRateHistory.Session? _session;
    private List<(DateTime At, ushort Bpm)> _sessionSamples = new();
    private bool _populating;
    private Point? _hover;
    // The daemon only pushes a snapshot when the BPM *changes*, so sample the latest
    // value at the stream's own 1 Hz cadence instead of once per snapshot — a steady
    // pulse then still draws as a flat line rather than a single point.
    private readonly DispatcherTimer _sampler = new() { Interval = TimeSpan.FromSeconds(1) };

    public HeartRateCard()
    {
        InitializeComponent();
        _sampler.Tick += (_, _) => Sample();
        Unloaded += (_, _) => _sampler.Stop();
        Loaded += (_, _) =>
        {
            if (HeartRateSwitch.IsOn) _sampler.Start();
            PopulatePicker();
            DrawGraph();
        };
        Loc.Instance.PropertyChanged += (_, _) => DispatcherQueue.TryEnqueue(() => { PopulatePicker(); DrawGraph(); });
    }

    /// Render the BPM value from a daemon Snapshot (no reading → em dash).
    public void Update(Snapshot s)
    {
        _applying = true;
        try
        {
            _latestBpm = s.HeartRate;
            HeartRateBpm.Text = s.HeartRate is ushort bpm ? bpm.ToString() : "—";
            if (s.HeartRate is not null && !_sampler.IsEnabled) _sampler.Start();
        }
        finally
        {
            _applying = false;
        }
    }

    private void HeartRate_Toggled(object sender, RoutedEventArgs e)
    {
        if (_applying) return;
        Client?.SetHeartRate(HeartRateSwitch.IsOn);
        if (HeartRateSwitch.IsOn)
        {
            _sampler.Start();
            return;
        }
        _sampler.Stop();
        _latestBpm = null;
        _live.Clear();
        HeartRateBpm.Text = "—";
        DrawGraph();
    }

    private void Sample()
    {
        if (_latestBpm is not ushort bpm) return;
        _live.Add((DateTime.Now, bpm));
        if (_live.Count > MaxGraphSamples) _live.RemoveAt(0);
        if (_session is null) DrawGraph();
    }

    // ---- history picker ----------------------------------------------------

    private void PopulatePicker()
    {
        _populating = true;
        try
        {
            long? keep = _session?.Id;
            _sessions.Clear();
            _sessions.AddRange(HeartRateHistory.Sessions());
            HistoryPicker.Items.Clear();
            HistoryPicker.Items.Add(Loc.Instance.Get("HeartRateHistoryLive"));
            foreach (var s in _sessions)
            {
                var minutes = Math.Max(1, (int)Math.Round(((s.End ?? s.Start) - s.Start).TotalMinutes));
                HistoryPicker.Items.Add(Loc.Instance.Get("HeartRateHistorySession", s.Start, minutes, s.Avg));
            }
            int idx = keep is long id ? _sessions.FindIndex(s => s.Id == id) + 1 : 0;
            HistoryPicker.SelectedIndex = idx > 0 ? idx : 0;
            if (idx <= 0) _session = null;
        }
        finally
        {
            _populating = false;
        }
    }

    private void HistoryPicker_DropDownOpened(object sender, object e) => PopulatePicker();

    private void HistoryPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_populating) return;
        int i = HistoryPicker.SelectedIndex;
        _session = i >= 1 && i - 1 < _sessions.Count ? _sessions[i - 1] : null;
        _sessionSamples = _session is { } s ? HeartRateHistory.Samples(s.Id) : new();
        _hover = null;
        DrawGraph();
    }

    // ---- graph -----------------------------------------------------------------

    private void HeartRateGraph_SizeChanged(object sender, SizeChangedEventArgs e) => DrawGraph();

    private void HeartRateGraph_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        _hover = e.GetCurrentPoint(HeartRateGraph).Position;
        DrawGraph();
    }

    private void HeartRateGraph_PointerExited(object sender, PointerRoutedEventArgs e)
    {
        _hover = null;
        DrawGraph();
    }

    /// A long session has far more readings than pixels: average them into at most
    /// `buckets` points so the graph stays light and readable.
    private static List<(DateTime At, ushort Bpm)> Downsample(List<(DateTime At, ushort Bpm)> data, int buckets)
    {
        if (data.Count <= buckets || buckets < 2) return data;
        var outp = new List<(DateTime, ushort)>(buckets);
        for (int b = 0; b < buckets; b++)
        {
            int from = b * data.Count / buckets, to = (b + 1) * data.Count / buckets;
            if (to <= from) continue;
            var slice = data.GetRange(from, to - from);
            outp.Add((slice[slice.Count / 2].At, (ushort)Math.Round(slice.Average(s => (int)s.Bpm))));
        }
        return outp;
    }

    private void DrawGraph()
    {
        var canvas = HeartRateGraph;
        canvas.Children.Clear();
        double w = canvas.ActualWidth, h = canvas.ActualHeight;
        if (w <= 0 || h <= 0) return;

        // Reuse the brushes XAML already resolved for the current theme.
        var accent = HeartRateBpm.Foreground;
        var guide = GraphAxisMax.Foreground;
        double left = 2, right = w - 2, top = 6, bottom = h - 6, height = bottom - top;

        foreach (var gy in new[] { top, (top + bottom) / 2, bottom })
            canvas.Children.Add(new Line
            {
                X1 = left, X2 = right, Y1 = gy, Y2 = gy, Stroke = guide, StrokeThickness = 1, Opacity = 0.35,
                StrokeDashArray = new DoubleCollection { 3, 3 },
            });

        bool live = _session is null;
        var raw = live ? _live : _sessionSamples;
        if (raw.Count == 0)
        {
            GraphAxisMax.Text = GraphAxisMid.Text = GraphAxisMin.Text = "";
            HeartRateGraphCaption.Text = Loc.Instance.Get("HeartRateGraphEmpty");
            return;
        }

        // Scale and stats come from every reading, not the downsampled points.
        int min = raw.Min(s => (int)s.Bpm), max = raw.Max(s => (int)s.Bpm);
        int avg = (int)Math.Round(raw.Average(s => (int)s.Bpm));
        double span = Math.Max(max - min, MinGraphBpmSpan);
        double lower = (min + max) / 2.0 - span / 2;
        GraphAxisMax.Text = Math.Round(lower + span).ToString();
        GraphAxisMid.Text = Math.Round(lower + span / 2).ToString();
        GraphAxisMin.Text = Math.Round(lower).ToString();
        HeartRateGraphCaption.Text = live
            ? Loc.Instance.Get("HeartRateGraphStats", raw.Count, min, avg, max)
            : Loc.Instance.Get("HeartRateSessionStats", raw.Count, min, avg, max);

        var pts = live ? raw : Downsample(raw, (int)Math.Max(2, (right - left) / 3));
        // Live: fixed one-minute slots, right-aligned so the newest reading sits at
        // the right edge. A session: stretched across the full width.
        int slots = live ? MaxGraphSamples : pts.Count;
        double step = slots > 1 ? (right - left) / (slots - 1) : 0;
        double x0 = right - step * (pts.Count - 1);
        double Y(ushort bpm) => bottom - Math.Clamp((bpm - lower) / span, 0, 1) * height;

        var line = new Polyline { Stroke = accent, StrokeThickness = 2, StrokeLineJoin = PenLineJoin.Round };
        bool bars = step >= 3; // one faint bar per reading while they're still distinguishable
        for (int i = 0; i < pts.Count; i++)
        {
            double x = x0 + i * step, y = Y(pts[i].Bpm);
            if (bars) canvas.Children.Add(new Line { X1 = x, X2 = x, Y1 = bottom, Y2 = y, Stroke = accent, StrokeThickness = 1, Opacity = 0.18 });
            line.Points.Add(new Point(x, y));
        }
        if (pts.Count > 1) canvas.Children.Add(line);
        AddDot(canvas, x0 + step * (pts.Count - 1), Y(pts[^1].Bpm), accent, 5);

        if (_hover is Point p && p.X >= x0 - step / 2)
        {
            // The reading nearest the pointer: a cursor line, a dot, and its value.
            int i = step > 0 ? Math.Clamp((int)Math.Round((p.X - x0) / step), 0, pts.Count - 1) : 0;
            var (at, bpm) = pts[i];
            double x = x0 + i * step, y = Y(bpm);
            canvas.Children.Add(new Line { X1 = x, X2 = x, Y1 = top, Y2 = bottom, Stroke = accent, StrokeThickness = 1, Opacity = 0.6 });
            AddDot(canvas, x, y, accent, 8);

            string text = live
                ? Loc.Instance.Get("HeartRateGraphPoint", bpm, Math.Max(0, (int)Math.Round((DateTime.Now - at).TotalSeconds)))
                : Loc.Instance.Get("HeartRateGraphPointAt", bpm, at);
            var label = new Border
            {
                Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
                BorderBrush = guide,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(6, 2, 6, 2),
                Child = new TextBlock { Text = text, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] },
            };
            label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            double lw = label.DesiredSize.Width;
            Canvas.SetLeft(label, Math.Clamp(x - lw / 2, 0, Math.Max(0, w - lw)));
            Canvas.SetTop(label, y - top > 26 ? y - 26 : y + 8);
            canvas.Children.Add(label);
        }
    }

    private static void AddDot(Canvas canvas, double x, double y, Brush fill, double size)
    {
        var dot = new Ellipse { Width = size, Height = size, Fill = fill };
        Canvas.SetLeft(dot, x - size / 2);
        Canvas.SetTop(dot, y - size / 2);
        canvas.Children.Add(dot);
    }
}
