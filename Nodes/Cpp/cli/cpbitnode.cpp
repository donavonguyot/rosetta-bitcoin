#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/node.hpp"

#include <csignal>
#include <iostream>

int main(int argc, char** argv) {
    try {
        const auto settings = cpbitnode::config::Settings::fromArgs(argc, argv);
        return cpbitnode::runNode(settings);
    } catch (const std::exception& ex) {
        std::cerr << ex.what() << '\n';
        return 1;
    }
}
