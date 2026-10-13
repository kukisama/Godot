#include "core.hpp"
namespace inn {
namespace {
constexpr const char* arm="https://management.azure.com";
constexpr const char* version="?api-version=2025-04-01";
std::string lower(std::string s){std::transform(s.begin(),s.end(),s.begin(),[](unsigned char c){return static_cast<char>(tolower(c));});return s;}
A values(J const& j){require(j.HasKey(L"value")&&j.Lookup(L"value").ValueType()==JsonValueType::Array,"INVALID_RESPONSE");auto a=j.GetNamedArray(L"value");for(auto const& v:a)require(v.ValueType()==JsonValueType::Object,"INVALID_RESPONSE");return a;}
J namedid(std::string const& id,std::string const& name){J j;put(j,"id",id);put(j,"name",name.empty()?id:name);return j;}
J page(A const& items,bool more,const char* notice){J j;put(j,"items",items);put(j,"has_more",more);put(j,"notice",notice);return j;}
const char* message(std::string const& code){
    if(code=="FORBIDDEN")return "403：当前账户缺少此资源范围的 Azure RBAC 权限，未提升权限。";
    if(code=="EXPIRED_CONFIRMATION")return "最终提交前确认已过期，未发送 POST；请重新核对目标。";
    if(code=="INTERACTION_REQUIRED")return "需要用户重新验证；请主动点击登录，查询不会弹窗。";
    if(code=="LOGOUT_INCOMPLETE")return "本进程已断开，但磁盘身份档案与应用缓存均清理失败；下次启动仍可能恢复。";
    if(code=="PROFILE_IO")return "磁盘档案保存失败；本进程已断开时，下次启动仍可能尝试恢复。";
    if(code=="LOGOUT_CACHE_FAILED")return "本应用认证缓存清理失败；未删除 Windows 账户。";
    if(code=="WAM_UNAVAILABLE")return "Win32 WAM 接口不可用；未启动浏览器。";
    if(code=="BROWSER_DISABLED")return "此版本仅使用原生 WAM，不支持浏览器参数。";
    if(code=="OPERATION_ACTIVE")return "原资源已有在途或结果不确定操作；禁止重复提交，请查看原记录。";
    return "请求未完成，已按安全边界拒绝；未输出令牌、响应原文或原始异常。";
}
}
Core::Core(Identity& i,Http& h,Profiles& p,std::function<Clock::time_point()> clock):identity(i),http(h),profiles(p),now(std::move(clock)){
    try{profile=profiles.load();profile.validate();}catch(...){profile={};notice="账户档案无效，需要手动重新登录；旧 MSAL 档案未读取。";}advance("","","","","");
}
void Core::advance(std::string const& account,std::string const& tenant,std::string const& name,std::string const& sub,std::string const& subname){
    query->store(true);query=std::make_shared<std::atomic_bool>(false);tickets.clear();vms.clear();next.clear();context=J();
    put(context,"generation",static_cast<double>(++generation));put(context,"account",account);put(context,"tenant_id",tenant);put(context,"tenant_name",name);put(context,"subscription_id",sub);put(context,"subscription_name",subname);
}
void Core::configure(Settings const& s){s.validate(false);std::lock_guard lock(mutex);require(!lease&&!auth_busy,"LOGOUT_REQUIRED");if(persist)persist(s);auth->store(true);++auth_generation;settings=s;advance("","","","","");}
J Core::current(){std::lock_guard lock(mutex);return parse(encode(context));}
J Core::configuration(){std::lock_guard lock(mutex);return settings.dto();}
unsigned long Core::authGeneration(){std::lock_guard lock(mutex);return auth_generation;}
J Core::prefs_locked(){J j;put(j,"auto_login",profile.auto_login);put(j,"has_identity",!profile.account_id.empty());put(j,"restoring",restoring);put(j,"notice",notice);return j;}
J Core::preferences(){std::lock_guard lock(mutex);return prefs_locked();}
A Core::operations(){std::lock_guard lock(mutex);A a;for(auto const& [id,j]:jobs)a.Append(parse(encode(j.dto)));return a;}
void Core::control(std::string const& action){std::lock_guard lock(mutex);
    if(action=="cancel_login"){auth->store(true);++auth_generation;}
    else if(action=="cancel_confirmation")tickets.clear();
    else if(action=="cancel_queries"){auth->store(true);++auth_generation;advance(text(context,"account"),text(context,"tenant_id"),text(context,"tenant_name"),text(context,"subscription_id"),text(context,"subscription_name"));}
    else if(action=="disconnect"){auth->store(true);++auth_generation;lease.reset();tenants.clear();subs.clear();advance("","","","","");}
    else throw Error("UNSUPPORTED_ACTION");
}
void Core::shutdown(){lifetime->store(true);control("cancel_login");control("cancel_queries");}
Core::Snapshot Core::capture(bool sub){std::lock_guard lock(mutex);require(!auth_busy,"LOGIN_BUSY");require(static_cast<bool>(lease),"NOT_CONNECTED");require(!sub||!text(context,"subscription_id").empty(),"SELECT_SUBSCRIPTION");Cancel c;c.flag=query;c.lifetime=lifetime;return {parse(encode(context)),lease,c};}
void Core::check(Snapshot const& s){require(s.context.GetNamedNumber(L"generation")==context.GetNamedNumber(L"generation")&&!s.cancel.flag->load(),"STALE_CONTEXT");}
void Core::save(Profile const& p){profiles.save(p);profile=p;}
void Core::remember(){if(!lease)return;Profile p{profile.auto_login,settings.client,settings.initial,lease->account_id,lease->provider,lease->username,lease->tenant,text(context,"subscription_id"),text(context,"subscription_name")};save(p);}
J Core::login(J const& args,HWND hwnd,std::optional<unsigned long> expected){
    keys(args,{"browser","select_account","tenant"});require(!boolean(args,"browser"),"BROWSER_DISABLED");Settings config;std::shared_ptr<Lease> old;std::string tenant;bool select;unsigned long serial;Cancel c;
    {std::lock_guard lock(mutex);require(!expected||*expected==auth_generation,"CANCELLED_OR_TIMEOUT");require(!lifetime->load(),"CANCELLED_OR_TIMEOUT");require(!auth_busy,"LOGIN_BUSY");settings.validate();config=settings;old=lease;select=boolean(args,"select_account")||!old;tenant=text(args,"tenant",config.initial);if(tenant.empty())tenant=config.initial;
        require(tenant==config.initial||eq(tenant,text(context,"tenant_id"))||tenants.count(lower(tenant)),"INVALID_TENANT");require(tenant=="organizations"||guid(tenant),"INVALID_TENANT");auth=std::make_shared<std::atomic_bool>(false);c.flag=auth;c.lifetime=lifetime;c.deadline=Clock::now()+std::chrono::minutes(3);serial=++auth_generation;auth_busy=true;subs.clear();advance(text(context,"account"),text(context,"tenant_id"),text(context,"tenant_name"),"","");}
    try{auto result=identity.login(config,tenant,old,select,hwnd,c);c.check();Profile checkp{profile.auto_login,config.client,config.initial,result->account_id,result->provider,result->username,result->tenant,"",""};checkp.validate();require(eq(result->client,config.client)&&(!old||select||result->account_id==old->account_id),"ACCOUNT_CHANGED");
        std::lock_guard lock(mutex);require(serial==auth_generation,"CANCELLED_OR_TIMEOUT");lease=result;if(select)tenants.clear();advance(result->username,result->tenant,result->tenant,"","");remember();auth_busy=false;notice="已记住原生 WAM 明确账户；组织要求时需手动重新验证。";return parse(encode(context));
    }catch(...){std::lock_guard lock(mutex);auth_busy=false;throw;}
}
J Core::restore(std::optional<unsigned long> expected){
    Settings config;Profile saved;Cancel c;unsigned long serial;
    {std::lock_guard lock(mutex);require(!expected||*expected==auth_generation,"CANCELLED_OR_TIMEOUT");require(!lifetime->load(),"CANCELLED_OR_TIMEOUT");if(lease||!profile.auto_login||profile.account_id.empty()||settings.client.empty())return parse(encode(context));require(!auth_busy,"LOGIN_BUSY");saved=profile;config=settings;saved.match(config);serial=++auth_generation;auth=std::make_shared<std::atomic_bool>(false);c.flag=auth;c.lifetime=lifetime;auth_busy=true;restoring=true;advance("","","","","");}
    try{auto result=identity.restore(config,saved,c);c.check();require(result->account_id==saved.account_id&&eq(result->tenant,saved.tenant)&&eq(result->client,config.client)&&!result->username.empty(),"ACCOUNT_CHANGED");std::map<std::string,J> found;std::string restore_notice="账户已恢复，请选择订阅。";
        if(!saved.sub.empty())try{std::string url=std::string(arm)+"/subscriptions?api-version=2022-12-01";std::set<std::string> visited;Cancel subcancel=c;subcancel.deadline=Clock::now()+std::chrono::seconds(30);
            for(unsigned n=0;n<max_restore_pages&&visited.insert(url).second;++n){auto raw=get(result,url,subcancel);for(auto const& v:values(raw)){auto row=v.GetObject();auto id=text(row,"subscriptionId");require(guid(id),"INVALID_RESPONSE");auto t=text(row,"tenantId");if(!t.empty()&&!eq(t,result->tenant))continue;found[lower(id)]=namedid(id,text(row,"displayName"));}if(found.count(lower(saved.sub)))break;url=text(raw,"nextLink");if(url.empty())break;page_url(url,"/subscriptions");}
            if(found.count(lower(saved.sub)))restore_notice="账户、目录及订阅已重新验证。";
        }catch(...){found.clear();restore_notice="账户已恢复；订阅查询未完成，请重新选择订阅。";}
        std::lock_guard lock(mutex);require(serial==auth_generation&&profile.auto_login&&!c.flag->load(),"CANCELLED_OR_TIMEOUT");lease=result;subs=found;auto sub=found.find(lower(saved.sub));advance(result->username,result->tenant,result->tenant,sub==found.end()?"":text(sub->second,"id"),sub==found.end()?"":text(sub->second,"name"));auth_busy=false;restoring=false;notice=restore_notice;return parse(encode(context));
    }catch(...){std::lock_guard lock(mutex);auth_busy=false;restoring=false;if(serial==auth_generation){lease.reset();subs.clear();tenants.clear();advance("","","","","");notice="需要手动重新登录；静默恢复未完成，未弹窗。";}throw;}
}
void Core::logout(std::optional<unsigned long> expected){Profile saved;bool disk=false,cache=false;{std::lock_guard lock(mutex);saved=profile;auth->store(true);if(!expected)++auth_generation;lease.reset();tenants.clear();subs.clear();advance("","","","","");Profile empty;empty.auto_login=profile.auto_login;profile=empty;try{save(empty);}catch(...){disk=true;}notice="本应用已断开，缓存清理尚未完成。";}
    Cancel c;c.lifetime=lifetime;try{identity.logout(saved,c);}catch(...){cache=true;}
    {std::lock_guard lock(mutex);notice=disk?"磁盘身份档案未清空，下次启动仍可能恢复；本进程已断开。":(cache?"磁盘身份已清空，认证缓存未完全清理。":"已仅注销本应用；公开配置保留，云操作未撤销。");}
    if(disk||cache)throw Error(disk?(cache?"LOGOUT_INCOMPLETE":"PROFILE_IO"):"LOGOUT_CACHE_FAILED");
}
Response Core::send(std::shared_ptr<Lease> l,std::string const& method,std::string const& url,Cancel const& c){host_path(url);auto r=http.send(*l,method,url,false,c);if(r.status==401){c.check();r=http.send(*l,method,url,true,c);}return r;}
J Core::get(std::shared_ptr<Lease> l,std::string const& url,Cancel const& c){auto r=send(l,"GET",url,c);success(r);return r.body;}
J Core::named(std::string const& kind,bool more){auto s=capture(false);auto path="/"+kind;std::string url;{std::lock_guard lock(mutex);check(s);if(more){require(next.count(kind)!=0,"NO_MORE");url=next.at(kind);}else{next.erase(kind);url=std::string(arm)+path+"?api-version=2022-12-01";}}
    auto raw=get(s.lease,url,s.cancel);A a;std::map<std::string,J> found;for(auto const& v:values(raw)){auto row=v.GetObject();auto id=text(row,kind=="tenants"?"tenantId":"subscriptionId");require(guid(id),"INVALID_RESPONSE");auto tenant=text(row,"tenantId");if(kind=="subscriptions"&&!tenant.empty()&&!eq(tenant,s.lease->tenant))continue;auto item=namedid(id,text(row,"displayName"));found[lower(id)]=item;a.Append(item);}
    auto n=text(raw,"nextLink");if(!n.empty())page_url(n,path);{std::lock_guard lock(mutex);check(s);auto& target=kind=="tenants"?tenants:subs;if(!more)target.clear();for(auto const& item:found)target[item.first]=item.second;if(n.empty())next.erase(kind);else next[kind]=n;}
    return page(a,!n.empty(),"每次一个服务端分页，未静默截断；可继续读取。");
}
J Core::mapvm(J const& row,std::string const& sub){auto r=resource(text(row,"id"),sub);auto props=object(row,"properties");J j;put(j,"resource_id",r.id);put(j,"name",r.name);put(j,"resource_group",r.group);put(j,"region",text(row,"location"));put(j,"size",text(object(props,"hardwareProfile"),"vmSize"));put(j,"power_state",power(object(props,"instanceView")));put(j,"last_refresh",stamp());J tags;for(auto const& pair:object(row,"tags")){require(pair.Value().ValueType()==JsonValueType::String,"INVALID_RESPONSE");tags.Insert(pair.Key(),pair.Value());}put(j,"tags",tags);put(j,"provisioning_state",text(props,"provisioningState"));put(j,"os_type",text(object(object(props,"storageProfile"),"osDisk"),"osType"));return j;}
J Core::readvm(std::shared_ptr<Lease> l,J const& ctx,std::string const& id,Cancel const& c){auto canonical=resource(id,text(ctx,"subscription_id")).id;auto vm=mapvm(get(l,std::string(arm)+canonical+version,c),text(ctx,"subscription_id"));require(eq(text(vm,"resource_id"),canonical),"INVALID_RESPONSE");put(vm,"power_state",power(get(l,std::string(arm)+canonical+"/instanceView"+version,c)));return vm;}
void Core::known(Snapshot const& s,std::string const& id){resource(id,text(s.context,"subscription_id"));std::lock_guard lock(mutex);check(s);require(vms.count(lower(id))!=0,"INVALID_TARGET");}
J Core::listvms(bool more){auto s=capture();auto path="/subscriptions/"+text(s.context,"subscription_id")+"/providers/Microsoft.Compute/virtualMachines";std::string url;{std::lock_guard lock(mutex);check(s);if(more){require(next.count("vms")!=0,"NO_MORE");url=next.at("vms");}else{next.erase("vms");url=std::string(arm)+path+version+"&statusOnly=true";}}
    auto raw=get(s.lease,url,s.cancel);A a;std::map<std::string,J> found;for(auto const& v:values(raw)){auto vm=mapvm(v.GetObject(),text(s.context,"subscription_id"));found[lower(text(vm,"resource_id"))]=vm;a.Append(vm);}auto n=text(raw,"nextLink");if(!n.empty())page_url(n,path);{std::lock_guard lock(mutex);check(s);if(!more)vms.clear();for(auto const& item:found)vms[item.first]=item.second;if(n.empty())next.erase("vms");else next["vms"]=n;}return page(a,!n.empty(),"缺失状态显示 unknown；筛选仅作用于已加载页。");
}
J Core::resourcegroups(bool more){
    auto s=capture();auto path="/subscriptions/"+text(s.context,"subscription_id")+"/resourcegroups";std::string url;
    {std::lock_guard lock(mutex);check(s);if(more){require(next.count("resource_groups")!=0,"NO_MORE");url=next.at("resource_groups");}else{next.erase("resource_groups");url=std::string(arm)+path+"?api-version=2021-04-01";}}
    auto raw=get(s.lease,url,s.cancel);A items;
    for(auto const& value:values(raw)){
        auto row=value.GetObject();auto id=text(row,"id");auto name=text(row,"name");
        require(!name.empty()&&clean(name)&&eq(id,"/subscriptions/"+text(s.context,"subscription_id")+"/resourceGroups/"+name),"INVALID_RESPONSE");
        // Reuse canonical resource-group validation; do not trust returned paths.
        resource(id+"/providers/Microsoft.Compute/virtualMachines/validation",text(s.context,"subscription_id"));
        J item;put(item,"id",id);put(item,"name",name);put(item,"region",text(row,"location"));J tags;
        for(auto const& pair:object(row,"tags")){require(pair.Value().ValueType()==JsonValueType::String,"INVALID_RESPONSE");tags.Insert(pair.Key(),pair.Value());}
        put(item,"tags",tags);items.Append(item);
    }
    auto n=text(raw,"nextLink");if(!n.empty())page_url(n,path);
    {std::lock_guard lock(mutex);check(s);if(n.empty())next.erase("resource_groups");else next["resource_groups"]=n;}
    return page(items,!n.empty(),"资源组只读查询；可继续读取服务端下一页。");
}
J Core::inspect(std::string const& id){auto s=capture();known(s,id);auto vm=readvm(s.lease,s.context,id,s.cancel);{std::lock_guard lock(mutex);check(s);vms[lower(id)]=vm;}return vm;}
void Core::no_active(std::string const& id){for(auto const& [key,job]:jobs){auto state=text(job.dto,"state");if(eq(text(object(job.dto,"target"),"resource_id"),id)&&state!="succeeded"&&state!="failed")throw Error("OPERATION_ACTIVE");}}
J Core::prepare(std::string const& id,std::string const& action){require(action=="start"||action=="deallocate","UNSUPPORTED_ACTION");auto s=capture();known(s,id);auto vm=readvm(s.lease,s.context,id,s.cancel);auto nonce=uuid();J j;put(j,"nonce",nonce);put(j,"context",s.context);put(j,"target",vm);put(j,"action",action);put(j,"impact",action=="start"?"将启动真实 VM 并产生计算费用。":"将中断业务并解除分配；磁盘、IP 等仍可能计费，不是零费用。");
    SYSTEMTIME st{};GetSystemTime(&st);FILETIME ft{};SystemTimeToFileTime(&st,&ft);ULARGE_INTEGER time{};time.LowPart=ft.dwLowDateTime;time.HighPart=ft.dwHighDateTime;time.QuadPart+=static_cast<ULONGLONG>(ttl.count())*10000000;ft.dwLowDateTime=time.LowPart;ft.dwHighDateTime=time.HighPart;FileTimeToSystemTime(&ft,&st);char exp[40];sprintf_s(exp,"%04u-%02u-%02uT%02u:%02u:%02uZ",st.wYear,st.wMonth,st.wDay,st.wHour,st.wMinute,st.wSecond);put(j,"expires",exp);
    {std::lock_guard lock(mutex);check(s);no_active(id);tickets.clear();tickets.emplace(nonce,Ticket{j,now()+ttl});}return j;
}
void Core::update(Job& j,const char* state,const char* msg){put(j.dto,"state",state);put(j.dto,"message",msg);put(j.dto,"updated",stamp());}
J Core::execute(std::string const& nonce){auto s=capture();Ticket t;{std::lock_guard lock(mutex);auto it=tickets.find(nonce);require(it!=tickets.end(),"INVALID_CONFIRMATION");t=it->second;tickets.erase(it);require(now()<t.expires,"EXPIRED_CONFIRMATION");check(s);require(object(t.dto,"context").GetNamedNumber(L"generation")==context.GetNamedNumber(L"generation"),"STALE_CONTEXT");no_active(text(object(t.dto,"target"),"resource_id"));}
    auto fresh=readvm(s.lease,s.context,text(object(t.dto,"target"),"resource_id"),s.cancel);require(text(fresh,"power_state")==text(object(t.dto,"target"),"power_state")&&text(fresh,"provisioning_state")==text(object(t.dto,"target"),"provisioning_state"),"TARGET_CHANGED");auto id=uuid();auto url=std::string(arm)+resource(text(fresh,"resource_id"),text(s.context,"subscription_id")).id+"/"+text(t.dto,"action")+version;
    bool sent=false;Cancel jobcancel;jobcancel.lifetime=lifetime;
    auto before=[&](){std::unique_lock lock(mutex);check(s);require(now()<t.expires,"EXPIRED_CONFIRMATION");if(!sent){no_active(text(fresh,"resource_id"));J d;put(d,"id",id);put(d,"context",s.context);put(d,"target",fresh);put(d,"action",text(t.dto,"action"));Job j{d,s.lease,"",false,false,0,now(),now()+poll_budget};update(j,"submitting","正在提交；关闭面板不撤销云端操作。");jobs.emplace(id,std::move(j));sent=true;}return lock;};
    try{auto r=http.send(*s.lease,"POST",url,false,jobcancel,before);if(r.status==401){jobcancel.deadline=Clock::now()+std::chrono::seconds(30);r=http.send(*s.lease,"POST",url,true,jobcancel,before);}success(r);std::lock_guard lock(mutex);auto& j=jobs.at(id);j.ack=true;j.poll=r.poll.empty()?r.location:r.poll;j.async=r.async;j.due=now()+std::chrono::seconds(r.retry);update(j,"submitted","Azure 已受理，尚未确认完成；未声明成功。");if(!j.poll.empty())try{poll_url(j.poll,text(s.context,"subscription_id"));}catch(...){update(j,"deferred","已受理，但轮询地址被拒绝；请查看原资源，不要重复提交。");}return parse(encode(j.dto));}
    catch(Error const& e){if(!sent)throw;std::lock_guard lock(mutex);auto& j=jobs.at(id);bool rejected=e.code=="FORBIDDEN"||e.code=="INTERACTION_REQUIRED"||e.code=="REDIRECT_BLOCKED"||(e.code.rfind("ARM_HTTP_4",0)==0&&e.code!="ARM_HTTP_408");update(j,rejected?"failed":"unknown",message(e.code));return parse(encode(j.dto));}
    catch(...){if(!sent)throw;std::lock_guard lock(mutex);auto& j=jobs.at(id);update(j,"unknown","原 POST 结果不确定，禁止自动重发；当前目标状态不能证明原提交成功。");return parse(encode(j.dto));}
}
void Core::tick(){std::string id;Job copy;{std::lock_guard lock(mutex);for(auto const& [key,j]:jobs){auto state=text(j.dto,"state");if((state=="submitted"||state=="pending")&&now()>=j.due){id=key;copy=j;break;}}}if(id.empty())return;const char* state="pending";const char* msg="操作尚未达到目标状态。";Cancel c;c.lifetime=lifetime;
    try{require(copy.count<max_polls&&now()<copy.deadline,"POLL_BUDGET");
        if(!copy.poll.empty()){poll_url(copy.poll,text(object(copy.dto,"context"),"subscription_id"));auto r=send(copy.lease,"GET",copy.poll,c);success(r);copy.due=now()+std::chrono::seconds(r.retry);auto status=text(r.body,"status");if(eq(status,"Failed")||eq(status,"Canceled")){state="failed";msg="Azure 返回操作失败/取消。";}else if((copy.async&&!eq(status,"Succeeded"))||r.status==202){state="pending";msg="Azure 仍在处理，尚未成功。";}else copy.poll.clear();}
        if(copy.poll.empty()&&std::string(state)!="failed"){auto vm=readvm(copy.lease,object(copy.dto,"context"),text(object(copy.dto,"target"),"resource_id"),c);if(!copy.ack){state="unknown";msg="目标当前状态已读取，但原提交仍未知；未重发 POST。";}else if(text(vm,"power_state")== (text(copy.dto,"action")=="start"?"running":"deallocated")){state="succeeded";msg="Azure 已受理且原资源实例状态已达成。";}}
        ++copy.count;if(copy.due<=now())copy.due=now()+std::chrono::seconds(std::min(30u,2+copy.count*2));if(copy.due>=copy.deadline||copy.due-now()>std::chrono::seconds(60)){state=copy.ack?"deferred":"unknown";msg="本地轮询预算或 Retry-After 上限已到；云端结果待核对，禁止盲目重发。";}
    }catch(...){state=copy.ack?"deferred":"unknown";msg="原操作查询未完成；已保留原账户/目录/订阅租约，不重发 POST。";}
    {std::lock_guard lock(mutex);auto& j=jobs.at(id);j.poll=copy.poll;j.due=copy.due;j.count=copy.count;update(j,state,msg);}
}
J Core::dispatch(std::string const& id,std::string const& action,J const& args,HWND hwnd,std::optional<unsigned long> expectedAuthGeneration){J reply;V data=JsonValue::CreateNullValue();bool ok=true;std::string code,msg;
    try{require(!id.empty()&&clean(id,100),"INVALID_REQUEST");
        if(action=="configure"){keys(args,{"client_id","initial_tenant"});Settings s{text(args,"client_id"),text(args,"initial_tenant","organizations")};configure(s);data=s.dto();msg="公开配置已保存，尚未登录。";}
        else if(action=="login")data=login(args,hwnd,expectedAuthGeneration);
        else if(action=="restore"){keys(args,{});data=restore(expectedAuthGeneration);}
        else if(action=="logout"){keys(args,{});logout(expectedAuthGeneration);data=current();}
        else if(action=="auto_login"){keys(args,{"enabled"});require(args.HasKey(L"enabled"),"INVALID_ARGUMENTS");std::lock_guard lock(mutex);auto p=profile;p.auto_login=boolean(args,"enabled");save(p);if(!p.auto_login){auth->store(true);if(!expectedAuthGeneration)++auth_generation;}data=parse(encode(context));}
        else if(action=="tenants"||action=="subscriptions"){keys(args,{"more"});data=named(action,boolean(args,"more"));}
        else if(action=="select_subscription"){keys(args,{"id"});std::lock_guard lock(mutex);require(static_cast<bool>(lease),"NOT_CONNECTED");auto it=subs.find(lower(text(args,"id")));require(it!=subs.end(),"INVALID_SUBSCRIPTION");advance(text(context,"account"),text(context,"tenant_id"),text(context,"tenant_name"),text(it->second,"id"),text(it->second,"name"));remember();data=parse(encode(context));}
        else if(action=="vms"){keys(args,{"more"});data=listvms(boolean(args,"more"));}
        else if(action=="resource_groups"){keys(args,{"more"});data=resourcegroups(boolean(args,"more"));}
        else if(action=="inspect"){keys(args,{"resource_id"});data=inspect(text(args,"resource_id"));}
        else if(action=="prepare"){keys(args,{"resource_id","action"});data=prepare(text(args,"resource_id"),text(args,"action"));}
        else if(action=="execute"){keys(args,{"nonce"});data=execute(text(args,"nonce"));}
        else if(action=="operations"){keys(args,{});data=operations();}
        else if(action=="resume"){keys(args,{"id"});std::lock_guard lock(mutex);auto it=jobs.find(text(args,"id"));require(it!=jobs.end(),"INVALID_OPERATION");auto& j=it->second;if(text(j.dto,"state")=="unknown"||text(j.dto,"state")=="deferred"){if(!j.poll.empty())try{poll_url(j.poll,text(object(j.dto,"context"),"subscription_id"));}catch(...){j.poll.clear();}j.count=0;j.deadline=now()+poll_budget;j.due=now();update(j,"pending","继续只读核对原记录，未重发 POST。");}A a;for(auto const& [key,job]:jobs)a.Append(parse(encode(job.dto)));data=a;}
        else throw Error("UNSUPPORTED_ACTION");
    }catch(NativeFailure const& e){ok=false;code=e.code();msg=e.message();put(reply,"diagnostic",e.dto());}
    catch(Error const& e){ok=false;code=e.code;msg=message(code);}catch(...){ok=false;code="REQUEST_FAILED";msg=message(code);}
    put(reply,"id",id);put(reply,"action",action);put(reply,"ok",ok);put(reply,"code",code);put(reply,"message",msg);put(reply,"data",data);put(reply,"context",current());put(reply,"preferences",preferences());put(reply,"mode","real");return reply;
}
}