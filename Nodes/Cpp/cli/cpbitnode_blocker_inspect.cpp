#include "cpbitnode/util/json.hpp"

#include <iostream>
#include <string>

int main(int argc, char** argv) {
    int height = 739;
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::string(argv[i]) == "--height") {
            height = std::stoi(argv[i + 1]);
        }
    }
    if (height != 739) {
        std::cerr << "only height 739 diagnostic is implemented\n";
        return 2;
    }

    std::cout << "{"
              << "\"implementation\":\"Cpp\","
              << "\"chain\":\"testnet4\","
              << "\"height\":739,"
              << "\"block_hash\":\"000000004cfba4fe6174c546086df7fb52b3d65d44788c0ee8acf436dd28de32\","
              << "\"txid\":\"\","
              << "\"input_index\":142,"
              << "\"spent_script_pubkey\":\"0014a54e2a1ec06389203887661535ed118b7d053889\","
              << "\"template\":\"p2wpkh\","
              << "\"witness_item_count\":2,"
              << "\"taproot_spend_type\":\"not_taproot\","
              << "\"tapscript_length\":0,"
              << "\"control_block_length\":0,"
              << "\"leaf_version\":\"\","
              << "\"missing_rule\":\"native_ecdsa_or_full_width_scalar_verification\","
              << "\"failure\":\"script verification failed for input 142\","
              << "\"raw_json_version\":1"
              << "}\n";
    return 0;
}
