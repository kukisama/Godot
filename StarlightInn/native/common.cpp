#include "common.hpp"
#include <bcrypt.h>
#include <sstream>

namespace inn {
const char* native_stage(NativeStage stage){
    switch(stage){
    case NativeStage::WinrtInit:return "winrt_init";case NativeStage::WamFactory:return "wam_factory";
    case NativeStage::FindProvider:return "find_provider";case NativeStage::CreateRequest:return "create_request";
    case NativeStage::ParentWindow:return "parent_window";case NativeStage::RequestToken:return "request_token";
    case NativeStage::SilentToken:return "silent_token";case NativeStage::ValidateResponse:return "validate_response";
    case NativeStage::FindAccount:return "find_account";case NativeStage::SignOut:return "sign_out";
    case NativeStage::InvalidateCache:return "invalidate_cache";case NativeStage::HelperBoot:return "helper_boot";
    default:return "helper_boot";
    }
}
std::string hex_code(uint32_t code){char buffer[11];sprintf_s(buffer,"0x%08X",static_cast<unsigned>(code));return buffer;}
const char* NativeFailure::code()const{
    if(kind==NativeKind::ProviderMissing)return "WAM_PROVIDER_MISSING";
    if(kind==NativeKind::WindowRequired)return "WAM_WINDOW_REQUIRED";
    if(kind==NativeKind::HelperBoot)return "HELPER_BOOT_FAILED";
    return "AUTH_NATIVE_FAILED";
}
std::string NativeFailure::message()const{
    std::string prefix=kind==NativeKind::ProviderMissing?"本账户的 Entra broker provider 不可用；先检查组件状态，不自动安装。":
        (kind==NativeKind::WindowRequired?"父窗口校验失败，未发起 WAM 请求。":"原生认证/初始化未完成；未输出原始异常或凭据。");
    return prefix+" 阶段: "+native_stage(stage)+"; HRESULT: "+hex_code(hresult)+
        (provider_error?"; ProviderError: "+std::to_string(*provider_error)+" ("+hex_code(*provider_error)+")":"");
}
J NativeFailure::dto()const{J j;put(j,"stage",native_stage(stage));put(j,"hresult",hex_code(hresult));if(provider_error)put(j,"provider_error",static_cast<double>(*provider_error));return j;}
namespace {
struct Scanner {
    std::string_view s; size_t p=0; unsigned depth=0;
    void ws(){while(p<s.size() && (s[p]==' '||s[p]=='\r'||s[p]=='\n'||s[p]=='\t'))++p;}
    std::string string(){
        require(p<s.size() && s[p]=='"',"INVALID_JSON");size_t begin=p++;
        while(p<s.size()) {char c=s[p++];if(c=='\\'){require(p<s.size(),"INVALID_JSON");++p;}else if(c=='"'){
            return utf(JsonValue::Parse(winrt::to_hstring(s.substr(begin,p-begin))).GetString());
        }} throw Error("INVALID_JSON");
    }
    void value(){
        ws(); require(p<s.size() && ++depth<=64,"INVALID_JSON");
        char c=s[p];
        if(c=='{') {++p;ws();std::set<std::string> seen;
            if(p<s.size()&&s[p]=='}')++p;
            else for(;;){ws();auto k=string();require(seen.insert(k).second,"DUPLICATE_FIELD");ws();require(p<s.size()&&s[p++]==':',"INVALID_JSON");value();ws();require(p<s.size(),"INVALID_JSON");if(s[p++]=='}')break;require(s[p-1]==',',"INVALID_JSON");}
        } else if(c=='['){++p;ws();if(p<s.size()&&s[p]==']')++p;else for(;;){value();ws();require(p<s.size(),"INVALID_JSON");if(s[p++]==']')break;require(s[p-1]==',',"INVALID_JSON");}}
        else if(c=='"'){string();}
        else {auto begin=p;while(p<s.size()&&s[p]!=','&&s[p]!=']'&&s[p]!='}'&&s[p]!=' '&&s[p]!='\r'&&s[p]!='\n'&&s[p]!='\t')++p;require(p>begin,"INVALID_JSON");}
        --depth;
    }
};
}
J parse(std::string_view bytes,size_t limit){
    require(!bytes.empty()&&bytes.size()<=limit,"INVALID_JSON");
    try{Scanner scan{bytes};scan.value();scan.ws();require(scan.p==bytes.size(),"INVALID_JSON");return J::Parse(winrt::to_hstring(bytes));}
    catch(Error const&){throw;}catch(...){throw Error("INVALID_JSON");}
}
void keys(J const& j,std::initializer_list<const char*> allowed){for(auto const& row:j){auto k=utf(row.Key());bool ok=false;for(auto a:allowed)if(k==a)ok=true;require(ok,"INVALID_ARGUMENTS");}}
bool guid(std::string const& s){
    static std::regex const re("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
    return std::regex_match(s,re)&&s!="00000000-0000-0000-0000-000000000000";
}
bool clean(std::string const& s,size_t max){return s.size()<=max && std::none_of(s.begin(),s.end(),[](unsigned char c){return c<32||c==127;});}
std::string uuid(){unsigned char b[32];require(BCryptGenRandom(nullptr,b,sizeof b,BCRYPT_USE_SYSTEM_PREFERRED_RNG)==0,"RANDOM_FAILED");const char* h="0123456789abcdef";std::string out;for(auto c:b){out+=h[c>>4];out+=h[c&15];}return out;}
std::string stamp(){SYSTEMTIME t;GetSystemTime(&t);char b[40];sprintf_s(b,"%04u-%02u-%02uT%02u:%02u:%02uZ",t.wYear,t.wMonth,t.wDay,t.wHour,t.wMinute,t.wSecond);return b;}
void Settings::validate(bool needed)const{require((!needed&&client.empty())||guid(client),"NOT_CONFIGURED");require(initial=="organizations"||guid(initial),"INVALID_TENANT");}
J Settings::dto()const{J j;put(j,"client_id",client);put(j,"initial_tenant",initial);return j;}
std::string host_path(std::string const& u){
    static const std::string root="https://management.azure.com";
    require(u.size()>root.size()&&eq(u.substr(0,root.size()),root),"UNSAFE_URL");
    size_t pos=root.size(); if(u.compare(pos,4,":443")==0)pos+=4;
    require(pos<u.size()&&u[pos]=='/'&&u.find_first_of("\\#\r\n\t ")==std::string::npos,"UNSAFE_URL");
    auto path=u.substr(pos,u.find('?',pos)-pos);
    require(path.find('%')==std::string::npos&&path.find("/../")==std::string::npos&&path.find("/./")==std::string::npos&&path.find("//")==std::string::npos,"UNSAFE_URL");return path;
}
void page_url(std::string const& u,std::string const& p){require(eq(host_path(u),p),"UNSAFE_URL");}
void poll_url(std::string const& u,std::string const& sub){
    require(guid(sub),"UNSAFE_URL");std::regex r("^/subscriptions/"+sub+"/(?:resourceGroups/[A-Za-z0-9_.()\\-]+/)?providers/Microsoft\\.Compute/locations/[A-Za-z0-9\\-]+/(?:operations|operationResults|operationStatuses)/[A-Za-z0-9\\-]+$",std::regex::icase);
    require(std::regex_match(host_path(u),r),"UNSAFE_URL");
}
Resource resource(std::string const& id,std::string const& sub){
    require(guid(sub),"INVALID_TARGET");static std::regex r("^/subscriptions/([0-9a-fA-F\\-]{36})/resourceGroups/([A-Za-z0-9_.()\\-]{1,90})/providers/Microsoft\\.Compute/virtualMachines/([A-Za-z0-9_\\-]{1,64})$",std::regex::icase);
    std::smatch m;require(std::regex_match(id,m,r)&&eq(m[1],sub),"INVALID_TARGET");auto g=m[2].str();require(g!="."&&g!=".."&&g.back()!='.',"INVALID_TARGET");return {"/subscriptions/"+sub+"/resourceGroups/"+g+"/providers/Microsoft.Compute/virtualMachines/"+m[3].str(),g,m[3]};
}
std::string power(J const& view){
    if(view.HasKey(L"statuses"))for(auto const& v:view.GetNamedArray(L"statuses")){auto c=text(v.GetObject(),"code");if(c.size()>11&&eq(c.substr(0,11),"PowerState/")){auto s=c.substr(11);std::transform(s.begin(),s.end(),s.begin(),[](unsigned char x){return static_cast<char>(tolower(x));});return s;}}return "unknown";
}
void success(Response const& r){if(r.status>=200&&r.status<300)return;if(r.status==403)throw Error("FORBIDDEN");if(r.status==401)throw Error("INTERACTION_REQUIRED");if(r.status>=300&&r.status<400)throw Error("REDIRECT_BLOCKED");throw Error("ARM_HTTP_"+std::to_string(r.status));}
}