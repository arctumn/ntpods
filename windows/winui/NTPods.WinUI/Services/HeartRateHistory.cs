using System;
using System.Collections.Generic;
using System.IO;
using Microsoft.Data.Sqlite;

namespace NTPods.WinUI.Services;

/// Read-only access to the daemon's heart-rate tracking database
/// (%LOCALAPPDATA%\NTPods\heart-rate.sqlite3, written by ntpodsd's hrdb.rs).
/// The daemon owns the writes; the app only reads, and WAL lets both run at once.
public static class HeartRateHistory
{
    public sealed record Session(long Id, DateTime Start, DateTime? End, int Count, int Min, int Avg, int Max);

    private static string DbPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NTPods", "heart-rate.sqlite3");

    private static DateTime FromUnixMs(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(ms).LocalDateTime;

    private static SqliteConnection? Open()
    {
        if (!File.Exists(DbPath)) return null;
        var c = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = DbPath, Mode = SqliteOpenMode.ReadOnly }.ToString());
        c.Open();
        return c;
    }

    /// Most recent sessions that have readings, newest first.
    public static List<Session> Sessions(int limit = 50)
    {
        var list = new List<Session>();
        try
        {
            using var c = Open();
            if (c is null) return list;
            using var cmd = c.CreateCommand();
            cmd.CommandText =
                @"SELECT s.id, s.started_at, s.ended_at, COUNT(x.id), MIN(x.bpm), AVG(x.bpm), MAX(x.bpm), MAX(x.ts)
                  FROM sessions s JOIN samples x ON x.session_id = s.id
                  GROUP BY s.id ORDER BY s.started_at DESC LIMIT $limit";
            cmd.Parameters.AddWithValue("$limit", limit);
            using var r = cmd.ExecuteReader();
            while (r.Read())
            {
                // A session left open (daemon stopped mid-run) ends at its last reading.
                long? end = r.IsDBNull(2) ? r.GetInt64(7) : r.GetInt64(2);
                list.Add(new Session(r.GetInt64(0), FromUnixMs(r.GetInt64(1)), end is long e ? FromUnixMs(e) : null,
                    r.GetInt32(3), r.GetInt32(4), (int)Math.Round(r.GetDouble(5)), r.GetInt32(6)));
            }
        }
        catch (Exception) { /* no DB yet / locked mid-checkpoint: show no history */ }
        return list;
    }

    /// Every reading of one session, oldest first.
    public static List<(DateTime At, ushort Bpm)> Samples(long sessionId)
    {
        var list = new List<(DateTime, ushort)>();
        try
        {
            using var c = Open();
            if (c is null) return list;
            using var cmd = c.CreateCommand();
            cmd.CommandText = "SELECT ts, bpm FROM samples WHERE session_id = $id ORDER BY ts";
            cmd.Parameters.AddWithValue("$id", sessionId);
            using var r = cmd.ExecuteReader();
            while (r.Read()) list.Add((FromUnixMs(r.GetInt64(0)), (ushort)r.GetInt32(1)));
        }
        catch (Exception) { }
        return list;
    }
}
