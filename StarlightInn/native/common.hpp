#pragma once
#define NOMINMAX
#include <windows.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <atomic>
#include <chrono>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace inn {
using namespace winrt::Windows::Data::Json;
using J = JsonObject;
using A = JsonArray;
using V = IJsonValue;
using Clock = std::chrono::steady_clock;
struct Error { std::string code; explicit Error(std::string c) : code(std::move(c)) {} };
// Only enum stages and numeric codes may cross the authentication boundary.
// Never retain hresult_error.message(), ProviderError.ErrorMessage or properties.
enum class NativeStage { WinrtInit, WamFactory, FindProvider, CreateRequest, ParentWindow, RequestToken, SilentToken, ValidateResponse, FindAccount, SignOut, InvalidateCache, HelperBoot };
enum class NativeKind { Failed, ProviderMissing, WindowRequired, HelperBoot };
struct NativeFailure {
    NativeStage stage; uint32_t hresult;
    std::optional<uint32_t> provider_error;
    NativeKind kind=NativeKind::Failed;
    const char* code() const;
    std::string message() const;
    J dto() const;
};
const char* native_stage(NativeStage);
std::string hex_code(uint32_t);
template<class F> decltype(auto) native_call(NativeStage stage,F&& f){
    try{return f();}catch(winrt::hresult_error const& e){
        throw NativeFailure{stage,static_cast<uint32_t>(e.code().value),{}};
    }
}
void check_wam_status(uint32_t,std::optional<uint32_t>);
inline void require(bool ok, const char* code) { if (!ok) throw Error(code); }
inline std::wstring wide(std::string_view s) { return std::wstring(winrt::to_hstring(s)); }
inline std::string utf(winrt::hstring const& s) { return winrt::to_string(s); }
inline V val(std::string const& s) { return JsonValue::CreateStringValue(winrt::to_hstring(s)); }
inline V val(const char* s) { return val(std::string(s)); }
inline V val(bool b) { return JsonValue::CreateBooleanValue(b); }
inline V val(double n) { return JsonValue::CreateNumberValue(n); }
inline void put(J const& j, const char* k, V const& v) { j.Insert(winrt::to_hstring(k), v); }
inline void put(J const& j, const char* k, std::string const& s) { put(j,k,val(s)); }
inline void put(J const& j, const char* k, const char* s) { put(j,k,val(s)); }
inline void put(J const& j, const char* k, bool b) { put(j,k,val(b)); }
inline void put(J const& j, const char* k, double n) { put(j,k,val(n)); }
inline std::string text(J const& j, const char* k, std::string fallback = "") {
    auto h = winrt::to_hstring(k); if (!j.HasKey(h)) return fallback;
    require(j.Lookup(h).ValueType()==JsonValueType::String,"INVALID_RESPONSE");
    return utf(j.GetNamedString(h));
}
inline bool boolean(J const& j, const char* k, bool fallback=false) {
    auto h=winrt::to_hstring(k); if(!j.HasKey(h)) return fallback;
    require(j.Lookup(h).ValueType()==JsonValueType::Boolean,"INVALID_ARGUMENTS"); return j.GetNamedBoolean(h);
}
inline J object(J const& j, const char* k) { return j.GetNamedObject(winrt::to_hstring(k),J()); }
inline std::string encode(V const& j) { return utf(j.Stringify()); }
// Walk JSON strings separately from the platform parser so duplicate fields,
// including escaped aliases, are rejected rather than last-one-wins.
J parse(std::string_view bytes, size_t limit=1024*1024);
void keys(J const& j, std::initializer_list<const char*> allowed);
inline bool eq(std::string const& a,std::string const& b) {
    return a.size()==b.size() && _strnicmp(a.c_str(),b.c_str(),a.size())==0;
}
bool guid(std::string const& s);
bool clean(std::string const& s, size_t max=512);
std::string uuid();
std::string stamp();
struct Cancel {
    std::shared_ptr<std::atomic_bool> flag=std::make_shared<std::atomic_bool>(false);
    Clock::time_point deadline=Clock::now()+std::chrono::seconds(30);
    std::shared_ptr<std::atomic_bool> lifetime;
    void check() const { require(!flag->load() && (!lifetime || !lifetime->load()) && Clock::now()<deadline,"CANCELLED_OR_TIMEOUT"); }
};
struct Secret {
    std::string bytes;
    explicit Secret(std::string s):bytes(s){if(!s.empty())SecureZeroMemory(s.data(),s.size());}
    Secret(Secret const&)=delete; Secret& operator=(Secret const&)=delete;
    Secret(Secret&& s):bytes(s.bytes){if(!s.bytes.empty())SecureZeroMemory(s.bytes.data(),s.bytes.size());s.bytes.clear();}
    ~Secret(){ if(!bytes.empty()) SecureZeroMemory(bytes.data(),bytes.size()); }
};
struct Settings {
    std::string client, initial="organizations";
    void validate(bool needed=true) const;
    J dto() const;
};
struct Profile {
    bool auto_login=true;
    std::string client, initial, account_id, provider, username, tenant, sub, subname;
    void validate() const;
    void match(Settings const&) const;
    J dto() const;
    static Profile from(J const&);
};
struct Profiles {
    virtual ~Profiles()=default;
    virtual Profile load()=0;
    virtual void save(Profile const&)=0;
};
struct MemoryProfiles:Profiles {
    Profile value;
    Profile load() override{return value;}
    void save(Profile const& p) override{p.validate();value=p;}
};
struct DiskProfiles:Profiles {
    std::wstring path;
    explicit DiskProfiles(std::wstring p):path(std::move(p)){}
    Profile load() override;
    void save(Profile const&) override;
    static std::wstring default_path();
};
std::string read_file(std::wstring const&,size_t);
void atomic_file(std::wstring const&,std::string_view);
struct Lease {
    std::string account_id, provider, username, tenant, client;
    virtual ~Lease()=default;
    virtual Secret token(bool force,Cancel const&)=0;
};
struct Identity {
    virtual ~Identity()=default;
    virtual std::shared_ptr<Lease> login(Settings const&,std::string const&,std::shared_ptr<Lease>,bool,HWND,Cancel const&)=0;
    virtual std::shared_ptr<Lease> restore(Settings const&,Profile const&,Cancel const&)=0;
    virtual void logout(Profile const&,Cancel const&)=0;
};
struct Response { unsigned status=200; J body; std::string poll, location; bool async=false; unsigned retry=2; };
struct Http {
    virtual ~Http()=default;
    // Only Core calls this; the wire protocol has no URL or token command.
    using Guard=std::function<std::unique_lock<std::mutex>()>;
    virtual Response send(Lease&,std::string const&,std::string const&,bool,Cancel const&,Guard={})=0;
};
std::string host_path(std::string const&);
void page_url(std::string const&,std::string const&);
void poll_url(std::string const&,std::string const&);
struct Resource {std::string id,group,name;};
Resource resource(std::string const&,std::string const&);
std::string power(J const&);
void success(Response const&);
struct NativeIdentity:Identity {
    DWORD parent;
    explicit NativeIdentity(DWORD p):parent(p){}
    std::shared_ptr<Lease> login(Settings const&,std::string const&,std::shared_ptr<Lease>,bool,HWND,Cancel const&) override;
    std::shared_ptr<Lease> restore(Settings const&,Profile const&,Cancel const&) override;
    void logout(Profile const&,Cancel const&) override;
    static bool available();
    static void verify_factory();
    static bool discover_provider(Cancel const&);
};
struct NativeHttp:Http { Response send(Lease&,std::string const&,std::string const&,bool,Cancel const&,Guard={}) override; };
}