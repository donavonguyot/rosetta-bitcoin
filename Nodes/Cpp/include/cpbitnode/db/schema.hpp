#pragma once

#include <sqlite3.h>

namespace cpbitnode::db {

inline constexpr int kSchemaVersion = 7;

void initSchema(sqlite3* db);
void seedWireCapabilities(sqlite3* db);

}  // namespace cpbitnode::db
