# SQLite amalgamation (optional vendoring)

Gate 0 builds against **system SQLite** via CMake `find_package(SQLite3)` (libsqlite3-dev on Debian/Ubuntu).

To vendor the amalgamation instead:

1. Download `sqlite3.c` and `sqlite3.h` from https://www.sqlite.org/download.html
2. Place them in this directory
3. Switch `CppNode/CMakeLists.txt` to compile `third_party/sqlite/sqlite3.c` and drop `find_package(SQLite3)`

No bundled sqlite sources are committed in Gate 0.
