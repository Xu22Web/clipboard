// src\main\reactivity\computed-cell.cs - a value derived from what a reader read (see
// lib\ui\reactive.ps1's New-UiComputed).
//
// Vue's computed: cached until one of the reads behind it moves. It recomputes on access, not on
// the flush, so a value nobody looks at costs nothing, and it reports itself changed so whatever
// renders it runs again.
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
using System;

namespace Cb {
  public sealed class ComputedCell : IDisposable {
    private readonly Func<object> getter;
    private object value;
    private bool dirty = true;
    private int id;

    public ComputedCell(Func<object> source) {
      if (source == null) { throw new ArgumentNullException("source"); }
      getter = source;
      id = Reactive.Effect(Compute, MarkDirty);
    }

    public object Value {
      get {
        if (dirty) { Reactive.Rerun(id); }
        Reactive.Track(this, "value");
        return value;
      }
    }

    public bool Dirty { get { return dirty; } }

    public void Dispose() {
      if (id > 0) { Reactive.Stop(id); id = 0; }
      Reactive.StopTarget(this);
    }

    private void Compute() {
      value = getter();
      dirty = false;
    }

    private void MarkDirty() {
      if (dirty) { return; }
      dirty = true;
      Reactive.Trigger(this, "value");
    }
  }
}
