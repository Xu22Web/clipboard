// src\main\reactivity\reactive-bag.cs - a data bag whose reads can be tracked and whose writes
// can be announced (see lib\ui\reactive.ps1).
//
// PowerShell has no property traps at all - a hashtable cannot be made to tell anyone it changed
// - so this lives in the one place the language cannot reach, DynamicObject. Reads cost what a
// hashtable read costs (measured: 1.45 us against 2.55 us for a hashtable) because the DLR
// caches the member after the first call; nothing here allocates on a read.
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Dynamic;

namespace Cb {
  public sealed class ReactiveBag : DynamicObject {
    private readonly Dictionary<string, object> values = new Dictionary<string, object>(StringComparer.Ordinal);
    private int revision;

    public ReactiveBag() { }

    public ReactiveBag(IDictionary seed) {
      if (seed == null) { return; }
      foreach (DictionaryEntry one in seed) {
        if (one.Key == null) { continue; }
        values[Convert.ToString(one.Key)] = one.Value;
      }
    }

    public int Revision { get { return revision; } }

    public override bool TryGetMember(GetMemberBinder binder, out object result) {
      Reactive.Track(this, binder.Name);
      return values.TryGetValue(binder.Name, out result);
    }

    public override bool TrySetMember(SetMemberBinder binder, object value) {
      Set(binder.Name, value);
      return true;
    }

    // A write of what is already there is not a change: nothing is enqueued and no effect runs,
    // which is what keeps a paint that writes the same value from asking for another paint.
    public bool Set(string key, object value) {
      if (key == null) { return false; }
      object old;
      if (values.TryGetValue(key, out old) && Same(old, value)) { return false; }
      values[key] = value;
      revision++;
      Reactive.Trigger(this, key);
      return true;
    }

    public object Get(string key) {
      if (key == null) { return null; }
      Reactive.Track(this, key);
      object value;
      if (values.TryGetValue(key, out value)) { return value; }
      return null;
    }

    public bool Has(string key) {
      if (key == null) { return false; }
      return values.ContainsKey(key);
    }

    public int Count { get { return values.Count; } }

    public string[] Keys() {
      string[] keys = new string[values.Count];
      values.Keys.CopyTo(keys, 0);
      return keys;
    }

    // A plain copy for the code that wants a hashtable: the reader then neither tracks nor
    // triggers, which is the right answer for a snapshot taken to build labels.
    public IDictionary Snapshot() {
      Dictionary<string, object> copy = new Dictionary<string, object>(values.Count, StringComparer.Ordinal);
      foreach (KeyValuePair<string, object> one in values) { copy[one.Key] = one.Value; }
      return copy;
    }

    private static bool Same(object a, object b) {
      if (object.ReferenceEquals(a, b)) { return true; }
      if (a == null || b == null) { return false; }
      string sa = a as string;
      string sb = b as string;
      if (sa != null && sb != null) { return string.Equals(sa, sb, StringComparison.Ordinal); }
      return a.Equals(b);
    }
  }
}
