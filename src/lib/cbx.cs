// lib/cbx.cs - the compiled client half of the command proxy.
//
// A command line costs about 2.5 s, and roughly 1 s of that is one PowerShell start even when
// the resident answers over the pipe (lib/proxy.ps1). This client costs about 150 ms: it is
// started by clipboard.cmd before any PowerShell exists, builds the same request frame the
// PowerShell client builds, and prints the answer.
//
// It is optional by design. clipboard.cmd only tries it when cbx.exe sits next to
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

static class Cbx
{
  // "not proxied": the caller has to run the command the slow way
  const int Fallback = 100;
  const int ConnectMs = 120;
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
    if (Array.IndexOf(Direct, name) >= 0) return Fallback;

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

  // commands the resident never answers: they change settings, move the store, touch the
  // registry, or are the resident itself. Same list as $script:ProxyDirectOnly in proxy.ps1.
  static readonly string[] Direct = new string[] {
    "config", "themes", "install", "uninstall", "serve", "stop", "ui", "edit",
    "export", "import", "backup", "restore", "migrate"
  };

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

  // one connect, one request, one reply; null when the resident is not there
  static string Session(string request)
  {
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
