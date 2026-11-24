// src\main\index.cs - what belongs to the type library, in one place.

// This file is compiled by nothing but name: it holds no code, only the list of sources that
// make up clipboard.dll, and the bundler resolves it into the file list the compiler is given
// (tools\bundler\plugins\50-cs-part.ps1). A source nothing reaches here is not compiled at all,
// so its types do not exist in the assembly - that is the closest .NET Framework gets to
// shaking a library without a linker.
//
// Adding a type to the library is therefore three lines: create the file under the folder it
// belongs to, add the #part line below, and leave the type name alone - every file declares
// the same namespace.
//
//   reactivity\  the bag with traps, the effects, the derived value   (renderer\src\core\reactive.ps1)
//   ipc\         the pipe server and the frame it speaks             (lib\serve.ps1)
//   store\       the record format and the blobs beside it           (lib\store.ps1)
//   clip\        reading and writing the clipboard itself            (lib\clip.ps1)
//   media\       pictures, formatted text, the caches beside them    (lib\media.ps1)
//   search\      the row filter a query runs against                 (lib\query.ps1)
//   ui\          win32, the forms, the tray, the pin list            (renderer\src\windows\*)
//   utils\       paths, logging, hashing, time                       (lib\base.ps1, utils\*)

// The directive is a line comment on purpose: it is read by a scanner that knows what a string
// and a block comment look like, so the text "#part" inside a literal declares nothing.
//
// The list below is the whole library: there is no second folder to append, so a source that is
// not named here is not compiled.

// #part reactivity/reactive-bag.cs
// #part reactivity/reactive.cs
// #part reactivity/computed-cell.cs
// #part search/search.cs
// #part media/rtf.cs
// #part media/rich.cs
// #part ui/tray.cs
// #part ui/tray-skin.cs
// #part ui/tray-item.cs
// #part ui/tray-menu.cs
// #part ui/win.cs
// #part ui/pin-list.cs
// #part ui/shell.cs
// #part ui/hot-window.cs
// #part ui/fluent-form.cs
// #part ui/pin-draw-event-args.cs
