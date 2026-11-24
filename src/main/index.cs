// src\main\index.cs - what belongs to the type library, in one place.

// This file is compiled by nothing but name: it holds no code, only the list of sources that
// make up clipboard.dll, and the bundler resolves it into the file list the compiler is given
// (tools\bundler\plugins\50-cs-part.ps1). A source nothing reaches here is not compiled at all,
// so its types do not exist in the assembly - that is the closest .NET Framework gets to
// shaking a library without a linker.
//
// The event of moving a type out of src\lib\assembly\cb.native.cs and into one of these
// folders is therefore three lines: create the file under the folder it belongs to, add the
// #part line below, and delete the block from the old file. The type name is unchanged,
// because every file declares the same namespace.
//
//   reactivity\  the bag with traps, the effects, the derived value   (lib\ui\reactive.ps1)
//   ipc\         the pipe server and the frame it speaks             (lib\serve.ps1)
//   store\       the record format and the blobs beside it           (lib\store.ps1)
//   clip\        reading and writing the clipboard itself            (lib\clip.ps1)
//   media\       pictures, formatted text, the caches beside them    (lib\media.ps1)
//   search\      the row filter a query runs against                 (lib\query.ps1)
//   ui\          win32, the forms, the tray, the pin list            (lib\panel\*)
//   utils\       paths, logging, hashing, time                       (lib\base.ps1, utils\*)

// The directive is a line comment on purpose: it is read by a scanner that knows what a string
// and a block comment look like, so the text "#part" inside a literal declares nothing.
//
// Until the last block has moved, the sources that are still in src\lib\assembly travel beside
// this list (bundler.ini, [entry.main] Append=). When the folder is empty that line goes away
// and the assembly is made of this list alone.

// #part reactivity/reactive-bag.cs
// #part reactivity/reactive.cs
// #part reactivity/computed-cell.cs
// #part search/search.cs
// #part media/rtf.cs
// #part media/rich.cs
// #part ui/tray.cs
// #part ui/tray-skin.cs
// #part ui/tray-item.cs
// #part ui/pin-list.cs
// #part ui/shell.cs
// #part ui/hot-window.cs
// #part ui/fluent-form.cs
// #part ui/pin-draw-event-args.cs
