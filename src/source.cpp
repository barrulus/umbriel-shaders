// SPDX-License-Identifier: MIT
#include "core.hpp"
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <curl/curl.h>
#include <mutex>
#include <thread>

namespace shaders {
namespace {
constexpr auto origin = "https://raw.githubusercontent.com/noctalia-dev/community-umbriel-shaders/";
struct Buffer {
    std::string data;
    size_t limit;
    bool exceeded = false;
};
size_t receive(char *data, size_t size, size_t count, void *user) {
    auto &buffer = *static_cast<Buffer *>(user);
    if (size && count > (buffer.limit - buffer.data.size()) / size) {
        buffer.exceeded = true;
        return 0;
    }
    try {
        buffer.data.append(data, size * count);
    } catch (...) {
        return 0;
    }
    return size * count;
}

} // namespace
std::string download(const std::string &url, size_t limit) {
    require(url.starts_with(origin) && url.find_first_of("\r\n") == std::string::npos,
            "Invalid download origin");
    static std::once_flag once;
    std::call_once(once, [] {
        require(curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK, "Could not initialize HTTPS");
    });
    const auto deleter = [](CURL *handle) { curl_easy_cleanup(handle); };
    std::unique_ptr<CURL, decltype(deleter)> handle(curl_easy_init(), deleter);
    require(bool(handle), "Could not initialize download");
    Buffer buffer{{}, limit};
    curl_easy_setopt(handle.get(), CURLOPT_URL, url.c_str());
    curl_easy_setopt(handle.get(), CURLOPT_PROTOCOLS_STR, "https");
    curl_easy_setopt(handle.get(), CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(handle.get(), CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(handle.get(), CURLOPT_SSL_VERIFYHOST, 2L);
    bool custom_ca = false;
    for (const auto *key : {"CURL_CA_BUNDLE", "SSL_CERT_FILE", "NIX_SSL_CERT_FILE"}) {
        const auto *path = std::getenv(key);
        if (path && *path) {
            curl_easy_setopt(handle.get(), CURLOPT_CAINFO, path);
            custom_ca = true;
            break;
        }
    }
    if (!custom_ca) {
        // Nix libcurl can have no compiled-in trust paths. Its command-line
        // wrapper supplies a bundle, but an application using the library must
        // locate the system trust store itself in that case.
        char *bundle = nullptr, *directory = nullptr;
        curl_easy_getinfo(handle.get(), CURLINFO_CAINFO, &bundle);
        curl_easy_getinfo(handle.get(), CURLINFO_CAPATH, &directory);
        if (!bundle && !directory)
            for (const auto *path : {"/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt",
                                     "/etc/ssl/cert.pem"}) {
                if (fs::is_regular_file(path)) {
                    curl_easy_setopt(handle.get(), CURLOPT_CAINFO, path);
                    break;
                }
            }
    }
    curl_easy_setopt(handle.get(), CURLOPT_CONNECTTIMEOUT_MS, 3000L);
    curl_easy_setopt(handle.get(), CURLOPT_TIMEOUT_MS, 8000L);
    curl_easy_setopt(handle.get(), CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(handle.get(), CURLOPT_USERAGENT, "Umbriel-Shaders-Native/0.2");
    curl_easy_setopt(handle.get(), CURLOPT_WRITEFUNCTION, receive);
    curl_easy_setopt(handle.get(), CURLOPT_WRITEDATA, &buffer);
    const auto result = curl_easy_perform(handle.get());
    require(!buffer.exceeded, "Download exceeds advertised size limit");
    require(result == CURLE_OK,
            std::string("Could not download catalogue asset: ") + curl_easy_strerror(result));
    long status = 0;
    curl_easy_getinfo(handle.get(), CURLINFO_RESPONSE_CODE, &status);
    require(status == 200,
            "Catalogue download returned HTTP " + std::to_string(status) + "; redirects are not followed");
    return buffer.data;
}
Catalogue Catalogue::online(const fs::path &cache, bool refresh, Fetch fetch) {
    const auto index = contained(cache, "catalogue.json");
    const bool fetch_index = refresh || !fs::exists(index);
    std::string raw;
    bool offline = false;
    if (fetch_index) {
        try {
            raw = fetch(std::string(origin) + "catalogue/catalogue.json", 4 * document_limit);
        } catch (const std::exception &) {
            if (!fs::exists(index))
                throw;
            offline = true;
        }
    }
    require(!raw.empty() || fs::exists(index), "The server returned an empty catalogue. Try Refresh again.");
    if (raw.empty())
        raw = read(index, 4 * document_limit);
    require(raw.size() <= 4 * document_limit, "Catalogue exceeds index size limit");
    auto registry = parse_json(raw);
    Catalogue result(std::move(registry));
    result.cache_ = fs::absolute(cache);
    result.fetch_ = std::move(fetch);
    result.mode_ = "online";
    result.offline_ = offline;
    if (fetch_index && !offline && (!fs::exists(index) || read(index, 4 * document_limit) != raw))
        atomic_write(index, raw);
    return result;
}
Catalogue Catalogue::local(const fs::path &root, const fs::path &cache, bool refresh) {
    Catalogue result(local_registry(root, cache, refresh), fs::absolute(root), true);
    result.mode_ = "local";
    return result;
}
std::string Catalogue::url(const std::string &name) const {
    relative_path(name);
    require(registry_.at("files").contains(name), "Asset is not listed in catalogue");
    // Repository paths reject URL metacharacters; percent-encode spaces and non-ASCII bytes.
    constexpr char digits[] = "0123456789ABCDEF";
    std::string escaped;
    for (unsigned char c : name) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '/' ||
            c == '-' || c == '_' || c == '.')
            escaped += char(c);
        else {
            escaped += '%';
            escaped += digits[c >> 4];
            escaped += digits[c & 15];
        }
    }
    return std::string(origin) + registry_.at("source").at("revision").get<std::string>() + "/" + escaped;
}
fs::path Catalogue::object_path(const std::string &name) const {
    return contained(cache_, "objects/" + registry_.at("files").at(name).at("sha256").get<std::string>() +
                                 fs::path(name).extension().string());
}
std::string Catalogue::bytes(const std::string &name) const {
    const auto &record = registry_.at("files").at(name);
    const auto limit = record.at("bytes").get<size_t>();
    const auto valid = [&](const std::string &data) {
        return data.size() == limit && sha256(data) == record.at("sha256").get<std::string>();
    };
    if (mode_ != "online") {
        require(!assets_.empty(), "Choose a shader asset snapshot or checkout");
        const auto data = read(contained(assets_, name), limit);
        require(valid(data), "Catalogue asset hash mismatch: " + name);
        return data;
    }
    const auto object = object_path(name); // Reject symlinks even when repairing corrupt entries.
    if (fs::exists(object)) {
        try {
            const auto data = read(object, limit);
            if (valid(data))
                return data;
        } catch (const std::exception &) {
        }
    }
    require(std::chrono::steady_clock::now() < deadline_,
            "Asset download deadline reached; try again to use the cached progress");
    const auto data = fetch_(url(name), limit);
    require(valid(data), "Catalogue asset hash mismatch: " + name);
    atomic_write(object, data);
    return data;
}
Json Catalogue::previews(const std::vector<std::string> &ids) const {
    require(ids.size() <= 24, "Request at most 24 visible previews at once");
    Json results = Json::object();
    std::mutex mutex;
    std::atomic<size_t> next{0};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    auto worker = [&] {
        while (true) {
            const auto i = next.fetch_add(1);
            if (i >= ids.size() || std::chrono::steady_clock::now() > deadline)
                return;
            Json preview = {{"image", nullptr}, {"animation", nullptr}};
            try {
                for (const auto &effect : registry_.at("effects")) {
                    if (effect.at("id") != ids[i])
                        continue;
                    const auto &media = effect.at("preview");
                    if (media.value("image", Json(nullptr)).is_string()) {
                        const auto name = media.at("image").get<std::string>();
                        (void)bytes(name);
                        preview["image"] =
                            (mode_ == "online" ? object_path(name) : contained(assets_, name)).string();
                    }
                    if (media.value("animation", Json(nullptr)).is_string()) {
                        const auto name = media.at("animation").get<std::string>();
                        preview["animation"] =
                            mode_ == "online" ? url(name) : contained(assets_, name).string();
                    }
                    break;
                }
            } catch (const std::exception &error) {
                preview["error"] = error.what();
            }
            std::lock_guard guard(mutex);
            results[ids[i]] = std::move(preview);
        }
    };
    std::vector<std::jthread> workers;
    for (size_t n = 0; n < std::min<size_t>(4, ids.size()); ++n)
        workers.emplace_back(worker);
    for (auto &thread : workers)
        thread.join();
    return results;
}
void Catalogue::collect_cache() const {
    if (mode_ != "online")
        return;
    std::set<fs::path> referenced;
    for (const auto &[name, record] : registry_.at("files").items()) {
        (void)record;
        referenced.insert(object_path(name));
    }
    const auto directory = contained(cache_, "objects");
    if (!fs::exists(directory))
        return;
    std::vector<fs::directory_entry> stale;
    uintmax_t retained = 0;
    for (const auto &entry : fs::directory_iterator(directory)) {
        if (entry.is_symlink() || !entry.is_regular_file())
            continue;
        if (!referenced.contains(entry.path())) {
            retained += entry.file_size();
            stale.push_back(entry);
        }
    }
    std::sort(stale.begin(), stale.end(),
              [](const auto &a, const auto &b) { return a.last_write_time() < b.last_write_time(); });
    for (const auto &entry : stale) {
        if (retained <= 64 * document_limit &&
            fs::file_time_type::clock::now() - entry.last_write_time() < std::chrono::hours(24 * 7))
            continue;
        retained -= entry.file_size();
        fs::remove(entry.path());
    }
}
} // namespace shaders
