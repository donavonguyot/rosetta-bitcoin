package com.jbitnode.consensus;

/** Raised when a block header fails consensus checks. */
public class HeaderValidationException extends RuntimeException {

  public HeaderValidationException(String message) {
    super(message);
  }
}
