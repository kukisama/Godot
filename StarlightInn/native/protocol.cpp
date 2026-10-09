#include "core.hpp"
#include <tlhelp32.h>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <thread>
#ifdef INN_FIXTURE
#include "../tests/native_fake.hpp"
#endif
namespace {
DWORD parent_id(){DWORD id=0;HANDLE s=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);if(s==INVALID_HANDLE_VALUE)return 0;PROCESSENTRY32W p{};p.dwSize=sizeof p;if(Process32FirstW(s,&p))do{if(p.th32ProcessID==GetCurrentProcessId()){id=p.th32ParentProcessID;break;}}while(Process32NextW(s,&p));CloseHandle(s);return id;}
void write(std::string const& text){static std::mutex output_mutex;std::lock_guard output_lock(output_mutex);auto line=text+"\n";size_t offset=0;while(offset<line.size()){DWORD written=0;
#ifdef INN_FIXTURE
    DWORD chunk=static_cast<DWORD>(std::min<size_t>(7,line.size()-offset));
#else
    DWORD chunk=static_cast<DWORD>(line.size()-offset);
#endif
    inn::require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),line.data()+offset,chunk,&written,nullptr)&&written>0,"PIPE_CLOSED");offset+=written;}}
void boot_error(inn::NativeFailure const& e) noexcept{
    // Plain numeric/enum JSON also works if WinRT initialization itself failed.
        try{
            write(std::string("{\"kind\":\"boot_error\",\"code\":\"HELPER_BOOT_FAILED\",\"diagnostic\":{\"stage\":\"")+inn::native_stage(e.stage)+"\",\"hresult\":\""+inn::hex_code(e.hresult)+"\"}}");
            // Keep pipe handles alive until GD consumes the packet and closes EOF.
            // Never force GD to PeekNamedPipe an already-exited process handle.
            HANDLE owner=OpenProcess(SYNCHRONIZE,FALSE,parent_id());
            if(owner){auto until=inn::Clock::now()+std::chrono::seconds(5);DWORD available=0;
                while(inn::Clock::now()<until&&PeekNamedPipe(GetStdHandle(STD_INPUT_HANDLE),nullptr,0,nullptr,&available,nullptr)&&WaitForSingleObject(owner,20)==WAIT_TIMEOUT){}
                CloseHandle(owner);
            }
        }catch(...){}
}
}
int pipe_main(){
    using namespace inn;
    DWORD parent=parent_id();HANDLE owner=OpenProcess(SYNCHRONIZE,FALSE,parent);if(!owner)throw NativeFailure{NativeStage::HelperBoot,static_cast<uint32_t>(HRESULT_FROM_WIN32(GetLastError())),{},NativeKind::HelperBoot};
    struct QueuedPacket {J packet;unsigned long authEpoch;};
    std::atomic_bool stopping=false;std::mutex queue_mutex;std::condition_variable cv;std::deque<QueuedPacket> queue;
#ifdef INN_FIXTURE
    test::FakeIdentity identity;test::FakeHttp http;MemoryProfiles profiles;
    bool gated=false,fault_release=false;std::string execute_fault;
    std::wstring config_path=L"fixture-public-config-not-on-disk";
#else
    NativeIdentity identity(parent);NativeHttp http;DiskProfiles profiles(DiskProfiles::default_path());
    wchar_t exe[32768];DWORD count=GetModuleFileNameW(nullptr,exe,32768);if(!count||count>=32768){CloseHandle(owner);throw NativeFailure{NativeStage::HelperBoot,static_cast<uint32_t>(E_FAIL),{},NativeKind::HelperBoot};}
    auto config_path=(std::filesystem::path(exe).parent_path().parent_path()/L"azure-settings.json").wstring();
#endif
    Core core(identity,http,profiles);
    std::string config_error;
    try{
#ifndef INN_FIXTURE
        auto j=parse(read_file(config_path,4096));keys(j,{"client_id","initial_tenant"});core.configure({text(j,"client_id"),text(j,"initial_tenant","organizations")});
        core.persist=[config_path](Settings const& s){atomic_file(config_path,encode(s.dto()));};
#else
        core.configure({test::sub,"organizations"});
#endif
    }catch(Error const&){config_error="INVALID_APP_CONFIG：公开配置无效，请重新保存 ClientId 与初始目录。";}
    catch(...){config_error="INVALID_APP_CONFIG：公开配置读取失败；未输出原始异常。";}
    std::thread worker([&]{bool initialized=false;try{
        native_call(NativeStage::WinrtInit,[]{winrt::init_apartment(winrt::apartment_type::multi_threaded);});initialized=true;
        std::string journal;
        while(!stopping){J packet{nullptr};unsigned long authEpoch=0;{std::unique_lock lock(queue_mutex);cv.wait_for(lock,std::chrono::milliseconds(100),[&]{return stopping||!queue.empty();});if(stopping)break;
    #ifdef INN_FIXTURE
            if(gated){cv.wait(lock,[&]{return stopping||!gated;});if(stopping)break;}
    #endif
            if(!queue.empty()){packet=queue.front().packet;authEpoch=queue.front().authEpoch;queue.pop_front();}}
            if(packet){auto action=text(packet,"action");auto id=text(packet,"id");
#ifdef INN_FIXTURE
                if(action=="fixture_crash")break;
                if(action=="fixture_late"){std::unique_lock lock(queue_mutex);cv.wait_for(lock,std::chrono::milliseconds(350),[&]{return stopping.load();});}
                if(action=="fixture_hang")continue;
                if(action=="fixture_boot_fault")throw NativeFailure{NativeStage::WinrtInit,static_cast<uint32_t>(E_FAIL),{},NativeKind::HelperBoot};
                if(action=="fixture_auth_fault"){
                    auto mode=text(object(packet,"args"),"mode");require(mode=="hresult"||mode=="provider"||mode=="missing","INVALID_ARGUMENTS");
                    identity.on_login=[mode](Cancel const&){
                        if(mode=="missing")throw NativeFailure{NativeStage::FindProvider,0,{},NativeKind::ProviderMissing};
                        if(mode=="provider")throw NativeFailure{NativeStage::RequestToken,0,0xcaa20008u};
                        native_call(NativeStage::RequestToken,[]{throw winrt::hresult_error(E_FAIL,L"CANARY_SECRET_TOKEN username@example.invalid client-guid response-body");});
                    };
                    J r;put(r,"id",id);put(r,"action",action);put(r,"ok",true);put(r,"data",J());write(encode(r));continue;
                }
                if(action=="fixture_arm_execute_fault"){execute_fault=text(object(packet,"args"),"mode");require(execute_fault=="reply"||execute_fault=="timeout","INVALID_ARGUMENTS");}
                if(action=="fixture_stats"||action=="fixture_arm_execute_fault"){J r;put(r,"id",id);put(r,"action",action);put(r,"ok",true);J data;put(data,"identity_calls",static_cast<double>(identity.calls));put(r,"data",data);write(encode(r));continue;}
                if(action=="fixture_echo"){J r;put(r,"id",id);put(r,"action",action);put(r,"ok",true);put(r,"data",object(packet,"args"));put(r,"context",core.current());put(r,"preferences",core.preferences());write(encode(r));continue;}
#endif
                if(action=="bootstrap"){J r;put(r,"kind","ready");put(r,"settings",core.configuration());put(r,"context",core.current());put(r,"preferences",core.preferences());put(r,"path",winrt::to_string(config_path));put(r,"error",config_error);
#ifndef INN_FIXTURE
                    put(r,"profile_path",winrt::to_string(profiles.path));
#else
                    put(r,"profile_path","fixture-memory-only");
#endif
                    write(encode(r));
                }else{auto hwnd=static_cast<uintptr_t>(packet.GetNamedNumber(L"hwnd",0));auto reply=core.dispatch(id,action,object(packet,"args"),reinterpret_cast<HWND>(hwnd),authEpoch);
#ifdef INN_FIXTURE
                    if(action=="execute"&&!execute_fault.empty()){require(boolean(reply,"ok")&&http.posts==1,"FIXTURE_EXECUTE_FAILED");J evidence;put(evidence,"kind","fixture_evidence");put(evidence,"data",object(reply,"data"));put(evidence,"posts",static_cast<double>(http.posts));write(encode(evidence));if(execute_fault=="reply")write(encode(reply));std::unique_lock lock(queue_mutex);cv.wait(lock,[&]{return stopping||fault_release;});break;}
#endif
                    write(encode(reply));}}
            core.tick();auto entries=encode(core.operations());if(entries!=journal){journal=entries;J r;put(r,"kind","journal");put(r,"data",core.operations());write(encode(r));}
        }
    }catch(NativeFailure const& e){boot_error(e);}
    catch(...){boot_error({NativeStage::HelperBoot,static_cast<uint32_t>(E_FAIL),{},NativeKind::HelperBoot});}
    if(initialized)winrt::uninit_apartment();stopping=true;cv.notify_all();});
    try {std::string rx;char bytes[4096];
        while(!stopping&&WaitForSingleObject(owner,0)==WAIT_TIMEOUT){DWORD available=0;if(!PeekNamedPipe(GetStdHandle(STD_INPUT_HANDLE),nullptr,0,nullptr,&available,nullptr))break;
            if(!available){WaitForSingleObject(owner,20);continue;}DWORD n=0;if(!ReadFile(GetStdHandle(STD_INPUT_HANDLE),bytes,std::min<DWORD>(available,sizeof bytes),&n,nullptr)||!n)break;rx.append(bytes,n);require(rx.size()<=1024*1024,"REQUEST_TOO_LARGE");
            size_t pos;while((pos=rx.find('\n'))!=std::string::npos){auto line=rx.substr(0,pos);rx.erase(0,pos+1);auto p=parse(line);keys(p,{"id","action","args","hwnd"});auto action=text(p,"action");require(clean(text(p,"id"),100),"INVALID_REQUEST");if(action=="shutdown"){stopping=true;break;}
                if(action=="cancel_login"||action=="cancel_queries"||action=="cancel_confirmation"){core.control(action);continue;}
#ifdef INN_FIXTURE
                if(action=="fixture_gate"||action=="fixture_release"||action=="fixture_fault_release"){{std::lock_guard lock(queue_mutex);if(action=="fixture_gate")gated=true;else if(action=="fixture_release")gated=false;else fault_release=true;}cv.notify_all();J ack;put(ack,"id",text(p,"id"));put(ack,"action",action);put(ack,"ok",true);put(ack,"data",J());write(encode(ack));continue;}
#endif
                if(action=="logout")core.control("disconnect");if(action=="auto_login"&&!boolean(object(p,"args"),"enabled",true))core.control("cancel_login");
                auto authEpoch=core.authGeneration();{std::lock_guard lock(queue_mutex);require(queue.size()<64,"QUEUE_FULL");queue.push_back({p,authEpoch});}cv.notify_one();}}
    }catch(...){/* malformed packet fails closed; never echo raw bytes */}
    stopping=true;core.shutdown();cv.notify_all();CancelSynchronousIo(worker.native_handle());worker.join();CloseHandle(owner);return 0;
}
int wmain(int argc,wchar_t** argv){
    if(argc!=2||std::wstring(argv[1])!=L"--pipe-v2")return 64;
    if(GetFileType(GetStdHandle(STD_INPUT_HANDLE))!=FILE_TYPE_PIPE||GetFileType(GetStdHandle(STD_OUTPUT_HANDLE))!=FILE_TYPE_PIPE)return 65;
    bool initialized=false;int result=68;
    try{inn::native_call(inn::NativeStage::WinrtInit,[]{winrt::init_apartment(winrt::apartment_type::multi_threaded);});initialized=true;result=pipe_main();}
    catch(inn::NativeFailure const& e){boot_error(e);}
    catch(...){boot_error({inn::NativeStage::HelperBoot,static_cast<uint32_t>(E_FAIL),{},inn::NativeKind::HelperBoot});}
    if(initialized)winrt::uninit_apartment();return result;
}