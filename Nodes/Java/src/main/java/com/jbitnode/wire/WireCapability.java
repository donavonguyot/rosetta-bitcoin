package com.jbitnode.wire;

/** Wire capability registry row mirrored from scout ports. */
public record WireCapability(
    String id,
    String checkpoint,
    String category,
    String name,
    String description,
    boolean required,
    boolean implemented) {}
