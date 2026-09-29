using System;
using System.Collections.Generic;
using System.Linq;
using LibrePods.WinUI.Ipc;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace LibrePods.WinUI.Controls;

/// Heart-rate monitoring toggle + BPM readout + a mini graph of the recent readings
/// (AirPods Pro 3, experimental). The toggle is user-driven — the snapshot has no
/// "monitoring on" flag, only the BPM value — so Update touches only the reading.
public sealed partial class HeartRateCard : UserControl
{
    // Same shape as HeartRateMiniGraph in upstream PR #702.
    private const int MaxGraphSamples = 24;
    private const double MinGraphBpmSpan = 20;

    public DaemonClient? Client { get; set; }

    private bool _applying;
    private ushort? _latestBpm;
    private readonly List<ushort> _samples = new();
    // The daemon only pushes a snapshot when the BPM *changes*, so sample the latest
    // value at the stream's own 1 Hz cadence instead of once per snapshot — a steady
    // pulse then still draws as a flat line rather than a single point.
    private readonly DispatcherTimer _sampler = new() { Interval = TimeSpan.FromSeconds(1) };

    public HeartRateCard()
    {
        InitializeComponent();
        _sampler.Tick += (_, _) => Sample();
        Unloaded += (_, _) => _sampler.Stop();
        Loaded += (_, _) => { if (HeartRateSwitch.IsOn) _sampler.Start(); DrawGraph(); };
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
        _samples.Clear();
        HeartRateBpm.Text = "—";
        DrawGraph();
    }

    private void Sample()
    {
        if (_latestBpm is not ushort bpm) return;
        _samples.Add(bpm);
        if (_samples.Count > MaxGraphSamples) _samples.RemoveAt(0);
        DrawGraph();
    }

    private void HeartRateGraph_SizeChanged(object sender, SizeChangedEventArgs e) => DrawGraph();

    /// Recent readings scaled into 0..1 around their centre, with a minimum span so a
    /// 1-bpm wobble doesn't fill the whole height (normalizedRecentHeartRates, PR #702).
    private List<double> NormalizedSamples()
    {
        if (_samples.Count == 0) return new();
        double min = _samples.Min(b => (int)b), max = _samples.Max(b => (int)b);
        double span = Math.Max(max - min, MinGraphBpmSpan);
        double lower = (min + max) / 2 - span / 2;
        return _samples.Select(b => Math.Clamp((b - lower) / span, 0, 1)).ToList();
    }

    private void DrawGraph()
    {
        var canvas = HeartRateGraph;
        canvas.Children.Clear();
        double w = canvas.ActualWidth > 0 ? canvas.ActualWidth : canvas.Width;
        double h = canvas.ActualHeight > 0 ? canvas.ActualHeight : canvas.Height;
        if (double.IsNaN(w) || double.IsNaN(h) || w <= 0 || h <= 0) return;

        // Reuse the brushes XAML already resolved for the current theme.
        var accent = HeartRateBpm.Foreground;
        var guide = HeartRateGraphCaption.Foreground;
        double left = 2, right = w - 2, top = 4, bottom = h - 4;
        double height = bottom - top;

        var values = NormalizedSamples();
        if (values.Count == 0)
        {
            // No readings yet: three faint guide lines.
            foreach (var y in new[] { top, (top + bottom) / 2, bottom })
                canvas.Children.Add(new Line { X1 = left, X2 = right, Y1 = y, Y2 = y, Stroke = guide, StrokeThickness = 1, Opacity = 0.5 });
            return;
        }

        canvas.Children.Add(new Line { X1 = left, X2 = right, Y1 = bottom, Y2 = bottom, Stroke = guide, StrokeThickness = 1, Opacity = 0.5 });

        // Right-aligned so the newest reading always sits at the right edge, even
        // before the window has filled up.
        double step = (right - left) / (MaxGraphSamples - 1);
        double x0 = right - step * (values.Count - 1);
        var line = new Polyline { Stroke = accent, StrokeThickness = 2, StrokeLineJoin = PenLineJoin.Round };
        for (int i = 0; i < values.Count; i++)
        {
            double x = x0 + i * step, y = bottom - values[i] * height;
            canvas.Children.Add(new Line { X1 = x, X2 = x, Y1 = bottom, Y2 = y, Stroke = accent, StrokeThickness = 1, Opacity = 0.18 });
            line.Points.Add(new Point(x, y));
        }
        if (values.Count > 1) canvas.Children.Add(line);

        double lastY = bottom - values[^1] * height;
        var dot = new Ellipse { Width = 5, Height = 5, Fill = accent };
        Canvas.SetLeft(dot, right - 2.5);
        Canvas.SetTop(dot, lastY - 2.5);
        canvas.Children.Add(dot);
    }
}
