JesterConsole 1.0.1
===================

PATCH
-----
Version 1.0.1 fixes a WoW 3.3.5a Lua load error:

  JesterConsoleInput doesn't have a "OnArrowPressed" script

WoW 3.3.5a does not expose that EditBox script handler. Command history now
uses OnKeyDown instead.

INSTALL / UPGRADE
-----------------
Replace the existing JesterConsole folder with this one:

D:\JesterCraft_3.3.5a\JesterCraft_3.3.5a\Interface\AddOns\JesterConsole

Then fully restart WoW or use /reload after replacing the files.

TEST
----
/jc

If the window opens, the addon loaded.

TILDE KEY
---------
Go to:
  Esc -> Key Bindings

Find:
  JesterConsole
  JesterConsole Toggle

Bind it to the grave / tilde key manually.

COMMAND EXAMPLES
----------------
bags
shadowmourne
benediction
item 41600 4
.additem 41600 4
