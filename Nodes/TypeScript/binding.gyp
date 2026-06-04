{
  "targets": [
    {
      "target_name": "tsbitnode_native_secp256k1",
      "sources": [
        "native/secp256k1_native.cc"
      ],
      "cflags": [
        "<!@(pkg-config --cflags libsecp256k1)"
      ],
      "libraries": [
        "<!@(pkg-config --libs libsecp256k1)"
      ],
      "xcode_settings": {
        "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
        "OTHER_CFLAGS": [
          "<!@(pkg-config --cflags libsecp256k1)"
        ],
        "OTHER_LDFLAGS": [
          "<!@(pkg-config --libs libsecp256k1)"
        ]
      }
    }
  ]
}
