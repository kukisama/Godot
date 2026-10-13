#include "common.hpp"
#include "async_wait.hpp"
#include <winrt/Windows.Security.Authentication.Web.Core.h>
#include <winrt/Windows.Security.Credentials.h>
#include <webauthenticationcoremanagerinterop.h>

namespace inn {
using namespace winrt::Windows::Security::Authentication::Web::Core;
using namespace winrt::Windows::Security::Credentials;
void check_wam_status(uint32_t status,std::optional<uint32_t> error){
    auto s=static_cast<WebTokenRequestStatus>(status);
    require(s!=WebTokenRequestStatus::UserCancel,"CANCELLED_OR_TIMEOUT");
    require(s!=WebTokenRequestStatus::UserInteractionRequired,"INTERACTION_REQUIRED");
    if(s!=WebTokenRequestStatus::Success&&s!=WebTokenRequestStatus::AccountSwitch)
        throw NativeFailure{NativeStage::RequestToken,0,error};
}
namespace {
template<class Op> auto await(Op const& op,Cancel const& c){
    return await_native(op,c);
}
std::string actual_tenant(std::string const& authority){
    const std::string prefix="https://login.microsoftonline.com/";
    require(authority.size()>prefix.size()&&eq(authority.substr(0,prefix.size()),prefix),"INVALID_IDENTITY");
    auto t=authority.substr(prefix.size());if(!t.empty()&&t.back()=='/')t.pop_back();
    require(guid(t),"TENANT_UNVERIFIED");return t;
}
WebTokenRequest request(WebAccountProvider const& provider,Settings const& s,std::string const& tenant,bool interactive){
    return native_call(NativeStage::CreateRequest,[&]{
    // Same scope-only WAM v2 shape as the working AzureRM-rust client.
    WebTokenRequest r(provider,L"https://management.azure.com/user_impersonation openid profile offline_access",winrt::to_hstring(s.client),interactive?WebTokenRequestPromptType::ForceAuthentication:WebTokenRequestPromptType::Default);
    r.Properties().Insert(L"authority",winrt::to_hstring("https://login.microsoftonline.com/"+tenant+"/"));
    r.Properties().Insert(L"validateAuthority",L"yes");r.Properties().Insert(L"wam_compat",L"2.0");
    return r;});
}
WebAccountProvider provider(Cancel const& c){return native_call(NativeStage::FindProvider,[&]{auto p=await(WebAuthenticationCoreManager::FindAccountProviderAsync(L"https://login.microsoft.com",L"organizations"),c);if(!p)throw NativeFailure{NativeStage::FindProvider,0,{},NativeKind::ProviderMissing};return p;});}
WebTokenResponse checked(WebTokenRequestResult const& result,std::string const& expected,std::string const& account){
    return native_call(NativeStage::ValidateResponse,[&]{
    auto status=result.ResponseStatus();
    std::optional<uint32_t> error;
    if(status!=WebTokenRequestStatus::Success&&status!=WebTokenRequestStatus::AccountSwitch){auto e=result.ResponseError();if(e)error=e.ErrorCode();}
    check_wam_status(static_cast<uint32_t>(status),error);
    require(result.ResponseData().Size()==1,"INVALID_IDENTITY");auto r=result.ResponseData().GetAt(0);
    require(static_cast<bool>(r.WebAccount())&&r.WebAccount().WebAccountProvider().Id()==L"https://login.microsoft.com"&&!r.WebAccount().Id().empty(),"INVALID_IDENTITY");
    require(account.empty()||utf(r.WebAccount().Id())==account,"ACCOUNT_CHANGED");
    require(r.Properties().HasKey(L"Authority"),"TENANT_UNVERIFIED");auto t=actual_tenant(utf(r.Properties().Lookup(L"Authority")));
    require(expected=="organizations"||eq(t,expected),"ACCOUNT_CHANGED");
    require(r.Properties().HasKey(L"wamcompat_scopes"),"SCOPE_UNVERIFIED");
    auto scopes=utf(r.Properties().Lookup(L"wamcompat_scopes"));std::istringstream stream(scopes);std::string scope;bool arm=false;
    while(stream>>scope)if(eq(scope,"https://management.azure.com/user_impersonation"))arm=true;
    require(arm&&!r.Token().empty(),"SCOPE_UNVERIFIED");return r;});
}
struct WamLease:Lease {
    WebAccount selected{nullptr};
    WebTokenRequestResult cached{nullptr};
    WamLease(WebTokenResponse const& r,std::string const& id,WebTokenRequestResult const& result):cached(result){selected=r.WebAccount();account_id=utf(selected.Id());provider=utf(selected.WebAccountProvider().Id());username=utf(selected.UserName());client=id;tenant=actual_tenant(utf(r.Properties().Lookup(L"Authority")));require(clean(username)&&!username.empty()&&clean(account_id),"INVALID_IDENTITY");}
    Secret token(bool force,Cancel const& c) override{
        if(force&&cached)native_call(NativeStage::InvalidateCache,[&]{await(cached.InvalidateCacheAsync(),c);});
        Settings s{client,"organizations"};auto r=request(selected.WebAccountProvider(),s,tenant,false);
        auto result=native_call(NativeStage::SilentToken,[&]{return await(WebAuthenticationCoreManager::GetTokenSilentlyAsync(r,selected),c);});
        auto response=checked(result,tenant,account_id);cached=result;return Secret(utf(response.Token()));
    }
};
}
void NativeIdentity::verify_factory(){native_call(NativeStage::WamFactory,[]{winrt::get_activation_factory<WebAuthenticationCoreManager>().as<IWebAuthenticationCoreManagerInterop>();});}
bool NativeIdentity::available(){try{verify_factory();return true;}catch(...){return false;}}
bool NativeIdentity::discover_provider(Cancel const& c){return static_cast<bool>(provider(c));}
std::shared_ptr<Lease> NativeIdentity::login(Settings const& s,std::string const& tenant,std::shared_ptr<Lease> previous,bool select,HWND hwnd,Cancel const& c){
    s.validate();verify_factory();DWORD pid=0;GetWindowThreadProcessId(hwnd,&pid);if(!IsWindow(hwnd)||pid!=parent)throw NativeFailure{NativeStage::ParentWindow,static_cast<uint32_t>(HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE)),{},NativeKind::WindowRequired};
    auto p=provider(c);auto r=request(p,s,tenant,select);winrt::Windows::Foundation::IAsyncOperation<WebTokenRequestResult> op{nullptr};
    auto interop=native_call(NativeStage::WamFactory,[]{return winrt::get_activation_factory<WebAuthenticationCoreManager>().as<IWebAuthenticationCoreManagerInterop>();});
    auto old=std::dynamic_pointer_cast<WamLease>(previous);
    if(!select&&old){
        try {auto result=native_call(NativeStage::SilentToken,[&]{return await(WebAuthenticationCoreManager::GetTokenSilentlyAsync(r,old->selected),c);});return native_call(NativeStage::ValidateResponse,[&]{return std::make_shared<WamLease>(checked(result,tenant,old->account_id),s.client,result);});}
        catch(Error const& e){if(e.code!="INTERACTION_REQUIRED")throw;}
        native_call(NativeStage::RequestToken,[&]{winrt::check_hresult(interop->RequestTokenWithWebAccountForWindowAsync(hwnd,reinterpret_cast<IInspectable*>(winrt::get_abi(r)),reinterpret_cast<IInspectable*>(winrt::get_abi(old->selected)),winrt::guid_of<decltype(op)>(),winrt::put_abi(op)));});
    }else {
        // No selected account: explicit user-driven request, never system default.
        native_call(NativeStage::RequestToken,[&]{winrt::check_hresult(interop->RequestTokenForWindowAsync(hwnd,reinterpret_cast<IInspectable*>(winrt::get_abi(r)),winrt::guid_of<decltype(op)>(),winrt::put_abi(op)));});
    }
    auto result=native_call(NativeStage::RequestToken,[&]{return await(op,c);});return native_call(NativeStage::ValidateResponse,[&]{return std::make_shared<WamLease>(checked(result,tenant,(!select&&old)?old->account_id:""),s.client,result);});
}
std::shared_ptr<Lease> NativeIdentity::restore(Settings const& s,Profile const& saved,Cancel const& c){
    saved.match(s);verify_factory();auto p=provider(c);auto a=native_call(NativeStage::FindAccount,[&]{return await(WebAuthenticationCoreManager::FindAccountAsync(p,winrt::to_hstring(saved.account_id)),c);});
    require(static_cast<bool>(a)&&utf(a.Id())==saved.account_id,"CACHE_MISSING");auto r=request(p,s,saved.tenant,false);
    auto result=native_call(NativeStage::SilentToken,[&]{return await(WebAuthenticationCoreManager::GetTokenSilentlyAsync(r,a),c);});return native_call(NativeStage::ValidateResponse,[&]{return std::make_shared<WamLease>(checked(result,saved.tenant,saved.account_id),s.client,result);});
}
void NativeIdentity::logout(Profile const& saved,Cancel const& c){
    if(saved.account_id.empty())return;saved.validate();auto p=provider(c);auto a=native_call(NativeStage::FindAccount,[&]{return await(WebAuthenticationCoreManager::FindAccountAsync(p,winrt::to_hstring(saved.account_id)),c);});
    if(a&&utf(a.Id())==saved.account_id)native_call(NativeStage::SignOut,[&]{await(a.SignOutAsync(winrt::to_hstring(saved.client)),c);});
}
}