#include "common.hpp"
#include <winhttp.h>

namespace inn {
namespace {
struct Handle {HINTERNET h=nullptr;explicit Handle(HINTERNET v):h(v){require(h!=nullptr,"NETWORK_FAILED");}~Handle(){WinHttpCloseHandle(h);}operator HINTERNET()const{return h;}};
struct HeaderSecret {std::wstring bytes;explicit HeaderSecret(std::string const& token){bytes.reserve(token.size()+32);bytes=L"Authorization: Bearer ";for(unsigned char ch:token){require(ch>=33&&ch<=126,"INVALID_IDENTITY");bytes.push_back(static_cast<wchar_t>(ch));}bytes+=L"\r\n";}~HeaderSecret(){SecureZeroMemory(bytes.data(),bytes.size()*sizeof(wchar_t));}};
std::string header(HINTERNET h,const wchar_t* name){DWORD n=0;WinHttpQueryHeaders(h,WINHTTP_QUERY_CUSTOM,name,nullptr,&n,nullptr);if(GetLastError()!=ERROR_INSUFFICIENT_BUFFER)return "";require(n<=16384,"INVALID_RESPONSE");std::wstring b(n/sizeof(wchar_t),0);require(WinHttpQueryHeaders(h,WINHTTP_QUERY_CUSTOM,name,b.data(),&n,nullptr)!=0,"INVALID_RESPONSE");b.resize(n/sizeof(wchar_t));while(!b.empty()&&b.back()==0)b.pop_back();return winrt::to_string(b);}
}
Response NativeHttp::send(Lease& lease,std::string const& method,std::string const& url,bool force,Cancel const& cancel,Guard before){
    host_path(url);require(method=="GET"||method=="POST","UNSUPPORTED_ACTION");cancel.check();
    Secret token=lease.token(force,cancel);cancel.check();
    Handle session(WinHttpOpen(L"StarlightInn/native-v2",WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,WINHTTP_NO_PROXY_NAME,WINHTTP_NO_PROXY_BYPASS,0));
    require(WinHttpSetTimeouts(session,30000,30000,30000,30000)!=0,"NETWORK_FAILED");
    Handle connection(WinHttpConnect(session,L"management.azure.com",INTERNET_DEFAULT_HTTPS_PORT,0));
    auto path=url.substr(url.find('/',8));
    Handle req(WinHttpOpenRequest(connection,wide(method).c_str(),wide(path).c_str(),nullptr,WINHTTP_NO_REFERER,WINHTTP_DEFAULT_ACCEPT_TYPES,WINHTTP_FLAG_SECURE));
    DWORD policy=WINHTTP_OPTION_REDIRECT_POLICY_NEVER;require(WinHttpSetOption(req,WINHTTP_OPTION_REDIRECT_POLICY,&policy,sizeof policy)!=0,"NETWORK_FAILED");
    // Certificate validation remains Windows default. Token/header never crosses pipes.
    HeaderSecret auth(token.bytes);
    cancel.check();
    auto guard=before?before():std::unique_lock<std::mutex>();
    bool sent=WinHttpSendRequest(req,auth.bytes.c_str(),static_cast<DWORD>(auth.bytes.size()),WINHTTP_NO_REQUEST_DATA,0,0,0)!=0;
    if(guard.owns_lock())guard.unlock();
    SecureZeroMemory(auth.bytes.data(),auth.bytes.size()*sizeof(wchar_t));require(sent,"NETWORK_FAILED");cancel.check();
    require(WinHttpReceiveResponse(req,nullptr)!=0,"NETWORK_FAILED");cancel.check();Response response;DWORD size=sizeof(response.status);
    require(WinHttpQueryHeaders(req,WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,WINHTTP_HEADER_NAME_BY_INDEX,&response.status,&size,nullptr)!=0,"INVALID_RESPONSE");
    response.poll=header(req,L"Azure-AsyncOperation");response.location=header(req,L"Location");response.async=!response.poll.empty();
    auto retry=header(req,L"Retry-After");if(!retry.empty()){
        if(std::all_of(retry.begin(),retry.end(),[](unsigned char c){return isdigit(c)!=0;})){try{auto seconds=std::stoull(retry);response.retry=static_cast<unsigned>(std::min<unsigned long long>(seconds,86400));}catch(...){response.retry=86400;}}
        else{SYSTEMTIME st{};if(WinHttpTimeToSystemTime(wide(retry).c_str(),&st)){FILETIME ft{},now{};SystemTimeToFileTime(&st,&ft);GetSystemTimeAsFileTime(&now);ULARGE_INTEGER a{},b{};a.LowPart=ft.dwLowDateTime;a.HighPart=ft.dwHighDateTime;b.LowPart=now.dwLowDateTime;b.HighPart=now.dwHighDateTime;response.retry=a.QuadPart>b.QuadPart?static_cast<unsigned>(std::min<ULONGLONG>((a.QuadPart-b.QuadPart)/10000000,86400)):1;}else response.retry=86400;}
        response.retry=std::max(1u,response.retry);
    }
    std::string bytes;char block[8192];DWORD got=0;
    while(true){cancel.check();require(WinHttpReadData(req,block,sizeof block,&got)!=0,"NETWORK_FAILED");if(!got)break;require(bytes.size()+got<=8*1024*1024,"RESPONSE_TOO_LARGE");bytes.append(block,got);}
    // Error bodies are discarded without parsing or exporting provider messages.
    if(response.status>=200&&response.status<300&&!bytes.empty())response.body=parse(bytes,8*1024*1024);
    return response;
}
}