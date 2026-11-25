# shared\utils\module-stub.ps1 - an empty module: what Use-Module answers when there is nothing
# left to run (already loaded, carried by the bundle, or not present in this copy).

# It is a file rather than a null so the dot-source in front of the call always has something
# harmless to run; a module is free to import the same dependency twice.
