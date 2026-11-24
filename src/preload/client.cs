// preload\client.cs - the compiled client half of the command proxy.
//
// A command line costs about 2.5 s, and roughly 1 s of that is one PowerShell start even when
// the resident answers over the pipe (lib/proxy.ps1). This client costs about 150 ms: it is
// started by clipboard.cmd before any PowerShell exists, builds the same request frame the
// PowerShell client builds, and prints the answer.
//
// It is the only file here that builds an executable: cli.ini [entry.client] compiles it into
// src\client.exe (via tools\bundler\plugins\60-cs-compile.ps1), while [entry.main] turns
// src\main into lib\assembly\clipboard.dll.
//
// It is optional by design. clipboard.cmd only tries it when client.exe sits next to
// clipboard.ps1, and it treats exit code 100 as "nothing happened, run PowerShell instead", so
// a copy without the executable behaves exactly as it did before.
//
// Nothing here may print to stdout unless it is the answer: the caller passes stdout through.
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;

static class Client
{
  // "not proxied": the caller has to run the command the slow way
  const int Fallback = 100;
  // A local named pipe either accepts at once or has no listener at all, so the wait only
  // covers a resident that is busy serving the previous request. Forty milliseconds keeps
  // that, and a machine with no resident running pays 80 ms less on every command before it
  // falls back to PowerShell.
  const int ConnectMs = 40;
  const int IOMs = 2000;
  const int FrameLimit = 1048576;

  static int Main(string[] raw)
  {
    // raw[0] is the tool root (the folder clipboard.ps1 lives in); the rest is the command
    // line exactly as the user typed it
    if (raw.Length < 2) return Fallback;
    string root = RootOf(raw[0]);
    if (root.Length == 0) return Fallback;

    List<string> pos = new List<string>();
    List<string> switches = new List<string>();
    int count = 0;
    for (int i = 1; i < raw.Length; i++)
    {
      string a = raw[i];
      // only "-" starts a switch: a value can begin with a slash (a path), and PowerShell does
      // not accept "/Name" either. Anything not understood here goes to the slow path, which
      // parses the real parameter set.
      if (a.Length > 1 && a[0] == '-')
      {
        switch (a.Substring(1).ToLowerInvariant())
        {
          case "count":
            if (i + 1 >= raw.Length) return Fallback;
            if (!int.TryParse(raw[++i], out count)) return Fallback;
            break;
          case "purge": switches.Add("Purge"); break;
          case "all": switches.Add("All"); break;
          case "media": switches.Add("Media"); break;
          case "replace": switches.Add("Replace"); break;
          case "h":
          case "help":
          case "noproxy":
          case "library":
            return Fallback;
          default:
            return Fallback;
        }
      }
      else pos.Add(a);
    }

    // the dispatcher takes four positional values and nothing else
    if (pos.Count == 0 || pos.Count > 4) return Fallback;
    string cmd = pos[0];
    string name = cmd.ToLowerInvariant();
    if (name.Length == 0) return Fallback;
    // What may cross is one file, ipc\channels.ini, shared with the PowerShell half; a name
    // it does not list is a plugin verb, which crosses when the file says so.
    Channels channels = Channels.Load(Path.Combine(root, "ipc", "channels.ini"));
    if (!channels.Allows(name)) return Fallback;

    string value = pos.Count > 1 ? pos[1] : "";
    string sub = pos.Count > 2 ? pos[2] : "";
    string arg = pos.Count > 3 ? pos[3] : "";
    // `put` with no text on the command line takes it from stdin, exactly like the entry file
    // does before it asks the resident. An empty entry stays an empty entry.
    if (name == "put" && value.Length == 0)
    {
      value = Strip(ReadStdin());
    }

    string request = Frame(root, cmd, value, sub, arg, count, switches);
    string reply;
    try { reply = Session(request); }
    catch { return Fallback; }
    if (reply == null) return Fallback;

    // 2 = another tool root answered the pipe, 3 = it does not know this command. Both are
    // refusals: print nothing and let the caller run the command itself.
    string code = Str(reply, "code");
    if (code == "2" || code == "3") return Fallback;
    string text = Str(reply, "out");
    if (code != "0")
    {
      string err = Str(reply, "err");
      if (err.Length > 0) Console.Error.WriteLine("[x] " + err);
      return 1;
    }
    byte[] bytes = new UTF8Encoding(false).GetBytes(text);
    using (Stream stdout = Console.OpenStandardOutput()) stdout.Write(bytes, 0, bytes.Length);
    return 0;
  }

  // The channel table, read from ipc\channels.ini: one [channel.<name>] section per built-in
  // command with Remote=1 (the resident answers it) or Remote=0 (the command line runs it), and
  // [channels] Plugins=1 to let a verb with no section of its own cross. The same file is read
  // by lib\proxy.ps1, so neither half can drift from the other.
  //
  // A missing or unreadable file refuses everything: this client then returns Fallback and the
  // caller runs the command the slow way, which is the same answer a second later.
  sealed class Channels
  {
    readonly Dictionary<string, bool> remote = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
    bool plugins;
    static readonly Channels None = new Channels();

    public bool Allows(string name)
    {
      bool listed;
      if (remote.TryGetValue(name, out listed)) return listed;
      if (!plugins) return false;
      return Verb(name);
    }

    // the shape lib\proxy.ps1 accepts: a lower case verb, nothing else
    static bool Verb(string s)
    {
      if (s.Length == 0) return false;
      char c = s[0];
      if (!(c >= 'a' && c <= 'z')) return false;
      foreach (char ch in s)
      {
        bool ok = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-';
        if (!ok) return false;
      }
      return true;
    }

    public static Channels Load(string path)
    {
      try
      {
        if (!File.Exists(path)) return None;
        Channels table = new Channels();
        string section = "";
        foreach (string raw in File.ReadAllLines(path))
        {
          string t = raw.Trim();
          if (t.Length < 2 || t[0] == '#' || t[0] == ';') continue;
          if (t[0] == '[' && t[t.Length - 1] == ']')
          {
            section = t.Substring(1, t.Length - 2).Trim().ToLowerInvariant();
            continue;
          }
          int eq = t.IndexOf('=');
          if (eq < 1) continue;
          string key = t.Substring(0, eq).Trim().ToLowerInvariant();
          string value = t.Substring(eq + 1).Trim().ToLowerInvariant();
          bool on = value == "1" || value == "true" || value == "yes" || value == "on";
          if (section == "channels" && key == "plugins") { table.plugins = on; continue; }
          if (!section.StartsWith("channel.") || section.Length <= 8) continue;
          if (key == "remote") table.remote[section.Substring(8)] = on;
        }
        return table;
      }
      catch { return None; }
    }
  }

  // the caller passes the folder as "%~dp0." (a trailing separator would escape the closing
  // quote in the batch file); the resident compares against the folder the way
  // Split-Path -Parent returns it, without a trailing separator
  static string RootOf(string raw)
  {
    string s = (raw ?? "").Trim();
    if (s.Length == 0) return "";
    s = s.Replace('/', '\\');
    while (s.EndsWith("\\.", StringComparison.Ordinal)) s = s.Substring(0, s.Length - 2);
    s = s.TrimEnd('\\');
    if (s.Length == 2 && s[1] == ':') s = s + "\\";   // a bare drive root keeps its slash
    return s;
  }

  static string ReadStdin()
  {
    try { using (Stream stdin = Console.OpenStandardInput()) return new StreamReader(stdin, Encoding.UTF8).ReadToEnd(); }
    catch { return ""; }
  }

  // the entry file drops the one line break a shell appends to piped text
  static string Strip(string s)
  {
    if (s == null) return "";
    if (s.EndsWith("\r\n")) return s.Substring(0, s.Length - 2);
    if (s.EndsWith("\n") || s.EndsWith("\r")) return s.Substring(0, s.Length - 1);
    return s;
  }

  static string Frame(string root, string cmd, string value, string sub, string arg, int count, List<string> switches)
  {
    StringBuilder sb = new StringBuilder(256);
    sb.Append("{\"v\":1,\"root\":").Append(J(root));
    sb.Append(",\"cmd\":").Append(J(cmd));
    sb.Append(",\"value\":").Append(J(value));
    sb.Append(",\"sub\":").Append(J(sub));
    sb.Append(",\"arg\":").Append(J(arg));
    sb.Append(",\"count\":").Append(count.ToString("0"));
    sb.Append(",\"switches\":[");
    for (int i = 0; i < switches.Count; i++)
    {
      if (i > 0) sb.Append(',');
      sb.Append(J(switches[i]));
    }
    // bound names only matter to `config set`, which is never proxied
    sb.Append("],\"bound\":[]}");
    return sb.ToString();
  }

  // The daemon holds this mutex for exactly as long as it runs (base.ps1: $MutexName), so it
  // answers "is there anyone to talk to" without touching the pipe. A mutex whose owner died
  // reports abandoned, which still means try the pipe.
  static bool ResidentUp()
  {
    try
    {
      bool created = false;
      using (Mutex m = new Mutex(false, "Local\\clipboard.daemon", out created))
      {
        bool free = false;
        try { free = m.WaitOne(0); }
        catch (AbandonedMutexException) { return true; }
        if (free) { m.ReleaseMutex(); return false; }
        return true;
      }
    }
    catch { return true; }
  }

  // one connect, one request, one reply; null when the resident is not there
  static string Session(string request)
  {
    if (!ResidentUp()) { return null; }
    string name = PipeName();
    using (NamedPipeClientStream client = new NamedPipeClientStream(".", name, PipeDirection.InOut))
    {
      try { client.Connect(ConnectMs); } catch { return null; }
      byte[] body = Encoding.UTF8.GetBytes(request);
      if (body.Length > FrameLimit) return null;
      byte[] header = BitConverter.GetBytes(body.Length);
      client.Write(header, 0, 4);
      client.Write(body, 0, body.Length);
      client.Flush();
      byte[] h = new byte[4];
      if (!Read(client, h, 0, 4)) return null;
      int len = BitConverter.ToInt32(h, 0);
      if (len <= 0 || len > FrameLimit) return null;
      byte[] payload = new byte[len];
      if (!Read(client, payload, 0, len)) return null;
      return Encoding.UTF8.GetString(payload);
    }
  }

  static bool Read(Stream s, byte[] buf, int offset, int count)
  {
    DateTime deadline = DateTime.UtcNow.AddMilliseconds(IOMs);
    while (count > 0)
    {
      int n = s.Read(buf, offset, count);
      if (n <= 0) return false;
      offset += n;
      count -= n;
      if (DateTime.UtcNow > deadline) return false;
    }
    return true;
  }

  // the same name the resident listens on: hash of the account SID, first eight bytes. A
  // request also names its tool root, and the resident only answers its own.
  static string PipeName()
  {
    string sid;
    try { sid = WindowsIdentity.GetCurrent().User.Value; }
    catch { sid = Environment.UserName; }
    using (SHA256 sha = SHA256.Create())
    {
      byte[] hash = sha.ComputeHash(Encoding.UTF8.GetBytes(sid));
      StringBuilder sb = new StringBuilder("clipboard-cmd-", 32);
      for (int i = 0; i < 8; i++) sb.Append(hash[i].ToString("x2"));
      return sb.ToString();
    }
  }

  // a JSON string literal. ConvertTo-Json on the other side escapes non-ASCII into \uXXXX,
  // which Str() undoes; here the text goes out as UTF-8, which JSON allows.
  static string J(string s)
  {
    if (s == null) s = "";
    StringBuilder sb = new StringBuilder(s.Length + 2);
    sb.Append('"');
    foreach (char c in s)
    {
      switch (c)
      {
        case '"': sb.Append("\\\""); break;
        case '\\': sb.Append("\\\\"); break;
        case '\n': sb.Append("\\n"); break;
        case '\r': sb.Append("\\r"); break;
        case '\t': sb.Append("\\t"); break;
        case '\b': sb.Append("\\b"); break;
        case '\f': sb.Append("\\f"); break;
        default:
          if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
          else sb.Append(c);
          break;
      }
    }
    sb.Append('"');
    return sb.ToString();
  }

  // one top-level field of the reply, unescaped; "" when it is missing
  static string Str(string json, string name)
  {
    string key = "\"" + name + "\":";
    int i = json.IndexOf(key, StringComparison.Ordinal);
    if (i < 0) return "";
    i += key.Length;
    while (i < json.Length && json[i] == ' ') i++;
    if (i < json.Length && json[i] == '"')
    {
      StringBuilder sb = new StringBuilder();
      i++;
      while (i < json.Length)
      {
        char c = json[i];
        if (c == '"') break;
        if (c != '\\') { sb.Append(c); i++; continue; }
        i++;
        if (i >= json.Length) break;
        char e = json[i++];
        switch (e)
        {
          case 'n': sb.Append('\n'); break;
          case 'r': sb.Append('\r'); break;
          case 't': sb.Append('\t'); break;
          case 'b': sb.Append('\b'); break;
          case 'f': sb.Append('\f'); break;
          case 'u':
            if (i + 4 <= json.Length)
            {
              int code;
              if (int.TryParse(json.Substring(i, 4), System.Globalization.NumberStyles.HexNumber, null, out code))
                sb.Append((char)code);
              i += 4;
            }
            break;
          default: sb.Append(e); break;
        }
      }
      return sb.ToString();
    }
    int start = i;
    while (i < json.Length && (char.IsDigit(json[i]) || json[i] == '-')) i++;
    return json.Substring(start, i - start);
  }
}
