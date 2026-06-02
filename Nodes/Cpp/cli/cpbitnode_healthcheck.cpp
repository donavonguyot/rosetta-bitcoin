#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/healthcheck.hpp"

#include <iostream>

int main(int argc, char** argv) {
    try {
        const auto settings = cpbitnode::config::Settings::fromArgs(argc, argv);
        cpbitnode::db::ProjectTracker tracker(settings.resolvedDbPath());
        const auto doc = cpbitnode::healthcheck::buildHealthcheckDocument(settings, tracker);
        try {
            cpbitnode::healthcheck::validateHealthcheckPayload(doc);
        } catch (const std::exception& ex) {
            std::cout << cpbitnode::healthcheck::serializeHealthcheckDocument(doc) << '\n';
            std::cerr << "healthcheck: payload validation failed: " << ex.what() << '\n';
            return 1;
        }
        std::cout << cpbitnode::healthcheck::serializeHealthcheckDocument(doc) << '\n';
        if (doc.syncStatus == "error") {
            return 1;
        }
        return 0;
    } catch (const std::exception& ex) {
        std::cerr << ex.what() << '\n';
        return 1;
    }
}
