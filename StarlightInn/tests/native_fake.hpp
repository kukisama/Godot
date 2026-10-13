#pragma once
#include "core.hpp"
namespace inn::test {
inline const std::string sub="11111111-1111-1111-1111-111111111111",tenant="22222222-2222-2222-2222-222222222222",other="33333333-3333-3333-3333-333333333333";
inline const std::string vm="/subscriptions/"+sub+"/resourceGroups/fixture-rg/providers/Microsoft.Compute/virtualMachines/fixture-vm";
struct FakeLease:Lease {
    std::function<void()> on_token;
    FakeLease(){account_id="native-opaque-fixture";provider="https://login.microsoft.com";username="fixture@example.invalid";client=sub;this->tenant=test::tenant;}
    Secret token(bool,Cancel const& c)override{if(on_token)on_token();c.check();return Secret("TEST_TOKEN_NEVER_EXPORT");}
};
struct FakeIdentity:Identity {
    std::shared_ptr<FakeLease> selected=std::make_shared<FakeLease>();
    bool cache_fail=false;unsigned logouts=0,calls=0;std::function<void(Cancel const&)> on_login;
    std::shared_ptr<Lease> login(Settings const& s,std::string const&,std::shared_ptr<Lease>,bool,HWND,Cancel const& c)override{++calls;if(on_login)on_login(c);c.check();selected->client=s.client;return selected;}
    std::shared_ptr<Lease> restore(Settings const& s,Profile const&,Cancel const& c)override{return login(s,"",{},false,nullptr,c);}
    void logout(Profile const&,Cancel const&)override{++logouts;if(cache_fail)throw Error("LOGOUT_CACHE_FAILED");}
};
struct FakeHttp:Http {
    unsigned posts=0,gets=0,status=202,refreshes=0;bool ambiguous=false,forbidden=false,redirect=false,first401=false,empty_list=false;
    std::string state="deallocated",nextlink,poll;std::function<void(std::string const&)> on_get;
    Response send(Lease& lease,std::string const& method,std::string const& url,bool force,Cancel const& c,Guard guard={})override{
        host_path(url);if(force)++refreshes;auto token=lease.token(force,c);Response r;
        if(method=="POST"){auto lock=guard?guard():std::unique_lock<std::mutex>();++posts;if(lock.owns_lock())lock.unlock();if(ambiguous)throw Error("NETWORK_FAILED");r.status=forbidden?403:((first401&&posts==1)?401:status);r.poll=poll;r.async=!poll.empty();return r;}
        ++gets;if(on_get)on_get(url);c.check();if(forbidden){r.status=403;return r;}if(redirect){r.status=302;return r;}
        if(url.find("/instanceView?")!=std::string::npos){A a;J p;put(p,"code","PowerState/"+state);a.Append(p);put(r.body,"statuses",a);}
        else if(url.find("virtualMachines?")!=std::string::npos){A a;J v;put(v,"id",vm);put(v,"location","fixture-region");J p;put(p,"provisioningState","Succeeded");put(v,"properties",p);a.Append(v);put(r.body,"value",a);put(r.body,"nextLink",nextlink);}
        else if(url.find("virtualMachines/fixture-vm?")!=std::string::npos){put(r.body,"id",vm);put(r.body,"location","fixture-region");J p;put(p,"provisioningState","Succeeded");put(r.body,"properties",p);}
        else if(url.find("/tenants?")!=std::string::npos){A a;J v;put(v,"tenantId",tenant);put(v,"displayName","Fixture directory");a.Append(v);put(r.body,"value",a);put(r.body,"nextLink",nextlink);}
        else if(url.find("/subscriptions?")!=std::string::npos){A a;J v;put(v,"subscriptionId",sub);put(v,"tenantId",tenant);put(v,"displayName","Fixture subscription");a.Append(v);put(r.body,"value",a);put(r.body,"nextLink",nextlink);}
        else if(url.find("/resourcegroups?")!=std::string::npos){A a;J v;put(v,"id","/subscriptions/"+sub+"/resourceGroups/fixture-rg");put(v,"name","fixture-rg");put(v,"location","fixture-region");J tags;put(tags,"environment","fixture");put(v,"tags",tags);a.Append(v);put(r.body,"value",a);put(r.body,"nextLink",nextlink);}
        else put(r.body,"status","Succeeded");if(empty_list&&r.body.HasKey(L"value"))put(r.body,"value",A());return r;
    }
};
}