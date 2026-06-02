package com.jbitnode.db;

/** Opening intent for chainstate invariant checks. */
public enum ChainstateOpenMode {
  READ_ONLY,
  READ_WRITE,
  REBUILD
}
