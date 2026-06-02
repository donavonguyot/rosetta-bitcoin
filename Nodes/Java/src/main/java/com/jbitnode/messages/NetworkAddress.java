package com.jbitnode.messages;

/** Bitcoin P2P network address (IPv6-mapped IPv4 layout). */
public record NetworkAddress(long services, String ip, int port) {}
