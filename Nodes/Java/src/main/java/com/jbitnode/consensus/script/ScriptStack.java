package com.jbitnode.consensus.script;

import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.Deque;

/** LIFO stack of script byte items. */
public final class ScriptStack {

  private final Deque<byte[]> items = new ArrayDeque<>();

  public void push(byte[] item) {
    items.push(item);
  }

  public void pushAll(byte[][] snapshot) {
    for (byte[] item : snapshot) {
      push(Arrays.copyOf(item, item.length));
    }
  }

  public byte[] pop() {
    byte[] item = items.pollFirst();
    if (item == null) {
      throw new ScriptError("stack underflow");
    }
    return item;
  }

  public byte[] peek() {
    byte[] item = items.peekFirst();
    if (item == null) {
      throw new ScriptError("stack underflow");
    }
    return item;
  }

  /** Returns the item {@code depthFromTop} elements below the stack top (1 = top). */
  public byte[] itemFromTop(int depthFromTop) {
    if (depthFromTop < 1 || depthFromTop > size()) {
      throw new ScriptError("stack underflow");
    }
    int index = 0;
    for (byte[] item : items) {
      index++;
      if (index == depthFromTop) {
        return item;
      }
    }
    throw new ScriptError("stack underflow");
  }

  public int size() {
    return items.size();
  }

  public boolean isEmpty() {
    return items.isEmpty();
  }

  /**
   * Moves the stack item {@code depthFromTop} positions below the top (0 = top) to the top,
   * removing it from its original position (BIP342 {@code OP_ROLL}).
   */
  public void rollFromTop(int depthFromTop) {
    if (depthFromTop < 0 || depthFromTop >= size()) {
      throw new ScriptError("OP_ROLL out of range");
    }
    byte[][] snap = snapshot();
    int removeIdx = snap.length - 1 - depthFromTop;
    byte[] moved = snap[removeIdx];
    items.clear();
    for (int i = 0; i < snap.length; i++) {
      if (i != removeIdx) {
        push(snap[i]);
      }
    }
    push(moved);
  }

  /** Returns a snapshot of stack items from bottom to top. */
  public byte[][] snapshot() {
    byte[][] out = new byte[items.size()][];
    int index = out.length - 1;
    for (byte[] item : items) {
      out[index--] = Arrays.copyOf(item, item.length);
    }
    return out;
  }
}
