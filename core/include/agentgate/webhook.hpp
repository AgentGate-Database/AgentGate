#pragma once

#include <string_view>

namespace agentgate {

// Rejects non-HTTP(S) URLs, userinfo, and, unless allow_private is set,
// loopback, private, link-local, and metadata destinations.
void validate_webhook_url(std::string_view url, bool allow_private);

} // namespace agentgate
